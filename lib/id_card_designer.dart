import 'dart:convert';

import 'id_card_manifest.dart';

/// School-scoped draft editor. Persistence and UI activation are separate.
/// Every accepted edit passes the same manifest geometry rules as PDF rendering.
class IdCardDesigner {
  IdCardDesigner({
    required this.schoolId,
    required Map<String, dynamic> manifest,
  }) {
    if (schoolId.trim().isEmpty)
      throw ArgumentError('School identity required');
    _validate(manifest);
    _history.add(jsonEncode(manifest));
  }
  final String schoolId;
  final List<String> _history = [];
  int _cursor = 0;
  bool get canUndo => _cursor > 0;
  bool get canRedo => _cursor < _history.length - 1;
  Map<String, dynamic> get snapshot =>
      Map<String, dynamic>.from(jsonDecode(_history[_cursor]) as Map);
  IdCardManifest get template => IdCardManifest.fromJson(snapshot);
  void _validate(Map<String, dynamic> value) => IdCardManifest.fromJson(value);
  void _commit(Map<String, dynamic> value) {
    _validate(value);
    final encoded = jsonEncode(value);
    if (encoded == _history[_cursor]) return;
    _history.removeRange(_cursor + 1, _history.length);
    _history.add(encoded);
    if (_history.length > 101) _history.removeAt(0);
    _cursor = _history.length - 1;
  }

  void undo() {
    if (canUndo) _cursor--;
  }

  void redo() {
    if (canRedo) _cursor++;
  }

  void editRegion(String side, String key, Map<String, dynamic> changes) {
    if (changes.keys.any(
      (k) => !{
        'x',
        'y',
        'width',
        'height',
        'fontSize',
        'minFontSize',
        'focusX',
        'focusY',
        'padding',
        'fit',
        'align',
        'wrap',
        'maxLines',
        'overflow',
        'label',
      }.contains(k),
    ))
      throw ArgumentError('Unsupported region edit');
    final value = snapshot;
    final regions = (value['regions'] as List).cast<Map>();
    final targets = regions.where((r) => r['side'] == side && r['key'] == key);
    if (targets.length != 1) throw StateError('Region identity mismatch');
    targets.single.addAll(changes);
    _commit(value);
  }

  void move(String side, String key, double x, double y, {double grid = 1}) {
    if (!grid.isFinite || grid <= 0 || !x.isFinite || !y.isFinite) {
      throw ArgumentError('Finite coordinates and positive snap grid required');
    }
    editRegion(side, key, {
      'x': (x / grid).round() * grid,
      'y': (y / grid).round() * grid,
    });
  }

  void resize(String side, String key, double width, double height) =>
      editRegion(side, key, {'width': width, 'height': height});

  /// Restore only a draft belonging to the same school and declared schema.
  void restore(Map<String, dynamic> envelope) {
    if (envelope['version'] != 1 ||
        envelope['schoolId'] != schoolId ||
        envelope['manifest'] is! Map)
      throw StateError('Foreign or invalid designer draft');
    _commit(Map<String, dynamic>.from(envelope['manifest'] as Map));
  }

  Map<String, dynamic> exportDraft({required String templateVersion}) {
    if (templateVersion.trim().isEmpty)
      throw ArgumentError('Template version required');
    return {
      'version': 1,
      'schoolId': schoolId,
      'templateVersion': templateVersion,
      'manifest': snapshot,
    };
  }
}
