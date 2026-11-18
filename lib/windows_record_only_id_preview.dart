import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'id_card_catalog.dart';
import 'windows_id_card_designer_entry.dart';
import 'windows_manifest_record_id_preview.dart';
import 'windows_student_id_cards.dart';
import 'windows_document_templates.dart';
import 'windows_local_firestore.dart';

/// A record-backed, on-screen ID view. Opening this dialog does not render,
/// cache, enqueue or publish PDF bytes. Export stays behind Download PDF.
class WindowsRecordOnlyIdPreview {
  const WindowsRecordOnlyIdPreview._();

  /// Resolve only an actually selected manifest. Never substitute a different
  /// graphic for a school's custom/legacy printable layout.
  static Future<Widget?> _selectedManifestPreview({
    required Map<String, dynamic> person,
    required String role,
    required String qr,
    required String origin,
    required String? school,
  }) async {
    final db = FirebaseFirestore.instance;
    final kind = role == 'Student'
        ? 'studentId' : role == 'Teacher' ? 'teacherId' : 'otherStaffId';
    final selections = await WindowsDocumentTemplates.selections();
    final selection = kind == 'studentId'
        ? 'manifest:$studentIdTemplateId'
        : selections[kind];
    if (selection is! String ||
        (!selection.startsWith('manifest:') &&
         !selection.startsWith('reviewed:'))) {
      return null; // Legacy designs continue using their native fallback.
    }
    final id = selection.startsWith('reviewed:')
        ? selection.split(':').elementAtOrNull(1)
        : selection.substring('manifest:'.length);
    if (id == null || id.isEmpty) {
      throw StateError('Selected school ID design is invalid.');
    }
    final entry = await IdCardCatalog.find(id);
    if (!entry.kinds.contains(kind)) {
      throw StateError('The selected ID template does not support this role.');
    }
    final manifest = selection.startsWith('reviewed:')
        ? await WindowsIdCardDesignerEntry.reviewed(
            selection, school ?? 'local:$origin')
        : await entry.manifest();
    final profile = (await db.collection('school_config')
        .doc('school_profile_cache').get()).data() ?? <String, dynamic>{};
    final images = await WindowsDocumentTemplates.previewManifestImages(
        person, profile);
    final backgrounds = await entry.backgrounds();
    if (db.activeProfileId != origin ||
        db.activeProfileIdentity['schoolSyncId'] != school ||
        (person['schoolId'] != null && person['schoolId'] != school)) {
      throw StateError('School changed during ID card preview.');
    }
    return WindowsManifestRecordIdPreview(
      manifest: manifest,
      record: {
        ...profile, ...person,
        'schoolName': person['schoolName'] ?? profile['schoolName'] ??
            profile['name'] ?? 'School',
        'schoolAddress': profile['address'] ?? person['schoolAddress'] ?? '',
      },
      backgrounds: backgrounds,
      images: images,
      qr: qr,
    );
  }

