import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'id_card_manifest.dart';

class IdCardCatalogEntry {
  IdCardCatalogEntry(Map<String, dynamic> data)
    : id = data['id'] as String,
      name = data['name'] as String,
      manifestAsset = data['manifest'] as String,
      kinds = List<String>.from(data['kinds'] as List),
      frontAsset = data['frontAsset']?.toString(),
      backAsset = data['backAsset']?.toString() {
    if (!RegExp(r'^[a-z][a-z0-9-]{1,80}$').hasMatch(id) ||
        name.isEmpty ||
        kinds.isEmpty ||
        kinds.any(
          (k) => !{'studentId', 'teacherId', 'otherStaffId'}.contains(k),
        ))
      throw const FormatException('Invalid ID catalog entry.');
    for (final path in [
      manifestAsset,
      frontAsset,
      backAsset,
    ].whereType<String>()) {
      if (!RegExp(r'^assets/[A-Za-z0-9_-]+\.(json|png|jpg|jpeg)$')
          .hasMatch(path))
        throw const FormatException('Template must use a bundled asset.');
    }
  }
  final String id, name, manifestAsset;
  final List<String> kinds;
  final String? frontAsset, backAsset;
  Future<IdCardManifest> manifest() async {
    final m = IdCardManifest.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(await rootBundle.loadString(manifestAsset)),
      ),
    );
    if (m.id != id)
      throw const FormatException('Catalog and manifest identity mismatch.');
    return m;
  }

  Future<Map<String, Uint8List>> backgrounds() async => {
    if (frontAsset != null)
      'front': (await rootBundle.load(frontAsset!)).buffer.asUint8List(),
    if (backAsset != null)
      'back': (await rootBundle.load(backAsset!)).buffer.asUint8List(),
  };
}

class IdCardCatalog {
  static Future<List<IdCardCatalogEntry>>? _loaded;
  static Future<List<IdCardCatalogEntry>> load() => _loaded ??= _load();
  static Future<List<IdCardCatalogEntry>> _load() async {
    final raw = jsonDecode(
      await rootBundle.loadString('assets/id_card_catalog.json'),
    );
    if (raw is! List || raw.length > 100)
      throw const FormatException('Invalid ID catalog.');
    final result = [
      for (final value in raw)
        IdCardCatalogEntry(Map<String, dynamic>.from(value as Map)),
    ];
    if (result.map((e) => e.id).toSet().length != result.length)
      throw const FormatException('Duplicate ID template.');
    // Every newly onboarded design must pass its geometry validation before it
    // becomes selectable. The gallery shows the actual rendered front/back pair.
    for (final entry in result) {
      await entry.manifest();
    }
    return result;
  }

  static Future<IdCardCatalogEntry> find(String id) async =>
      (await load()).firstWhere(
        (e) => e.id == id,
        orElse: () => throw const FormatException('Unknown ID template.'),
      );
}
