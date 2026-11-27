import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'windows_local_firestore.dart';
import 'windows_connect/managed_school_session.dart';
import 'school_image_input.dart';
import 'package:crypto/crypto.dart';

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

  static const greenBlueId = 'student-green-blue-modern-v1';
  static const greenBlueAsset = 'assets/student_green_blue_modern_front.png';
  static const greenBlueSha256 = '08912d18ce48222ac150f0b3bd3189270ad96534e7764d243d8456d8d243e2b9';
  static bool isApprovedGreenBlueArtwork(Uint8List bytes) =>
      bytes.length == 337769 && sha256.convert(bytes).toString() == greenBlueSha256;

  Future<bool> hasApprovedGreenBlueArtwork() async {
    if (id != greenBlueId) return true;
    if (frontAsset != greenBlueAsset || backAsset != null) return false;
    final assets = await AssetManifest.loadFromAssetBundle(rootBundle);
    if (!assets.listAssets().contains(greenBlueAsset)) return false;
    final bytes = await rootBundle.load(greenBlueAsset);
    return isApprovedGreenBlueArtwork(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
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
  static bool isGlobalId(String id)=>RegExp(r'^gid-[a-f0-9]{32}$').hasMatch(id);
  static Future<List<IdCardCatalogEntry>> load() async {
    final builtIn=await (_loaded ??= _load());
    final remote=await _GlobalIdCatalog.read();
    return [...builtIn,...remote];
  }
  /// Recheck authorization immediately before explicit global export.
  /// No offline premium unlock is provided by this initial implementation.
  static Future<void> requireGlobalAccess(String id) async {
    if(!isGlobalId(id))return;
    final entry=await find(id);
    if(entry is! _GlobalIdCatalogEntry)throw StateError('Global template unavailable');
    await entry.authorize();
  }
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
    final available = <IdCardCatalogEntry>[];
    for (final entry in result) {
      if (await entry.hasApprovedGreenBlueArtwork()) available.add(entry);
    }
    return available;
  }

  static Future<IdCardCatalogEntry> find(String id) async =>
      (await load()).firstWhere(
        (e) => e.id == id,
        orElse: () => throw const FormatException('Unknown ID template.'),
      );
}

class _GlobalIdCatalog {
  static String? _scope;
  static DateTime? _checked;
  static List<_GlobalIdCatalogEntry> _entries=[];
  static Future<List<_GlobalIdCatalogEntry>>? _inFlight;
  static Future<List<_GlobalIdCatalogEntry>> read() async {
    if(kIsWeb||defaultTargetPlatform!=TargetPlatform.windows)return [];
    final db=FirebaseFirestore.instance;
    final origin=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school))return [];
    final scope=jsonEncode([origin,school]);
    bool current()=>db.activeProfileId==origin&&db.activeProfileIdentity['schoolSyncId']==school;
    if(_scope!=scope){_scope=scope;_checked=null;_entries=[];_inFlight=null;}
    final previous=_checked;
    if(previous!=null&&DateTime.now().difference(previous)<const Duration(seconds:60))return current()?_entries:[];
    final existing=_inFlight;
    if(existing!=null){final value=await existing;return current()?value:[];}
    final future=()async{
      try{
        final reply=await ManagedSchoolSession.callForSchool(school,'managed/id-library/list',{});
        if(!current()||reply['schoolId']!=school||reply['success']!=true)return <_GlobalIdCatalogEntry>[];
        final raw=reply['templates'];
        if(raw is! List||raw.length>200)throw const FormatException('Invalid global catalog');
        final seen=<String>{};
        final entries=<_GlobalIdCatalogEntry>[];
        for(final value in raw){
          final row=Map<String,dynamic>.from(value as Map);
          final id=row['id'];
          if(id is! String||!IdCardCatalog.isGlobalId(id)||!seen.add(id))throw const FormatException('Invalid global template identity');
          if(row['unlocked']!=true||row['accessType']!='free'||row['pricePaise']!=0)continue;
          final entry=_GlobalIdCatalogEntry(row,origin,school);
          // Keep the same immutable package in memory across unchanged refreshes.
          final old=_entries.where((e)=>e.id==id&&e.packageHash==entry.packageHash);
          entries.add(old.isEmpty?entry:old.first);
        }
        entries.sort((a,b)=>a.id.compareTo(b.id));
        if(current()&&_scope==scope){_entries=entries;_checked=DateTime.now();}
        return entries;
      }catch(_){
        // Built-ins remain usable. No stale/unverified remote template is unlocked.
        if(current()&&_scope==scope){_entries=[];_checked=DateTime.now();}
        return <_GlobalIdCatalogEntry>[];
      }
    }();
    _inFlight=future;
    try{final value=await future;return current()?value:[];}
    finally{if(identical(_inFlight,future))_inFlight=null;}
  }
}

