import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'windows_secure_storage.dart';
import 'windows_connect/central_school_cloud.dart';
import 'global_id_card_offline_policy.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'windows_local_firestore.dart';
import 'windows_connect/managed_school_session.dart';
import 'school_image_input.dart';
import 'package:crypto/crypto.dart';

import 'id_card_manifest.dart';
import 'id_card_identity.dart';

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

  static const greenBlueId = IdCardIdentity.greenBlueId;
  static const greenBlueAsset = 'assets/student_green_blue_modern_front.png';
  static const greenBlueSha256 = IdCardIdentity.greenBlueSha256;
  static bool isApprovedGreenBlueArtwork(Uint8List bytes) =>
      IdCardIdentity.isApprovedGreenBlueArtwork(bytes);

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
  static bool isGlobalId(String id)=>IdCardIdentity.isGlobalId(id);
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

  static Future<IdCardCatalogEntry> find(String id) async {
    final entries=isGlobalId(id)?await _GlobalIdCatalog.read():await (_loaded ??= _load());
    return entries.firstWhere((e)=>e.id==id,orElse:()=>throw const FormatException('Unknown ID template.'));
  }
}

class _GlobalIdCatalog {
  static String? _scope;
  static DateTime? _checked;
  static int _expiresAt=0;
  static List<_GlobalIdCatalogEntry> _entries=[];
  static Future<List<_GlobalIdCatalogEntry>>? _inFlight;
  static const _storage=WindowsSecureStorage();
  static bool temporary(Object e)=>e is SocketException||e is TimeoutException||
    e is http.ClientException||(e is CentralCloudException&&!e.authoritativeAccessDenial&&(e.status==429||e.status>=500));
  static String keyFor(String scope)=>'global_id_free_catalog_v1_'+sha256.convert(utf8.encode(scope)).toString();
  static Future<void> invalidate(String scope) async{
    if(_scope==scope){_entries=[];_checked=null;_expiresAt=0;}
    try{await _storage.delete(key:keyFor(scope));}catch(_){}
  }
  static Future<Map<String,dynamic>?> offline(String scope,String school,String uid) async{
    try{
      final raw=await _storage.read(key:keyFor(scope));
      if(raw==null||raw.length>256*1024)return null;
      final value=Map<String,dynamic>.from(jsonDecode(raw) as Map);
      return GlobalIdCardOfflinePolicy.valid(value,school:school,uid:uid,nowMs:DateTime.now().millisecondsSinceEpoch)?value:null;
    }catch(_){return null;}
  }
  static Future<List<_GlobalIdCatalogEntry>> read() async {
    if(kIsWeb||defaultTargetPlatform!=TargetPlatform.windows)return [];
    final db=FirebaseFirestore.instance;
    final origin=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school))return [];
    bool current()=>db.activeProfileId==origin&&db.activeProfileIdentity['schoolSyncId']==school;
    Map<String,dynamic> session;
    try{session=await CentralSchoolCloud.saved();}catch(_){return [];}
    final uid=session['uid']?.toString()??'',endpoint=session['endpoint']?.toString()??'';
    if(!current()||session['managed']!=true||session['schoolId']!=school||uid.isEmpty||endpoint.isEmpty)return [];
    final scope=jsonEncode([origin,school,uid,endpoint]);
    if(_scope!=scope){_scope=scope;_checked=null;_expiresAt=0;_entries=[];_inFlight=null;}
    final previous=_checked,now=DateTime.now();
    if(previous!=null&&!now.isBefore(previous)&&now.difference(previous)<const Duration(seconds:60)&&now.millisecondsSinceEpoch<_expiresAt)return current()?_entries:[];
    final existing=_inFlight;
    if(existing!=null){final value=await existing;return current()&&_scope==scope?value:[];}
    final future=()async{
      try{
        Map<String,dynamic> reply;
        try{
          reply=await ManagedSchoolSession.callForSchool(school,'managed/id-library/list',{}).timeout(const Duration(seconds:25));
        }catch(e){
          if(!temporary(e)){await invalidate(scope);rethrow;}
          final cached=await offline(scope,school,uid);
          if(cached==null)rethrow;
          reply=cached;
        }
        if(!current()||_scope!=scope)return <_GlobalIdCatalogEntry>[];
        if(!GlobalIdCardOfflinePolicy.valid(reply,school:school,uid:uid,nowMs:DateTime.now().millisecondsSinceEpoch)){
          await invalidate(scope);return <_GlobalIdCatalogEntry>[];
        }
        final entries=<_GlobalIdCatalogEntry>[];
        for(final value in reply['templates'] as List){
          final row=Map<String,dynamic>.from(value as Map);
          if(!GlobalIdCardOfflinePolicy.freeRow(row))continue;
          final entry=_GlobalIdCatalogEntry(row,origin,school,uid,endpoint,scope);
          final old=_entries.where((e)=>e.id==entry.id&&e.packageHash==entry.packageHash&&e.name==entry.name);
          entries.add(old.isEmpty?entry:old.first);
        }
        // Store only server-authorized free metadata; never extend an offline
        // lease or persist any premium authorization.
        final cached=<String,dynamic>{'success':true,'schoolId':school,'uid':uid,
          'serverTime':reply['serverTime'],'expiresAt':reply['expiresAt'],'paymentEnabled':false,
          'templates':(reply['templates'] as List).where((v)=>v is Map&&GlobalIdCardOfflinePolicy.freeRow(Map<String,dynamic>.from(v))).toList()};
        try{await _storage.write(key:keyFor(scope),value:jsonEncode(cached));}
        catch(_){/* Current verified online operation can still proceed. */}
        entries.sort((a,b)=>a.name.compareTo(b.name));
        if(current()&&_scope==scope){_entries=entries;_checked=DateTime.now();_expiresAt=reply['expiresAt'] as int;}
        return current()&&_scope==scope?entries:<_GlobalIdCatalogEntry>[];
      }catch(_){
        if(current()&&_scope==scope){_entries=[];_checked=null;_expiresAt=0;}
        return <_GlobalIdCatalogEntry>[];
      }
    }();
    _inFlight=future;
    try{final value=await future;return current()&&_scope==scope?value:[];}
    finally{if(identical(_inFlight,future))_inFlight=null;}
  }
}

