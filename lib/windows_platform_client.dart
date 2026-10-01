import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'platform/platform_config.dart';
import 'windows_firebase_sync.dart';
import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';

class WindowsLicenseState {
  const WindowsLicenseState({required this.allowed, required this.status, required this.expiresAt, this.error = ''});
  final bool allowed;
  final String status;
  final DateTime expiresAt;
  final String error;
  int get daysLeft => max(0, expiresAt.difference(DateTime.now()).inHours ~/ 24);
}
class WindowsPlatformClient {
  WindowsPlatformClient._();
  static final instance = WindowsPlatformClient._();
  static const _secure = FlutterSecureStorage();
  final state = ValueNotifier<WindowsLicenseState>(WindowsLicenseState(allowed: true, status: 'checking', expiresAt: DateTime.now()));
  String _id = '', _secret = '', _boundProject = '', _cacheProject = '';
  DateTime? _trialStart, _lastSeen, _verifiedAt;
  Timer? _timer;
  bool _running = false;
  final Set<String> _sentNotices = {};
  static const version = String.fromEnvironment('APP_VERSION', defaultValue: '2.1.79');
  String _random() => base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
  Future<Map<String, dynamic>> call(String action, Map<String, dynamic> body) async {
    final response = await http.post(Uri.parse(platformApiUrl), headers: {'Content-Type':'application/json'}, body: jsonEncode({'action':action, 'installationId':_id, 'installationSecret':_secret, ...body})).timeout(const Duration(seconds:15));
    final d = jsonDecode(response.body);
    if (d is! Map || response.statusCode >= 400 || d['success'] != true) throw StateError(d is Map ? d['message']?.toString() ?? 'Platform unavailable' : 'Platform unavailable');
    return Map<String,dynamic>.from(d);
  }
  Future<void> initialize() async {
    if (_id.isNotEmpty) return;
    _id = await _secure.read(key:'vs_installation_id') ?? _random();
    await _secure.write(key:'vs_installation_id',value:_id);
    _secret = await _secure.read(key:'vs_installation_secret') ?? '';
    _trialStart = DateTime.tryParse(await _secure.read(key:'vs_trial_start') ?? '') ?? DateTime.now().toUtc();
    await _secure.write(key:'vs_trial_start',value:_trialStart!.toIso8601String());
    _lastSeen = DateTime.tryParse(await _secure.read(key:'vs_license_last_seen') ?? '');
    _verifiedAt = DateTime.tryParse(await _secure.read(key:'vs_license_verified_at') ?? '');
    final cache = await _secure.read(key:'vs_license_cache');
    if (cache != null) { try { _apply(Map<String,dynamic>.from(jsonDecode(cache)), verified:false); } catch (_) {} }
    final active = await WindowsFirebaseRemote.status();
    if (_cacheProject.isNotEmpty && active.projectId != _cacheProject) {
      _verifiedAt = null;
      state.value = WindowsLicenseState(allowed:false,status:'unbound',expiresAt:DateTime.now());
    }
    _offlineState('');
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds:60), (_) => unawaited(refresh()));
  }
  void _offlineState(String error) {
    final now = DateTime.now().toUtc();
    final clockOK = _lastSeen == null || !now.isBefore(_lastSeen!.subtract(const Duration(minutes:5)));
    final trialEnd = _trialStart!.add(const Duration(days:5));
    final cached = state.value;
    final paidOffline = cached.status == 'licensed' && _verifiedAt != null && now.difference(_verifiedAt!).inHours <= 72 && cached.expiresAt.isAfter(now);
    if (cached.status == 'blocked') { state.value=WindowsLicenseState(allowed:false,status:'blocked',expiresAt:cached.expiresAt,error:error); return; }
    state.value = WindowsLicenseState(allowed:clockOK && (paidOffline || trialEnd.isAfter(now)),status:!clockOK?'clock_error':paidOffline?'licensed':trialEnd.isAfter(now)?'trial':'expired',expiresAt:paidOffline?cached.expiresAt:trialEnd,error:error);
  }
  void _apply(Map<String,dynamic> data, {bool verified=true}) {
    final now = DateTime.now().toUtc();
    _cacheProject = data['schoolId']?.toString() ?? '';
    final end = DateTime.fromMillisecondsSinceEpoch((data['expiresAt'] as num?)?.toInt() ?? 0, isUtc:true);
    state.value = WindowsLicenseState(allowed:data['allowed']==true && end.isAfter(now),status:data['status']?.toString() ?? 'expired',expiresAt:end);
    if (verified) { _verifiedAt=now; unawaited(_secure.write(key:'vs_license_verified_at',value:now.toIso8601String())); unawaited(_secure.write(key:'vs_license_cache',value:jsonEncode(data))); }
  }
  Future<void> refresh() async {
    if (_running) return;
    _running=true;
    try {
      if (_secret.isEmpty) {
        String hardware = Platform.environment['COMPUTERNAME'] ?? _id;
        try { final r = await Process.run('reg',['query',r'HKLM\SOFTWARE\Microsoft\Cryptography','/v','MachineGuid']); if(r.exitCode==0) hardware=r.stdout.toString().trim(); } catch (_) {}
        final data=await call('installation/register',{'deviceFingerprint':sha256.convert(utf8.encode(hardware)).toString()});
        _secret=data['installationSecret'].toString();
        await _secure.write(key:'vs_installation_secret',value:_secret);
        final serverStart=DateTime.fromMillisecondsSinceEpoch((data['trialStartedAt'] as num).toInt(),isUtc:true);
        if(serverStart.isBefore(_trialStart!)) _trialStart=serverStart;
        await _secure.write(key:'vs_trial_start',value:_trialStart!.toIso8601String());
      }
      final remote=await WindowsFirebaseRemote.status();
      if (_cacheProject.isNotEmpty && remote.projectId != _cacheProject) {
        _verifiedAt=null;
        state.value=WindowsLicenseState(allowed:false,status:'unbound',expiresAt:DateTime.now());
      }
      final links=await WindowsExternalConnections.load();
      final script=links['googleScriptUrl']?.toString().trim() ?? '';
      if(remote.authenticated && script.isNotEmpty && _boundProject!=remote.projectId) {
        final nameDoc=await FirebaseFirestore.instance.collection('school_config').doc('school_profile_cache').get();
        final bound=await call('school/bind',{'projectId':remote.projectId,'googleScriptUrl':script,'schoolIdToken':await WindowsFirebaseRemote.freshIdToken(),'schoolName':nameDoc.data()?['schoolName'] ?? remote.projectId,'version':version});
        _boundProject=remote.projectId;
        _apply(bound);
      }
      final students=await FirebaseFirestore.instance.collection('students_directory').get();
      final teachers=await FirebaseFirestore.instance.collection('teachers_directory').get();
      final heartbeat=await call('school/heartbeat',{'version':version,'studentCount':students.docs.length,'teacherCount':teachers.docs.length});
      if (heartbeat['schoolId'] != null && remote.projectId != heartbeat['schoolId']) throw StateError('Connect and verify the active school before using its license.');
      _apply(heartbeat);
      if(state.value.allowed && _boundProject.isNotEmpty) await _relayNotices();
    } catch(e) { _offlineState(e.toString().replaceFirst('Bad state: ','')); }
    finally { _lastSeen=DateTime.now().toUtc(); await _secure.write(key:'vs_license_last_seen',value:_lastSeen!.toIso8601String()); _running=false; }
  }
  Future<void> _relayNotices() async {
    final list=await FirebaseFirestore.instance.collection('school_notices').get();
    for(final doc in list.docs) {
      if(_sentNotices.contains(doc.id)) continue;
      final d=doc.data(); final raw=d['timestamp'] ?? d['createdAt'];
      final at=raw is Timestamp?raw.millisecondsSinceEpoch:raw is num?raw.toInt():DateTime.tryParse(raw?.toString() ?? '')?.millisecondsSinceEpoch ?? 0;
      if(at<DateTime.now().subtract(const Duration(days:7)).millisecondsSinceEpoch){_sentNotices.add(doc.id);continue;}
      await call('school/notice',{'noticeId':doc.id,'title':d['title'] ?? 'School notice','message':d['description'] ?? d['message'] ?? ''});
      _sentNotices.add(doc.id);
    }
  }
  Future<void> activate(String key) async { final data=await call('license/activate',{'key':key.trim().toUpperCase()}); _apply(data); await _secure.write(key:'vidya_saarthi_windows_license_status_v1',value:'active'); }
  Future<void> complaint(String message) async { await call('complaint/create',{'message':message,'version':version}); }
  void dispose() { _timer?.cancel(); }
}
