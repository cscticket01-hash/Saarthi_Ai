import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../lib/mobile/school_session.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../lib/mobile/session_cache_store.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();sqfliteFfiInit();
  late Directory directory;late MobileSessionCacheStore foreground,background;
  Future<Database> open()=>databaseFactoryFfi.openDatabase('${directory.path}/session.db',options:OpenDatabaseOptions(
    version:1,singleInstance:false,onConfigure:(db)async{await db.execute('PRAGMA busy_timeout=5000');await db.execute('PRAGMA synchronous=FULL');},
    onCreate:(db,_)=>MobileSessionCacheStore.createSchema(db)));
  setUp(()async{FlutterSecureStorage.setMockInitialValues({});directory=await Directory.systemTemp.createTemp('vs-shared-session');foreground=MobileSessionCacheStore(openDatabaseOverride:open);background=MobileSessionCacheStore(openDatabaseOverride:open);});
  tearDown(()async{await foreground.close();await background.close();await directory.delete(recursive:true);});
  String snapshot(String revision,{String qr='school-A/person-1'})=>jsonEncode({'qr':qr,'schoolToken':'PRIVATE_SESSION_TOKEN','dashboard':{'revision':revision}});
  test('independent connections reject stale writes and a newer read grants no stale-payload write',()async{
    final a=await foreground.readSnapshot(),b=await background.readSnapshot();
    await foreground.write(snapshot('first'),expectedVersion:a.version);
    await expectLater(background.write(snapshot('stale'),expectedVersion:b.version),throwsA(isA<StaleSessionCache>()));
    final fresh=await background.readSnapshot();await background.write(snapshot('second'),expectedVersion:fresh.version);
    await foreground.readSnapshot();
    await expectLater(foreground.write(snapshot('old-payload'),expectedVersion:a.version),throwsA(isA<StaleSessionCache>()));
    expect(jsonDecode((await foreground.read())!)['dashboard']['revision'],'second');
  });
  test('logout tombstone survives restart and blocks an older worker resurrecting identity',()async{
    await foreground.read();await foreground.write(snapshot('first'));
    final old=await background.readSnapshot();await foreground.clear('school-A/person-1');
    await expectLater(background.write(snapshot('resurrect'),expectedVersion:old.version),throwsA(isA<StaleSessionCache>()));
    await foreground.close();foreground=MobileSessionCacheStore(openDatabaseOverride:open);
    await const FlutterSecureStorage().write(key:'vs_mobile_session',value:snapshot('old-legacy-copy'));
    expect(await foreground.read(),isNull);
  });
  test('an older account cannot clear a newer different-school login',()async{
    await foreground.read();await foreground.write(snapshot('A'));await background.read();
    final now=await foreground.readSnapshot();await foreground.write(snapshot('B',qr:'school-B/person-2'),expectedVersion:now.version);
    await expectLater(background.clear('school-A/person-1'),throwsA(isA<StaleSessionCache>()));
    expect(jsonDecode((await foreground.read())!)['qr'],'school-B/person-2');
  });
  test('legacy cache migrates once and session/QR/key are absent from SQLite envelope',()async{
    await const FlutterSecureStorage().write(key:'vs_mobile_session',value:snapshot('legacy'));
    final original=await foreground.readSnapshot();expect(jsonDecode(original.value!)['dashboard']['revision'],'legacy');
    await foreground.write(snapshot('verified'),expectedVersion:original.version);
    expect(await const FlutterSecureStorage().read(key:'vs_mobile_session'),isNull);
    final rows=await (await foreground.database).query('session_snapshot');final raw=jsonEncode(rows);
    expect(raw, isNot(contains('PRIVATE_SESSION_TOKEN')));expect(raw,isNot(contains('school-A')));
    expect(await background.read(),snapshot('verified'));
  });
  test('corrupt authenticated ciphertext fails closed and retains the row',()async{
    await foreground.read();await foreground.write(snapshot('verified'));
    final db=await foreground.database;await db.update('session_snapshot',{'envelope':'{"nonce":"bad","cipher":"bad","mac":"bad"}'},where:'id=1');
    await expectLater(background.read(),throwsA(anything));
    expect((await db.query('session_snapshot')).length,1);
  });
  test('foreground adopts background verified cache before requesting the next delta',()async{
    final fixture=Map<String,dynamic>.from((jsonDecode(File('test/fixtures/windows_person_qr.json').readAsStringSync()) as List).first);
    final school=fixture['schoolId'];var revision='first';var observed='';
    Map<String,dynamic> response(Map<String,dynamic> data)=>{'success':true,'schoolId':school,'projectId':school,...data};
    http.Client client()=>MockClient((request)async{
      final body=jsonDecode(request.body)['request'] as Map;
      if(body['action']=='mobile_login')return http.Response(jsonEncode(response({'sessionToken':'verified-session','expiresAt':DateTime.now().add(const Duration(hours:1)).millisecondsSinceEpoch,'person':{'name':'Own student'},'schoolName':'Own school'})),200);
      if(body['action']=='mobile_dashboard'){
        observed=body['knownRevision']?.toString()??'';
        return http.Response(jsonEncode(response({'revision':revision,'notices':[]})),200);
      }
      return http.Response(jsonEncode(response({})),200);
    });
    final front=SchoolSession(client:client(),sharedSessionStore:foreground);
    final back=SchoolSession(client:client(),sharedSessionStore:background);
    await front.login(SchoolLink.parse(SchoolLink.encodeCompact(fixture)));
    await front.refreshDashboard();
    await back.restore();revision='second';await back.refreshDashboard();
    revision='third';await front.refreshDashboard();
    expect(observed,'second');expect(front.dashboard['revision'],'third');
    await back.clear();
    await expectLater(front.refreshDashboard(),throwsA(isA<SchoolAccessDenied>()));
    expect(front.loggedIn,false);expect(front.dashboard,isEmpty);
    await front.closeBackgroundInvocation();await back.closeBackgroundInvocation();
  });

}
