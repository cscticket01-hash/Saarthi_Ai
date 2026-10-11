import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'id_card_catalog.dart';
import 'id_card_designer.dart';
import 'id_card_designer_screen.dart';
import 'id_card_draft_storage_io.dart';
import 'windows_local_firestore.dart';

/// The actual Windows document-template route into the local-first ID
/// designer. This deliberately saves DRAFTS only; it does not silently change
/// school-wide print layouts, issue QR credentials or sync school data.
class WindowsIdCardDesignerEntry {
  static Future<void> open(
    BuildContext context, {
    required IdCardCatalogEntry entry,
  }) async {
    final db = FirebaseFirestore.instance;
    final originalProfile = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId']?.toString().trim();
    if (originalProfile.isEmpty || originalProfile == 'unbound') {
      throw StateError('Select a local school before editing ID cards.');
    }
    final schoolScope = school == null || school.isEmpty
        ? 'local:$originalProfile'
        : school;

    void checkSchool() {
      if (db.activeProfileId != originalProfile ||
          (db.activeProfileIdentity['schoolSyncId']?.toString().trim() ?? '') !=
              (school ?? '')) {
        throw StateError('School changed. Reopen the ID card designer.');
      }
    }

    if (!entry.kinds.contains('studentId')) {
      throw StateError('This designer route requires a student ID template.');
    }

    // Paths come from a validated bundled catalog ID, never user input.
    final root = await getApplicationSupportDirectory();
    checkSchool();
    final safeTemplate = entry.id;
    if (!RegExp(r'^[a-z][a-z0-9-]{1,80}$').hasMatch(safeTemplate)) {
      throw const FormatException('Invalid ID template storage key.');
    }
    final store = IdCardDraftStorageIo(
      rootPath: '${root.path}${Platform.pathSeparator}id_card_drafts'
          '${Platform.pathSeparator}$safeTemplate',
      schoolId: schoolScope,
    );
    final asset = jsonDecode(await rootBundle.loadString(entry.manifestAsset));
    if (asset is! Map) throw const FormatException('Invalid ID template.');
    final editor = IdCardDesigner(
      schoolId: schoolScope,
      manifest: Map<String, dynamic>.from(asset),
    );
    final current = await store.loadDraft();
    checkSchool();
    if (current != null) {
      final savedManifest = current['manifest'];
      if (savedManifest is! Map || savedManifest['id'] != entry.id) {
        throw StateError('Saved template identity changed. Review the local draft.');
      }
      editor.restore(current);
    }
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => IdCardDesignerScreen(
          designer: editor,
          templateVersion: 'manifest-v1:${entry.id}',
          onSave: (draft) async {
            checkSchool();
            await store.saveDraft(draft);
            checkSchool();
          },
        ),
      ),
    );
  }
}
