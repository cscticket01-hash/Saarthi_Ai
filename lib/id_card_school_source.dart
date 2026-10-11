import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'id_card_bulk_engine.dart';
import 'id_card_engine.dart';
import 'id_card_manifest.dart';
import 'school_qr_link.dart';
import 'windows_local_firestore.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/school_drive_images.dart';

class IdCardBulkPreflight {
  IdCardBulkPreflight(this.students, this.findings);
  final List<IdCardBulkStudent> students;
  final List<Map<String, String>> findings;
  bool get blocked => findings.any((f) => f['severity'] == 'error');
}

/// Reads the existing local school, cached profile and existing QR credentials.
/// No issuance, person edits, queue creation or profile re-registration.
class IdCardSchoolSource {
  IdCardSchoolSource({required this.schoolId, required this.profile,
    required this.records, required this.connection, required this.ensureActive});
  final String schoolId;
  final Map<String, dynamic> profile, connection;
  final List<Map<String, dynamic>> records;
  final void Function() ensureActive;

  static Future<IdCardSchoolSource> capture() async {
    final db = FirebaseFirestore.instance, origin = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    if (origin.isEmpty || origin == 'unbound' || school.isEmpty) throw StateError('Select an existing connected school identity for bulk IDs');
    void guard() { if (db.activeProfileId != origin || db.activeProfileIdentity['schoolSyncId'] != school) throw StateError('School changed; reopen ID tools'); }
    final profile = (await db.collection('school_config').doc('school_profile_cache').get()).data() ?? {};
    guard();
    final docs = await db.collection('students_directory').get();guard();
    final connection = await CentralSchoolCloud.saved();guard();
    if (connection['schoolId'] != school) throw StateError('School QR connection is unavailable or belongs to another school');
    final records = scopedRecords(
      docs.docs.map((doc) => <String, dynamic>{...doc.data(), '_recordId': doc.id}),
      school,
    );
    records.sort((a,b) => a['_recordId'].toString().compareTo(b['_recordId'].toString()));
    return IdCardSchoolSource(schoolId: school, profile: profile, records: records, connection: connection, ensureActive: guard);
  }