class _GlobalIdCatalogEntry extends IdCardCatalogEntry {
  _GlobalIdCatalogEntry(Map<String,dynamic> row,this.origin,this.school):
    packageHash=row['packageSha256'] as String,version=row['version'] as int,
    super({'id':row['id'],'name':row['name'],'kinds':[row['kind']],
      'manifest':'assets/global_id_card_placeholder.json'}) {
    if(version!=1||!RegExp(r'^[a-f0-9]{64}$').hasMatch(packageHash)||
      row['state']!='published'||row['mappingState']!='verified')throw const FormatException('Invalid global template metadata');
  }
  final String origin,school,packageHash;
  final int version;
  ({IdCardManifest manifest,Map<String,Uint8List> backgrounds})? _prepared;
  Future<({IdCardManifest manifest,Map<String,Uint8List> backgrounds})>? _pending;
  void _guard(){
    final db=FirebaseFirestore.instance;
    if(db.activeProfileId!=origin||db.activeProfileIdentity['schoolSyncId']!=school)throw StateError('School changed during global ID access');
  }
  Future<void> authorize() async{
    _guard();
    final reply=await ManagedSchoolSession.callForSchool(school,'managed/id-library/access',{'id':id,'version':version});
    _guard();
    if(reply['schoolId']!=school||reply['success']!=true||reply['packageSha256']!=packageHash)throw StateError('Global template changed or access revoked');
  }
  Future<({IdCardManifest manifest,Map<String,Uint8List> backgrounds})> _package() async{
    _guard();
    final saved=_prepared;
    if(saved!=null)return saved;
    if(_pending!=null){final result=await _pending!;_guard();return result;}
    final future=()async{
      final reply=await ManagedSchoolSession.callForSchool(school,'managed/id-library/package',{'id':id,'version':version});
      _guard();
      if(reply['schoolId']!=school||reply['success']!=true||reply['packageSha256']!=packageHash)throw StateError('Global package identity mismatch');
      final encoded=reply['packageBase64'];
      if(encoded is! String||encoded.length>11200000)throw const FormatException('Global package too large');
      final bytes=base64Decode(encoded);
      if(bytes.length>8*1024*1024||sha256.convert(bytes).toString()!=packageHash)throw const FormatException('Global package checksum mismatch');
      final data=Map<String,dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      final manifest=IdCardManifest.fromJson(Map<String,dynamic>.from(data['manifest'] as Map));
      if(manifest.id!=id)throw const FormatException('Global manifest identity mismatch');
      final raw=Map<String,dynamic>.from(data['backgrounds'] as Map);
      if(!raw.containsKey('front')||raw.containsKey('back')!=manifest.hasBack||raw.length!=(manifest.hasBack?2:1))throw const FormatException('Global artwork sides mismatch');
      final images=<String,Uint8List>{for(final e in raw.entries)e.key:base64Decode(e.value as String)};
      for(final image in images.values){SchoolImageInput.validate(image);}
      _guard();
      return (manifest:manifest,backgrounds:Map<String,Uint8List>.unmodifiable(images));
    }();
    _pending=future;
    try{final result=await future;_guard();_prepared=result;return result;}
    finally{if(identical(_pending,future))_pending=null;}
  }
  @override Future<IdCardManifest> manifest() async=>(await _package()).manifest;
  @override Future<Map<String,Uint8List>> backgrounds() async=>{for(final e in (await _package()).backgrounds.entries)e.key:Uint8List.fromList(e.value)};
}
