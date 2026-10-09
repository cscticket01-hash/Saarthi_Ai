import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'school_qr_link.dart';
import 'windows_school_identity.dart';
import 'windows_backend_bridge.dart';
import 'windows_connect/central_school_cloud.dart';
import 'id_card_catalog.dart';
import 'id_card_engine.dart';
import 'fitted_document_preview.dart';
import 'windows_connect/school_drive_images.dart';
import 'windows_ui_localization.dart';

import 'dart:typed_data';

import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'package:printing/printing.dart';

import 'windows_local_firestore.dart';
import 'windows_reference_documents.dart';
import 'windows_student_id_cards.dart';

class WindowsDocumentTemplates {
  static const manifestName = 'School ID • Manifest Front + Back';
  static Future<Uint8List> manifestId(
    Map<String, dynamic> data, {
    String qr = '',
    String templateId = 'school-id-v1',
    Uint8List? photo,
    Uint8List? logo,
    Uint8List? signature,
    Uint8List? seal,
  }) async {
    final entry = await IdCardCatalog.find(templateId);
    final manifest = await entry.manifest();
    return IdCardEngine.render(
      manifest,
      data,
      qr: qr,
      backgrounds: await entry.backgrounds(),
      images: {
        if (photo != null) 'photo': photo,
        if (logo != null) 'logo': logo,
        if (signature != null) 'signature': signature,
        if (seal != null) 'seal': seal,
      },
    );
  }

  static Future<Map<String, dynamic>> selections() async =>
      (await FirebaseFirestore.instance
              .collection('school_settings')
              .doc('document_templates')
              .get())
          .data() ??
      {};
  static Future<Uint8List?> _image(dynamic raw) async {
    final source = raw?.toString().trim() ?? '';
    if (source.startsWith('data:image/')) {
      try {
        return Uint8List.fromList(UriData.parse(source).contentAsBytes());
      } catch (_) {
        return null;
      }
    }
    final u = Uri.tryParse(raw?.toString() ?? '');
    if (u == null || u.scheme != 'https') return null;
    try {
      return await schoolImageBytes(u.toString())
          .timeout(const Duration(milliseconds: 600), onTimeout: () => null);
    } catch (_) {}
    return null;
  }