class _GlobalIdCatalogEntry extends IdCardCatalogEntry {
  _GlobalIdCatalogEntry(Map<String,dynamic> row,this.origin,this.school,this.uid,this.endpoint,this.scope):
    packageHash=row['packageSha256'] as String,version=row['version'] as int,
    super({'id':row['id'],'name':row['isCurrent']==true&&row['version']==1?row['name']:'${row['name']} • v${row['version']}${row['isCurrent']==true?'':' (previous)'}','kinds':[row['kind']],
      'manifest':'assets/global_id_card_placeholder.json'}) {
    if(version<1||version>10000||!RegExp(r'^[a-f0-9]{64}$').hasMatch(packageHash)||
      row['state']!='published'||row['mappingState']!='verified')throw const FormatException('Invalid global template metadata');
  }
  final String origin,school,uid,endpoint,scope,packageHash;
  final int version;
  ({IdCardManifest manifest,Map<String,Uint8List> backgrounds})? _prepared;
  Future<({IdCardManifest manifest,Map<String,Uint8List> backgrounds})>? _pending;
  void _guard(){
    final db=FirebaseFirestore.instance;
    if(db.activeProfileId!=origin||db.activeProfileIdentity['schoolSyncId']!=school)throw StateError('School changed during global ID access');
  }
  Future<void> _accountGuard() async{
    _guard();
    final session=await CentralSchoolCloud.saved();
    _guard();
    if(session['managed']!=true||session['schoolId']!=school||session['uid']!=uid||
       session['endpoint']!=endpoint)throw StateError('Global template account changed');
  }
  Future<void> authorize() async{
    await _accountGuard();
    try{
      final reply=await ManagedSchoolSession.callForSchool(school,'managed/id-library/access',{'id':id,'version':version}).timeout(const Duration(seconds:25));
      await _accountGuard();
      if(reply['schoolId']!=school||reply['success']!=true||reply['packageSha256']!=packageHash)throw StateError('Global template changed or access revoked');
    }catch(e){
      if(!_GlobalIdCatalog.temporary(e)){await _GlobalIdCatalog.invalidate(scope);rethrow;}
      await _accountGuard();
      final cached=await _GlobalIdCatalog.offline(scope,school,uid);
      if(cached==null||!GlobalIdCardOfflinePolicy.contains(cached,id:id,version:version,hash:packageHash))rethrow;
    }
  }
  Future<File> _cacheFile() async{
    final root=await getApplicationSupportDirectory();
    _guard();
    final scopeHash=sha256.convert(utf8.encode(scope)).toString();
    final folder=Directory('${root.path}${Platform.pathSeparator}global_id_card_cache_v1${Platform.pathSeparator}$scopeHash');
    await folder.create(recursive:true);
    _guard();
    return File('${folder.path}${Platform.pathSeparator}$id-$version-$packageHash.json');
  }
  ({IdCardManifest manifest,Map<String,Uint8List> backgrounds}) _decodePackage(Uint8List bytes){
    if(bytes.length>8*1024*1024||sha256.convert(bytes).toString()!=packageHash)throw const FormatException('Global package checksum mismatch');
    final data=Map<String,dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    final manifest=IdCardManifest.fromJson(Map<String,dynamic>.from(data['manifest'] as Map));
    if(manifest.id!=id)throw const FormatException('Global manifest identity mismatch');
    final raw=Map<String,dynamic>.from(data['backgrounds'] as Map);
    if(!raw.containsKey('front')||raw.containsKey('back')!=manifest.hasBack||raw.length!=(manifest.hasBack?2:1))throw const FormatException('Global artwork sides mismatch');
    final images=<String,Uint8List>{for(final e in raw.entries)e.key:base64Decode(e.value as String)};
    for(final image in images.values){SchoolImageInput.validate(image);}
    return (manifest:manifest,backgrounds:Map<String,Uint8List>.unmodifiable(images));
  }
  Future<({IdCardManifest manifest,Map<String,Uint8List> backgrounds})> _package() async{
    await _accountGuard();
    final saved=_prepared;
    if(saved!=null)return saved;
    if(_pending!=null){final result=await _pending!;_guard();return result;}
    final future=()async{
      // Authorize online or via an unexpired secure free-only catalog lease.
      // Missing cached artwork must still be downloaded online.
      await authorize();
      File? cache;
      try{
        cache=await _cacheFile();
        if(await cache.exists()&&await cache.length()<=8*1024*1024){
          final result=_decodePackage(await cache.readAsBytes());
          _guard();return result;
        }
      }catch(_){/* Cache failures must not replace or unlock remote templates. */}
      _guard();
      final reply=await ManagedSchoolSession.callForSchool(school,'managed/id-library/package',{'id':id,'version':version});
      _guard();
      if(reply['schoolId']!=school||reply['success']!=true||reply['packageSha256']!=packageHash)throw StateError('Global package identity mismatch');
      final encoded=reply['packageBase64'];
      if(encoded is! String||encoded.length>11200000)throw const FormatException('Global package too large');
      final bytes=base64Decode(encoded);
      final result=_decodePackage(bytes);
      _guard();
      if(cache!=null){
        File? temporary;
        try{
          // Only reviewed clean artwork and manifest; no person data or secrets.
          temporary=File('${cache.path}.tmp');
          await temporary.writeAsBytes(bytes,flush:true);
          _guard();
          await temporary.rename(cache.path);
        }catch(_){try{if(temporary!=null&&await temporary.exists())await temporary.delete();}catch(_){}}
      }
      _guard();return result;
    }();
    _pending=future;
    try{final result=await future;_guard();_prepared=result;return result;}
    finally{if(identical(_pending,future))_pending=null;}
  }
  @override Future<IdCardManifest> manifest() async=>(await _package()).manifest;
  @override Future<Map<String,Uint8List>> backgrounds() async=>{for(final e in (await _package()).backgrounds.entries)e.key:Uint8List.fromList(e.value)};
}