  static Future<void> show(
    BuildContext context, {
    required String title,
    required Map<String, dynamic> data,
    Future<void> Function()? onDownload,
  }) async {
    final db = FirebaseFirestore.instance;
    final origin = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId'];
    if (data['schoolId'] != null && data['schoolId'] != school) {
      throw StateError('Another school ID card cannot be displayed.');
    }
    final person = Map<String, dynamic>.from(data);
    final photo = WindowsDocumentTemplates.previewPersonPhoto(person);
    final qr = person['qrData']?.toString() ?? '';
    final schoolName = (person['schoolName'] ?? 'School').toString();
    final name = (person['name'] ?? '').toString();
    final role = title.toLowerCase().contains('student')
        ? 'Student'
        : title.toLowerCase().contains('teacher')
        ? 'Teacher'
        : 'Staff';

    final selectedPreview = _selectedManifestPreview(
      person: person, role: role, qr: qr, origin: origin,
      school: school?.toString(),
    );

    String value(List<String> keys) {
      for (final key in keys) {
        final text = person[key]?.toString().trim() ?? '';
        if (text.isNotEmpty && text.toLowerCase() != 'null') return text;
      }
      return '—';
    }

    Widget field(String label, List<String> keys) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 95, child: Text(label,
            style: const TextStyle(fontSize: 12, color: Colors.black54))),
        Expanded(child: Text(value(keys), softWrap: true,
            style: const TextStyle(fontSize: 13, color: Colors.black87,
                fontWeight: FontWeight.w600))),
      ]),
    );

    Widget side({required bool front}) => Container(
      width: 348,
      constraints: const BoxConstraints(minHeight: 258),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF116B75), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(schoolName, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                color: Color(0xFF075D65))),
          const SizedBox(height: 5),
          Text(front ? '$role ID · Front' : '$role ID · Back',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Colors.black54)),
          const Divider(),
          if (front) ...[
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              FutureBuilder<Uint8List?>(
                future: photo,
                builder: (_, snap) => ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: snap.hasData && snap.data!.isNotEmpty
                      ? Image.memory(snap.data!, width: 75, height: 92,
                          fit: BoxFit.cover)
                      : Container(width: 75, height: 92,
                          color: const Color(0xFFEAF1F1),
                          child: const Icon(Icons.person_outline,
                              size: 42, color: Colors.blueGrey)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name.isEmpty ? '—' : name,
                    style: const TextStyle(fontSize: 16,
                      color: Colors.black87, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  field(role == 'Student' ? 'Class' : 'Designation',
                    role == 'Student' ? ['class', 'className'] :
                        ['designation', 'role']),
                  field(role == 'Student' ? 'Roll' : 'Employee ID',
                    role == 'Student' ? ['rollNo', 'roll'] :
                        ['employeeId', 'teacherId']),
                ],
              )),
            ]),
            const SizedBox(height: 12),
            field('ID', ['studentId', 'teacherId', 'employeeId', 'id']),
            field('Contact', ['contact', 'mobile', 'parentContact']),
          ] else ...[
            field('Parent', ['parentName', 'fatherName']),
            field('D.O.B.', ['dob', 'dateOfBirth']),
            field('Address', ['address', 'streetAddress']),
            if (qr.isNotEmpty)
              Align(alignment: Alignment.center,
                child: QrImageView(data: qr, size: 112,
                  backgroundColor: Colors.white)),
          ],
        ],
      ),
    );

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 750,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Live record preview · No PDF is generated',
                  style: TextStyle(fontSize: 12)),
                const SizedBox(height: 12),
                FutureBuilder<Widget?>(
                  future: selectedPreview,
                  builder: (_, snap) {
                    if (snap.hasError) {
                      return Text(
                        'The selected school ID layout could not be verified. '
                        'No alternate design or PDF has been substituted. '
                        '${snap.error}',
                        style: const TextStyle(color: Colors.deepOrange));
                    }
                    if (snap.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.data != null) return snap.data!;
                    return Column(crossAxisAlignment:
                        CrossAxisAlignment.start, children: [
                      const Text('Legacy custom layout · record-only data card',
                        style: TextStyle(fontSize: 12)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 12, runSpacing: 12,
                        children: [side(front: true), side(front: false)]),
                    ]);
                  },
                ),
                const SizedBox(height: 12),
                const Text('Download PDF uses the selected printable school template.',
                  style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
          if (onDownload != null)
            FilledButton.icon(
              onPressed: () async {
                if (db.activeProfileId != origin ||
                    db.activeProfileIdentity['schoolSyncId'] != school) {
                  Navigator.of(dialogContext).pop();
                  return;
                }
                Navigator.of(dialogContext).pop();
                await onDownload();
              },
              icon: const Icon(Icons.download_outlined),
              label: const Text('Download PDF'),
            ),
        ],
      ),
    );
  }
}
