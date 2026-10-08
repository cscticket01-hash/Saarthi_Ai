import 'managed_developer_service.dart';
import 'dart:convert';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'monitor_summary.dart';
import 'platform_config.dart';

/// Authenticated website operations. Firebase rules enforce the developer claim
/// on every operation; the dashboard is never an authority by itself.
class DeveloperService {
  final _db = FirebaseFirestore.instance;
  Map<String, dynamic>? _cached;
  DateTime? _loadedAt;
  String _random(int bytes) => List.generate(bytes, (_) => Random.secure().nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  dynamic _plain(dynamic v) {
    if (v is Timestamp) return v.millisecondsSinceEpoch;
    if (v is Map) return v.map((k, x) => MapEntry(k.toString(), _plain(x)));
    if (v is List) return v.map(_plain).toList();
    return v;
  }
  Future<List<Map<String, dynamic>>> _list(String collection, {int limit = 500}) async {
    final s = await _db.collection(collection).limit(limit).get();
    return s.docs.map((d) => <String, dynamic>{...Map<String, dynamic>.from(_plain(d.data())), 'id': d.id}).toList();
  }
  Future<Map<String, dynamic>> call(String action, Map<String, dynamic> body) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Developer login required');
    final claims = (await user.getIdTokenResult()).claims ?? {};
    if (claims['admin'] != true && claims['developer'] != true) {
      throw StateError('Developer access required');
    }
    if (action == 'developer/dashboard') return _dashboard(body['refresh'] == true);
    _cached = null;
    if(action=='school/block'||action=='school/delete'||action=='license/issue'){
      final id=body['schoolId']?.toString()??'';final school=(await _db.collection('platform_schools').doc(id).get()).data();
      if(school?['managed']==true){
        return ManagedDeveloperService.call(action=='school/delete'?'delete':action=='school/block'?'block':'licence',body);
      }
    }
    if(action=='license/revoke'||action=='license/delete'){
      final licence=(await _db.collection('platform_licenses').doc(body['licenseId'].toString()).get()).data();
      if(licence!=null){final school=(await _db.collection('platform_schools').doc(licence['schoolId']).get()).data();
        if(school?['managed']==true){if(school?['licenseId']!=body['licenseId'])throw StateError('This is an old licence. Manage the current school licence from central controls.');return ManagedDeveloperService.call(action=='license/delete'?'delete-licence':'revoke',{'schoolId':licence['schoolId']});}}
    }

    if (action == 'school/create') return _createSchool(body);
    if (action == 'license/issue') return _issue(body, user.uid);
    if (action == 'license/revoke') {
      final id = body['licenseId'].toString();
      final doc = _db.collection('platform_licenses').doc(id);
      final license = (await doc.get()).data();
      if (license == null) throw StateError('Licence not found');
      final batch = _db.batch();
      batch.update(doc, {'revoked': true, 'revokedAt': FieldValue.serverTimestamp()});
      batch.update(_db.collection('platform_license_status').doc(id), {'revoked': true});
      final school = _db.collection('platform_schools').doc(license['schoolId']);
      final current = (await school.get()).data();
      if (current?['licenseId'] == id) batch.update(school, {'licenseExpiresAt': 0});
      await batch.commit();
      return {'success': true};
    }
    if (action == 'license/delete') {
      final id = body['licenseId'].toString();
      final doc = _db.collection('platform_licenses').doc(id);
      final license = (await doc.get()).data();
      if (license == null) throw StateError('Licence not found');
      final schoolId = license['schoolId']?.toString() ?? '';
      final school = _db.collection('platform_schools').doc(schoolId);
      final current = (await school.get()).data();
      final batch = _db.batch();
      batch.delete(doc);
      batch.delete(_db.collection('platform_license_status').doc(id));
      if (current?['licenseId'] == id) {
        batch.set(school, {
          'licenseId': FieldValue.delete(),
          'licenseExpiresAt': FieldValue.delete(),
        }, SetOptions(merge: true));
      }
      await batch.commit();
      return {'success': true};
    }
    if (action == 'school/block') {
      final schoolId = body['schoolId'].toString();
      final blocked = body['blocked'] == true;
      final school = _db.collection('platform_schools').doc(schoolId);
      if (!(await school.get()).exists) throw StateError('School not found');
      final licences = await _db.collection('platform_licenses').where('schoolId', isEqualTo: schoolId).get();
      final batch = _db.batch();
      batch.set(_db.collection('platform_school_blocks').doc(schoolId), {
        'blocked': blocked,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      batch.set(school, {'blocked': blocked}, SetOptions(merge: true));
      if (blocked) {
        for (final l in licences.docs) {
          batch.set(l.reference, {'revoked': true, 'revokedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
          batch.set(_db.collection('platform_license_status').doc(l.id), {'revoked': true}, SetOptions(merge: true));
        }
        batch.set(school, {'licenseExpiresAt': 0}, SetOptions(merge: true));
      }
      await batch.commit();
      return {'success': true, 'blocked': blocked};
    }
    if (action == 'school/delete') {
      final schoolId = body['schoolId'].toString();
      await call('school/block', {'schoolId':schoolId,'blocked':true});
      await _db.collection('platform_schools').doc(schoolId).set({'deletedAt':FieldValue.serverTimestamp()},SetOptions(merge:true));
      return {'success':true};
    }
    if (action == 'complaint/update') {
      final status = body['status'].toString();
      if (!{'open','in_progress','resolved'}.contains(status)) throw ArgumentError('Invalid status');
      await _db.collection('platform_complaints').doc(body['complaintId'].toString()).update({
        'status': status, 'developerNote': body['note'].toString().substring(0, min(3000, body['note'].toString().length)),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return {'success': true};
    }
    throw ArgumentError('Unknown developer action');
  }
  Future<Map<String, dynamic>> _dashboard(bool refresh) async {
    if (refresh || _cached == null || _loadedAt == null ||
        DateTime.now().difference(_loadedAt!) > const Duration(minutes: 30)) {
      final lists = await Future.wait([
        _list('platform_schools'), _list('platform_school_trials'),
        _list('platform_licenses'),
        _db.collection('platform_complaints').orderBy('createdAt', descending: true).limit(100).get()
          .then((s) => s.docs.map((d) => <String,dynamic>{...Map<String,dynamic>.from(_plain(d.data())), 'id':d.id}).toList()),
      ]);
      final byId = {for (final s in lists[0]) s['id']: s};
      for (final s in lists[1]) {
        byId.putIfAbsent(s['id'], () => {'id':s['id'], 'name':s['id'], 'trialStartedAt':s['createdAt']});
      }
      _cached = {'schools': byId.values.toList(), 'licenses':lists[2], 'complaints':lists[3]};
      _loadedAt = DateTime.now();
    }
    final summaries = await _list('platform_school_summaries');
    final byId = {for(final s in summaries) s['id']:s};
    final licenses={for(final l in _cached!['licenses'] as List) l['id']:l};
    final schools = (_cached!['schools'] as List).where((s)=>s['deletedAt']==null).map((s) {
      final school=<String,dynamic>{...s, if(s['managed']!=true)...?byId[s['id']]};
      final active=licenses[school['activeLicenseHash']];
      if(active!=null && active['schoolId']==school['id']) {
        school['licenseExpiresAt']=active['revoked']==true?0:active['expiresAt'];
      }
      return school;
    }).toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    return {'success':true, ..._cached!, 'schools':schools, 'serverTime':now, 'summary':monitorSummary(schools,now)};
  }
  Future<Map<String, dynamic>> _createSchool(Map<String, dynamic> b) async {
    final schoolId = b['schoolId'].toString().trim();
    if (!RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(schoolId) || schoolId == platformProjectId) {
      throw ArgumentError('Enter the school\'s separate Firebase project ID');
    }
    final ref = _db.collection('platform_schools').doc(schoolId);
    final previous = (await ref.get()).data();
    if (previous?['monitorUid'] != null && b['replaceMonitor'] != true) return {'success':true};
    final password = _random(24), email = 'monitor-${_random(12)}@vidyasaarthi.invalid';
    // Independent REST sign-up keeps the developer's current login intact.
    final r = await http.post(Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$platformApiKey'),
      headers:{'Content-Type':'application/json'},
      body:jsonEncode({'email':email, 'password':password, 'returnSecureToken':true}));
    final auth = jsonDecode(r.body);
    if (r.statusCode != 200 || auth['localId'] == null) throw StateError('Could not provision school monitoring');
    final uid = auth['localId'].toString();
    final name = (b['schoolName'] ?? schoolId).toString().trim();
    final batch = _db.batch();
    batch.set(ref, {'name':name.isEmpty?schoolId:name, 'monitorUid':uid, 'createdAt':FieldValue.serverTimestamp()}, SetOptions(merge:true));
    batch.set(_db.collection('platform_monitor_access').doc(uid), {'schoolId':schoolId});
    if (previous?['monitorUid'] != null) {
      batch.delete(_db.collection('platform_monitor_access').doc(previous!['monitorUid']));
    }
    try { await batch.commit(); } catch (_) {
      await http.post(Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:delete?key=$platformApiKey'),
        headers:{'Content-Type':'application/json'},body:jsonEncode({'idToken':auth['idToken']}));
      rethrow;
    }
    return {'success':true, 'setup':{'projectId':schoolId, 'monitorEmail':email, 'monitorPassword':password}};
  }
  Future<Map<String, dynamic>> _issue(Map<String, dynamic> b, String uid) async {
    final days = b['days'];
    final amount = b['amount'];
    if (days is! int || days < 1 || days > 3650 || amount is! num || !amount.isFinite || amount < 0) {
      throw ArgumentError('Use 1–3650 days and a valid purchase amount');
    }
    final schoolId = b['schoolId'].toString();
    final setup = await _createSchool(b);
    final school = _db.collection('platform_schools').doc(schoolId);
    final key = 'VS-${_random(16).toUpperCase()}';
    final id = sha256.convert(utf8.encode(key)).toString();
    final expires = DateTime.now().toUtc().add(Duration(days:days));
    final batch = _db.batch();
    batch.set(_db.collection('platform_licenses').doc(id), {
      'schoolId':schoolId, 'expiresAt':Timestamp.fromDate(expires), 'issuedAt':FieldValue.serverTimestamp(),
      'issuedBy':uid, 'paid':b['paid']==true, 'amount':amount, 'revoked':false, 'keyHint':key.substring(key.length-6),
    });
    batch.set(_db.collection('platform_license_status').doc(id), {
      'schoolId':schoolId, 'expiresAt':Timestamp.fromDate(expires), 'revoked':false,
    });
    batch.set(school, {'licenseId':id, 'licenseExpiresAt':Timestamp.fromDate(expires),
      if(b['paid']==true) 'purchased':true}, SetOptions(merge:true));
    await batch.commit();
    return {'success':true, 'key':key, 'expiresAt':expires.millisecondsSinceEpoch,
      if(setup['setup'] != null) 'setup':{...setup['setup'] as Map, 'licenseKey':key}};
  }
}
