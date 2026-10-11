import 'dart:convert';
import 'dart:io';

import '../../lib/id_card_designer.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void rejected(void Function() action) {
  var failed = false;
  try {
    action();
  } catch (_) {
    failed = true;
  }
  require(failed, 'Invalid edit was accepted');
}

void main() {
  final raw = Map<String, dynamic>.from(
    jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync())
        as Map,
  );
  final d = IdCardDesigner(schoolId: 'own-school', manifest: raw);
  final before = jsonEncode(d.snapshot);
  final photo = d.template.regions.firstWhere((r) => r.key == 'photo');
  d.editRegion(photo.side, photo.key, {'focusX': 0.25, 'focusY': 0.4});
  require(
    d.template.regions.firstWhere((r) => r.key == 'photo').focusX == 0.25,
    'Crop focus lost',
  );
  d.undo();
  require(jsonEncode(d.snapshot) == before, 'Undo differs');
  d.redo();
  require(d.canUndo, 'Redo lost');
  final accepted = jsonEncode(d.snapshot);
  rejected(() => d.move(photo.side, photo.key, -50, 0));
  rejected(() => d.resize(photo.side, photo.key, 100000, 100000));
  rejected(() => d.editRegion(photo.side, photo.key, {'focusX': 2}));
  require(jsonEncode(d.snapshot) == accepted, 'Rejected edit changed draft');
  final copy = d.snapshot;
  (copy['regions'] as List).clear();
  require(d.template.regions.isNotEmpty, 'Mutable snapshot leaked');
  final draft = d.exportDraft(templateVersion: 'v1');
  rejected(() => d.restore({...draft, 'schoolId': 'foreign'}));
  d.undo();
  d.editRegion(photo.side, photo.key, {'focusX': 0.6});
  require(!d.canRedo, 'Redo branch not discarded');
  rejected(() => d.editRegion(photo.side, photo.key, {'key': 'changed'}));
  rejected(() => d.move(photo.side, photo.key, 1, 1, grid: 0));
  print(
    'PASS designer geometry, crop, undo/redo, isolation and immutable snapshots',
  );
}