  static String _documentDate(dynamic timestamp) {
    final date = timestamp is Timestamp
        ? timestamp.toDate()
        : timestamp is num
        ? DateTime.fromMillisecondsSinceEpoch(timestamp.toInt())
        : null;
    return date == null
        ? '-'
        : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  static Future<Uint8List?> _personPhoto(Map<String, dynamic> data) async {
    final url = data['photoUrl']?.toString().trim() ?? '';
    if (url.isNotEmpty) return _image(url);
    final raw = data['photoBase64']?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    return _image(
      raw.startsWith('data:image/') ? raw : 'data:image/jpeg;base64,$raw',
    );
  }

  static Future<Uint8List?> selected(
    String kind,
    Map<String, dynamic> data, {
    String qr = '',
    bool publish = true,
  }) async {
    qr = IdCardEngine.compactQr(qr);
    final bytes = await _selected(kind, data, qr: qr);
    if (bytes != null &&
        {'studentId', 'teacherId', 'otherStaffId'}.contains(kind) &&
        qr.isNotEmpty)
      await IdCardEngine.verifyExport(bytes, qr);
    if (bytes != null &&
        publish &&
        {'studentId', 'teacherId'}.contains(kind) &&
        qr.isNotEmpty) {
      final identity = await CentralSchoolCloud.saved();
      if (identity['managed'] == true) await _publish(kind, data, qr, bytes);
    }
    return bytes;
  }

  static String _fingerprint(
    Map<String, dynamic> data,
    Map<String, dynamic> profile,
    dynamic template,
    String qr,
  ) {
    dynamic clean(dynamic v) {
      if (v is Timestamp) return v.millisecondsSinceEpoch;
      if (v is DateTime) return v.millisecondsSinceEpoch;
      if (v is Map) {
        final keys =
            v.keys
                .map((k) => k.toString())
                .where(
                  (k) =>
                      !k.startsWith('_sync') &&
                      !{
                        'updatedAt',
                        'lastEdited',
                        'mobileLinkUpdatedAt',
                      }.contains(k),
                )
                .toList()
              ..sort();
        return {for (final k in keys) k: clean(v[k])};
      }
      if (v is List) return v.map(clean).toList();
      return v;
    }

    return sha256
        .convert(utf8.encode(jsonEncode(clean([data, profile, template, qr]))))
        .toString();
  }

  static Future<void> _publish(
    String kind,
    Map<String, dynamic> data,
    String qr,
    Uint8List bytes,
  ) async {
    final link = SchoolLink.parse(qr), db = FirebaseFirestore.instance;
    final collection = kind == 'teacherId'
        ? 'teachers_directory'
        : 'students_directory';
    final person = (await db.collection(collection).doc(link.personId).get())
        .data();
    if (person == null ||
        person['mobileLinkToken'] != link.linkToken ||
        link.schoolId != db.activeProfileIdentity['schoolSyncId'])
      throw StateError('Verified ID owner changed. Reopen ID card.');
    final profile =
        (await db.collection('school_config').doc('school_profile_cache').get())
            .data() ??
        {};
    final revision = _fingerprint(
      person,
      profile,
      (await selections())[kind],
      qr,
    );
    await WindowsBackendBridge.publishIdCard(
      bytes: bytes,
      qr: qr,
      kind: kind,
      person: person,
      inputRevision: revision,
    );
  }

  /// Uses the same selected renderer and the existing durable document outbox.
  /// Only changed person/profile/template inputs create a new immutable package.
  static Future<void> publishChangedIdCards() async {
    final db = FirebaseFirestore.instance, origin = db.activeProfileId;
    final identity = await CentralSchoolCloud.saved();
    if (identity['managed'] != true) return;
    final profile =
        (await db.collection('school_config').doc('school_profile_cache').get())
            .data() ??
        {};
    final templates = await selections();
    final fileQueue=(await db.collection('_windows_document_outbox').get()).docs;
    final recordQueue=(await db.collection('_windows_firebase_outbox').get()).docs;
    final conflictedIds={
      for(final q in fileQueue)if({'conflict','needsAttention'}.contains(q.data()['syncState']))q.id,
      for(final q in recordQueue)if(q.data()['collection']=='documents' && {'conflict','needsAttention'}.contains(q.data()['syncState']))q.data()['documentId'],
    };
    for (final kind in ['studentId', 'teacherId']) {
      final collection = kind == 'studentId'
          ? 'students_directory'
          : 'teachers_directory';
      final people = await db.collection(collection).get();
      for (final doc in people.docs) {
        if (db.activeProfileId != origin)
          throw StateError('School changed during ID publication.');
        // Retained file/metadata conflicts must be explicitly reviewed before
        // automatic ID regeneration can change their queue or local originals.
        final ownerId=WindowsBackendBridge.publishedIdCardOwnerId(kind=='studentId'?'student':'teacher',doc.id);
        if(conflictedIds.contains(ownerId))continue;
        final person = await SchoolPersonIdentity.ensure(collection, doc.id);
        final qr = SchoolLink.encodeCompact({
          'app': 'VIDYA_SAARTHI',
          'v': 2,
          'managed': true,
          'schoolId': identity['schoolId'],
          'centralEndpoint': identity['endpoint'],
          'firebaseProjectId': identity['projectId'],
          'type': kind == 'studentId' ? 'student' : 'teacher',
          'personId': doc.id,
          'linkToken': person['mobileLinkToken'],
        });
        final revision = _fingerprint(person, profile, templates[kind], qr);
        final id = WindowsBackendBridge.publishedIdCardId(qr);
        final existing =
            (await db.collection('_local_student_documents').doc(id).get())
                .data();
        if (existing?['inputRevision'] == revision &&
            existing?['deleted'] != true)
          continue;
        final address = [
          person['address'],
          person['district'],
          person['state'],
        ].where((v) => v != null && v.toString().isNotEmpty).join(', ');
        final data = {
          ...person,
          'schoolName': profile['schoolName'] ?? profile['name'] ?? '',
          'roll': person['rollNo'],
          'contact': person['parentContact'],
          'streetAddress': person['address'],
          'address': address,
          'showStudentUid': person['studentUid'] != null,
        };
        final bytes = await selected(kind, data, qr: qr, publish: false);
        if (bytes == null)
          throw StateError('Selected ID renderer returned no package.');
        await WindowsBackendBridge.publishIdCard(
          bytes: bytes,
          qr: qr,
          kind: kind,
          person: person,
          inputRevision: revision,
        );
      }
    }
  }

  static Future<Uint8List?> _selected(
    String kind,
    Map<String, dynamic> data, {
    String qr = '',
  }) async {
    final origin = FirebaseFirestore.instance.activeProfileId;
    if (data['schoolId'] != null &&
        data['schoolId'] !=
            FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'])
      throw StateError('Another school document is not accessible.');
    final v = (await selections())[kind];
    final profile =
        (await FirebaseFirestore.instance
                .collection('school_config')
                .doc('school_profile_cache')
                .get())
            .data() ??
        {};
    if (FirebaseFirestore.instance.activeProfileId != origin)
      throw StateError('School changed during document preview.');
    final assets = await Future.wait<Uint8List?>([
      _personPhoto(data),
      _image(data['schoolLogoUrl'] ?? profile['logoUrl']),
      _image(data['principalSignatureUrl'] ?? profile['principalSignatureUrl']),
      _image(profile['sealUrl']),
    ]);
    if (FirebaseFirestore.instance.activeProfileId != origin)
      throw StateError('School changed during document preview.');
    if ((v is String && v.startsWith('manifest:')) || kind == 'otherStaffId') {
      return manifestId(
        {
          ...profile,
          ...data,
          'schoolName': profile['schoolName'] ?? profile['name'] ?? '',
          'schoolAddress': profile['address'] ?? '',
          'designation':
              data['designation'] ??
              data['role'] ??
              (kind == 'studentId' ? 'Student' : 'Teacher'),
          'rollNo':
              data['rollNo'] ?? data['employeeId'] ?? data['teacherId'] ?? '',
          'parentName': data['parentName'] ?? data['fatherName'] ?? '',
        },
        qr: qr,
        templateId: v is String && v.startsWith('manifest:')
            ? v.substring(9)
            : (await IdCardCatalog.load())
                  .firstWhere((e) => e.kinds.contains(kind))
                  .id,
        photo: assets[0],
        logo: assets[1],
        signature: assets[2],
        seal: assets[3],
      );
    }
    if (kind == 'studentId') {
      return renderWindowsStudentId(
        template: windowsStudentIdIndex(v),
        data: {
          'schoolName': profile['schoolName'] ?? profile['name'] ?? '',
          ...data,
          if ((profile['schoolName']?.toString().trim() ?? '').isNotEmpty)
            'schoolName': profile['schoolName'],
        },
        qr: qr,
        photo: assets[0],
        logo: assets[1],
        signature: assets[2],
      );
    }
    return renderWindowsReferenceDocument(
      kind: kind,
      template: windowsReferenceDocumentIndex(kind, v),
      data: {
        ...profile,
        'schoolName': profile['schoolName'] ?? profile['name'] ?? '',
        'schoolAddress': profile['address'] ?? '',
        'schoolEmail': profile['schoolEmail'] ?? profile['email'] ?? '',
        ...data,
        if ((profile['schoolName']?.toString().trim() ?? '').isNotEmpty)
          'schoolName': profile['schoolName'],
        'schoolAddress': profile['address'] ?? '',
        'schoolEmail': profile['schoolEmail'] ?? profile['email'] ?? '',
        if (kind == 'reportCard' &&
            (data['dateText']?.toString().trim().isEmpty ?? true))
          'dateText': _documentDate(data['timestamp']),
      },
      qr: qr,
      photo: assets[0],
      logo: assets[1],
      signature: assets[2],
      seal: assets[3],
    );
  }

  static Future<Uint8List?> renderTemplate(
    String kind,
    int index,
    Map<String, dynamic> data,
  ) async {
    final origin = FirebaseFirestore.instance.activeProfileId;
    final profile =
        (await FirebaseFirestore.instance
                .collection('school_config')
                .doc('school_profile_cache')
                .get())
            .data() ??
        {};
    final branding = {
      ...data,
      ...profile,
      'schoolName': profile['schoolName'] ?? '',
      'schoolAddress': profile['address'] ?? '',
      'schoolEmail': profile['schoolEmail'] ?? profile['email'] ?? '',
    };
    final images = await Future.wait<Uint8List?>([
      _image(profile['logoUrl']),
      _image(profile['principalSignatureUrl']),
      _image(profile['sealUrl']),
    ]);
    if (FirebaseFirestore.instance.activeProfileId != origin)
      throw StateError('School changed during template preview.');
    final legacyCount = kind == 'studentId'
        ? windowsStudentIdNames.length
        : kind == 'teacherId'
        ? windowsReferenceDocumentNames['teacherId']!.length
        : kind == 'otherStaffId'
        ? 0
        : -1;
    if (legacyCount >= 0 && index >= legacyCount) {
      final choices = (await IdCardCatalog.load())
          .where((e) => e.kinds.contains(kind))
          .toList();
      final entry = choices[index - legacyCount];
      return manifestId(
        branding,
        templateId: entry.id,
        logo: images[0],
        signature: images[1],
        seal: images[2],
      );
    }
    if (kind == 'studentId')
      return renderWindowsStudentId(
        template: index,
        data: branding,
        logo: images[0],
        signature: images[1],
      );
    return renderWindowsReferenceDocument(
      kind: kind,
      template: index,
      data: branding,
      logo: images[0],
      signature: images[1],
      seal: images[2],
    );
  }

  static Future<void> preview(
    BuildContext context,
    Uint8List bytes, {
    String title = 'Document preview',
    String? notice,
    VoidCallback? onDownload,
    VoidCallback? onPrint,
  }) => showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      child: SizedBox(
        width: 900,
        height: 680,
        child: Column(
          children: [
            ListTile(
              title: Text(title),
              trailing: IconButton(
                onPressed: () => Navigator.pop(ctx),
                icon: const Icon(Icons.close),
              ),
            ),
            if (notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(notice, textAlign: TextAlign.center),
              ),
            Expanded(child: FittedDocumentPreview(bytes: bytes)),
            if (onDownload != null || onPrint != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  children: [
                    if (onPrint != null)
                      OutlinedButton.icon(
                        onPressed: onPrint,
                        icon: const Icon(Icons.print),
                        label: const Text('Print ID Card'),
                      ),
                    if (onDownload != null)
                      FilledButton.icon(
                        onPressed: onDownload,
                        icon: const Icon(Icons.download),
                        label: const Text('Download PDF'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
  static Future<bool> previewReport(
    BuildContext context,
    Map<String, dynamic> data,
  ) async {
    final bytes = await selected('reportCard', data);
    if (bytes == null) return false;
    if (context.mounted) await preview(context, bytes, title: 'Report card');
    return true;
  }
}

class SchoolDocumentTemplatesScreen extends StatefulWidget {
  const SchoolDocumentTemplatesScreen({super.key});
  @override
  State<SchoolDocumentTemplatesScreen> createState() =>
      _SchoolDocumentTemplatesScreenState();
}

class _SchoolDocumentTemplatesScreenState
    extends State<SchoolDocumentTemplatesScreen> {
  final _names = <String, List<String>>{
    ...windowsReferenceDocumentNames,
    'studentId': [
      ...windowsStudentIdNames,
      WindowsDocumentTemplates.manifestName,
    ],
    'teacherId': [
      ...windowsReferenceDocumentNames['teacherId']!,
      WindowsDocumentTemplates.manifestName,
    ],
    'otherStaffId': [WindowsDocumentTemplates.manifestName],
  };
  List<IdCardCatalogEntry> _catalog = [];
  String? _catalogError;
  int _legacyCount(String kind) => kind == 'studentId'
      ? windowsStudentIdNames.length
      : kind == 'teacherId'
      ? windowsReferenceDocumentNames['teacherId']!.length
      : 0;
  List<IdCardCatalogEntry> _choices(String kind) =>
      _catalog.where((e) => e.kinds.contains(kind)).toList();
  int _chosen() {
    final value = _selected[_kind];
    if (value is String && value.startsWith('manifest:')) {
      final i = _choices(_kind).indexWhere((e) => e.id == value.substring(9));
      return i < 0 ? -1 : _legacyCount(_kind) + i;
    }
    return _kind == 'studentId'
        ? windowsStudentIdIndex(value)
        : _kind == 'otherStaffId'
        ? 0
        : windowsReferenceDocumentIndex(_kind, value);
  }

  String _kind = 'studentId';
  Map<String, dynamic> _selected = {};
  bool _loading = true;
  final Map<String, Future<Uint8List>> _thumbnails = {};

  Future<Uint8List> _thumbnail(int index) {
    final kind = _kind;
    final sample = _sample;
    return _thumbnails.putIfAbsent('$kind:$index', () async {
      final bytes = (await WindowsDocumentTemplates.renderTemplate(
        kind,
        index,
        sample,
      ))!;
      final page = await Printing.raster(bytes, pages: [0], dpi: 100).first;
      return page.toPng();
    });
  }

  @override
  void initState() {
    super.initState();
    _initializeCatalog();
  }

  Future<void> _initializeCatalog() async {
    try {
      final entries = await IdCardCatalog.load(),
          v = await WindowsDocumentTemplates.selections();
      if (mounted)
        setState(() {
          _catalog = entries;
          _selected = v;
          for (final kind in ['studentId', 'teacherId', 'otherStaffId'])
            _names[kind] = [
              if (kind == 'studentId') ...windowsStudentIdNames,
              if (kind == 'teacherId')
                ...windowsReferenceDocumentNames['teacherId']!,
              ..._choices(kind).map((e) => e.name),
            ];
          _loading = false;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          _loading = false;
          _catalogError = 'Invalid template catalog: $e';
        });
    }
  }

  Map<String, dynamic> get _sample => {
    'schoolName': '',
    'name': _kind == 'teacherId' ? 'Ananya Sharma' : 'Arup Das',
    'teacherId': 'T-0001',
    'designation': 'Senior Teacher',
    'subject': 'Mathematics',
    'class': 'Class 5',
    'studentClass': 'Class 5',
    'rollNo': '12',
    'parentName': 'Bikash Das',
    'contact': '9876543210',
    'address': '',
    'district': 'Cachar',
    'state': 'Assam',
    'pinCode': '788001',
    'dob': '15/03/2015',
    'examName': 'Final Examination',
    'marks': {'English': 84, 'Mathematics': 91, 'Science': 87},
    'fullMarks': 100,
    'totalMarks': 262,
    'percentage': '87.3',
    'result': 'PASS',
    'receiptNo': 'VS-000124',
    'dateText': '01/10/2026',
    'feeItems': {'Tuition fee': 1000, 'Exam fee': 200},
    'totalAmount': 1200,
    'paymentMode': 'Cash',
  };
  Future<void> _preview(int index) async {
    final bytes = await WindowsDocumentTemplates.renderTemplate(
      _kind,
      index,
      _sample,
    );
    if (mounted)
      await WindowsDocumentTemplates.preview(
        context,
        bytes!,
        title: index < 0 ? 'Default preview' : _names[_kind]![index],
      );
  }

  Future<void> _select(int index) async {
    final kind = _kind, count = _legacyCount(_kind);
    final value =
        {'studentId', 'teacherId', 'otherStaffId'}.contains(kind) &&
            index >= count
        ? 'manifest:${_choices(kind)[index - count].id}'
        : index;
    await FirebaseFirestore.instance
        .collection('school_settings')
        .doc('document_templates')
        .set({
          kind: value,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
    if (mounted) setState(() => _selected[kind] = value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('School document templates')),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_catalogError != null) Text(_catalogError!),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _names.keys
                .map(
                  (k) => ChoiceChip(
                    label: Text(
                      {
                        'studentId': 'Student ID',
                        'teacherId': 'Teacher ID',
                        'otherStaffId': 'Other Staff ID',
                        'reportCard': 'Report card',
                        'receipt': 'Fee receipt',
                      }[k]!,
                    ),
                    selected: _kind == k,
                    onSelected: (_) => setState(() => _kind = k),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 14),
          const Text(
            'Preview first, then select one layout for the whole school. Student and teacher ID layouts are stored separately.',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 20),
          if (_loading) const LinearProgressIndicator(),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 350,
                mainAxisExtent: 360,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              itemCount: _names[_kind]!.length,
              itemBuilder: (ctx, n) {
                final i = n;
                final chosen = _chosen();
                final active = i == chosen;
                final portrait =
                    (_kind == 'studentId' || _kind == 'teacherId') &&
                    (_kind == 'studentId' ? i < 2 : i != 2);
                return Card(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: BorderSide(
                      color: active ? const Color(0xFF00D9A5) : Colors.white12,
                      width: active ? 2 : 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _kind == 'teacherId'
                                  ? Icons.school_outlined
                                  : _kind == 'studentId'
                                  ? Icons.badge_outlined
                                  : Icons.description_outlined,
                              color: Colors.tealAccent,
                            ),
                            const Spacer(),
                            if (active)
                              const Icon(
                                Icons.check_circle,
                                color: Colors.tealAccent,
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ...[
                          Expanded(
                            child: Center(
                              child: FutureBuilder<Uint8List>(
                                future: _thumbnail(i),
                                builder: (context, snapshot) => snapshot.hasData
                                    ? Image.memory(
                                        snapshot.data!,
                                        fit: BoxFit.contain,
                                      )
                                    : snapshot.hasError
                                    ? const Text(
                                        'Use Preview to view this design',
                                      )
                                    : const CircularProgressIndicator(),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Text(
                          i < 0 ? 'Default' : _names[_kind]![i],
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          i < 0
                              ? 'Standard school layout'
                              : portrait
                              ? 'Front | Back • each 54 × 85.6 mm'
                              : _kind.endsWith('Id')
                              ? 'Front | Back • each 85.6 × 54 mm'
                              : 'Printable school document',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),

                        Row(
                          children: [
                            OutlinedButton(
                              onPressed: () => _preview(i),
                              child: const Text('Preview'),
                            ),
                            const SizedBox(width: 10),
                            FilledButton(
                              onPressed: active || _catalogError != null
                                  ? null
                                  : () => _select(i),
                              child: Text(
                                active ? 'Selected' : 'Use for school',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