  /// Reject cross-school records instead of silently including them in a
  /// class bulk export. Retained local records without an explicit school
  /// binding still belong to the already-selected local profile.
  static List<Map<String, dynamic>> scopedRecords(
      Iterable<Map<String, dynamic>> rows, String schoolId) {
    if (schoolId.trim().isEmpty) throw StateError('School identity required');
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      for (final field in ['schoolId', 'schoolSyncId']) {
        final bound = row[field]?.toString().trim() ?? '';
        if (bound.isNotEmpty && bound != schoolId) {
          throw StateError('Foreign student record requires school review');
        }
      }
      if (row['_syncDeleted'] == true || row['deleted'] == true) continue;
      result.add(row);
    }
    return result;
  }

  /// Never preview a deleted or explicitly foreign school record. Unscoped
  /// legacy local records remain readable in the active profile, but an
  /// explicitly school-bound record must match the active school identity.
  static Map<String, dynamic>? previewSample(
      Iterable<Map<String, dynamic>> rows, String? currentSchoolId) {
    final activeSchool = currentSchoolId?.trim() ?? '';
    for (final row in rows) {
      if (row['_syncDeleted'] == true || row['deleted'] == true) continue;
      var foreign = false;
      for (final field in ['schoolId', 'schoolSyncId']) {
        final bound = row[field]?.toString().trim() ?? '';
        if (bound.isNotEmpty && bound != activeSchool) {
          foreign = true;
          break;
        }
      }
      if (!foreign) return row;
    }
    return null;
  }

  static String classOf(Map<String, dynamic> data) => (data['studentClass'] ?? data['class'] ?? '').toString().trim();
  List<String> get classes => (records.map(classOf).where((v) => v.isNotEmpty).toSet().toList()..sort());
  List<Map<String, dynamic>> forClass(String value) => records.where((r) => classOf(r) == value).toList();

  String existingQr(Map<String, dynamic> record) {
    final personId = (record['mobileStableId'] ?? record['_recordId']).toString();
    final token = record['mobileLinkToken']?.toString() ?? '';
    if (token.length < 20) throw StateError('Existing QR credential missing; school authorization required');
    final raw = record['idCardQr']?.toString();
    final qr = raw != null && raw.isNotEmpty ? raw : SchoolLink.encodeCompact({
      'managed': connection['managed'] == true, 'schoolId': schoolId,
      'centralEndpoint': connection['endpoint'], 'firebaseProjectId': connection['projectId'],
      'googleScriptUrl': connection['scriptUrl'], 'type': 'student', 'personId': personId, 'linkToken': token,
    });
    final link = SchoolLink.parse(qr);
    if (link.managed != (connection['managed'] == true) ||
        (link.managed && link.endpoint != connection['endpoint']) ||
        (link.managed ? link.schoolId : link.projectId) != schoolId ||
        link.personId != personId || link.linkToken != token || link.role != 'student') {
      throw StateError('Existing student QR identity mismatch');
    }
    return qr;
  }

  Future<IdCardBulkPreflight> preflight(String classId, Set<String> selected, IdCardManifest template,
      {Map<String, Uint8List> backgrounds = const {}, Future<Uint8List?> Function(String)? imageLoader, void Function(int,int)? onProgress, bool Function()? isCancelled}) async {
    ensureActive();
    if (selected.isEmpty || selected.length > 500) throw StateError('Select 1–500 students from one class');
    final rows = forClass(classId).where((r) => selected.contains(r['_recordId'])).toList();
    if (rows.length != selected.length) throw StateError('Student selection changed or belongs to another class');
    final load = imageLoader ?? schoolImageBytes;
    Future<Uint8List?> image(Object? source) async {
      if (source == null || source.toString().isEmpty) return null;
      try { final bytes = await load(source.toString()).timeout(const Duration(seconds: 8), onTimeout: () => null);ensureActive();return bytes; }
      catch (_) { ensureActive();return null; }
    }
    final shared = <String, Uint8List>{};
    for (final key in ['logo','signature','seal']) {
      final bytes = await image(profile[key == 'logo' ? 'logoUrl' : key == 'signature' ? 'principalSignatureUrl' : 'sealUrl']);
      if (bytes != null) shared[key] = bytes;
    }
    final students = <IdCardBulkStudent>[], findings = <Map<String,String>>[];
    for (final row in rows) {
      ensureActive();if (isCancelled?.call() ?? false) throw StateError('Bulk preparation cancelled; existing jobs retained');
      final id = row['_recordId'].toString();
      try {
        final qr = existingQr(row), link = SchoolLink.parse(qr);
        final rawPhoto = row['photoBase64']?.toString();
        final photo = await image(row['photoUrl'] ?? (rawPhoto == null ? null : rawPhoto.startsWith('data:image/') ? rawPhoto : 'data:image/png;base64,$rawPhoto'));
        final images = {...shared, if (photo != null) 'photo': photo};
        if (photo == null) findings.add({'studentId':id,'severity':'warning','code':'MISSING_PHOTO'});
        final data = <String,dynamic>{
          'schoolId': schoolId, 'schoolName': profile['schoolName'] ?? profile['name'] ?? '',
          'schoolAddress': profile['address'] ?? '', 'name': row['name'] ?? '',
          'parentName': row['parentName'] ?? row['fatherName'] ?? '',
          'class': classId, 'studentClass': classId, 'section': row['section'] ?? '',
          'rollNo': row['rollNo']?.toString() ?? '', 'studentId': link.personId,
          'address': row['address'] ?? '', 'contact': row['contact'] ?? row['contactNo'] ?? '',
          'district': row['district'] ?? '', 'state': row['state'] ?? '',
          'pinCode': row['pinCode']?.toString() ?? '', 'designation': 'Student',
          'academicSession': row['academicSession'] ?? profile['academicSession'] ?? '',
          'sourceRecordRevision': row['_syncRevision'] ?? 'local-unversioned',
          'sourceRecordId': id,
        };
        var missing = false;
        for (final r in template.regions.where((r) => r.isRequired)) {
          if (r.kind == 'image' ? images[r.key] == null : r.kind == 'text' && (data[r.key]?.toString().trim().isEmpty ?? true)) {
            findings.add({'studentId':id,'severity':'error','code':'MISSING_REQUIRED_${r.key}'});missing=true;
          }
        }
        if (missing) {onProgress?.call(rows.indexOf(row)+1, rows.length);continue;}
        final issued = link.cardIssueId.isNotEmpty;
        final issue = issued ? qr.split('|').last : 'legacy-qr:${sha256.convert(utf8.encode(IdCardEngine.compactQr(qr)))}';
        students.add(IdCardBulkStudent(schoolId:schoolId,classId:classId,studentId:link.personId,
          cardIssueId:issue,identityKind:issued?'issued-reference':'legacy-qr-reference',qr:qr,data:data,images:images,backgrounds:backgrounds));
      } catch (_) { findings.add({'studentId':id,'severity':'error','code':'IDENTITY_OR_INPUT_REVIEW'}); }
      onProgress?.call(rows.indexOf(row)+1, rows.length);
    }
    ensureActive();return IdCardBulkPreflight(students,findings);
  }
}
