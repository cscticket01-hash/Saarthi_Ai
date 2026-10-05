import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/platform/platform_config.dart';
import '../lib/school_cloud_engine.dart';
import '../lib/windows_secure_storage.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_managed_school_gate.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  final now=DateTime.utc(2026,10,6);
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  Map<String,dynamic> access({String status='licensed',bool allowed=true,bool activated=true})=>{
    'success':true,'schoolId':school,'uid':'A','projectId':platformProjectId,
    'allowed':allowed,'activated':activated,'status':status,
    'expiresAt':now.add(const Duration(days:5)).millisecondsSinceEpoch,
    'serverTime':now.millisecondsSinceEpoch};
  Map<String,dynamic> identity(Map<String,dynamic>? lease)=>{
    'managed':true,'schoolId':school,'uid':'A','projectId':platformProjectId,
    if(lease!=null)'verifiedAccess':lease};
  SchoolCloudEngine engine(Map<String,dynamic> saved,{Future<Map<String,dynamic>> Function()? verify,
    Future<void> Function(Map<String,dynamic>,Map<String,dynamic>)? persist})=>SchoolCloudEngine(
      readIdentity:()async=>saved,clock:()=>now,activateLocal:()async{},legacyAccess:()async=>null,
      verify:verify??()async=>throw const SocketException('offline'),persist:persist??(a,b)async{});
  test('existing authenticated school restores locally without waiting for cloud',()async{
    final cloud=Completer<Map<String,dynamic>>();final e=engine(identity(access()),verify:()=>cloud.future);
    await e.restore();expect(e.canOpen,true);expect(e.restoring,false);
    cloud.completeError(const SocketException('offline'));await Future<void>.delayed(Duration.zero);
    expect(e.canOpen,true);expect(e.state,SchoolCloudState.offline);e.dispose();
  });
  test('trial works offline, expired, blocked and unactivated leases never open',()async{
    for(final lease in [access(status:'trial',activated:false),access()]){
      final e=engine(identity(lease));await e.restore();expect(e.canOpen,true);e.dispose();
    }
    for(final lease in [access(allowed:false,status:'blocked'),access(activated:false),
      {...access(),'expiresAt':now.millisecondsSinceEpoch},
      {...access(),'serverTime':now.add(const Duration(hours:1)).millisecondsSinceEpoch}]){
      final e=engine(identity(lease));await e.restore();expect(e.canOpen,false);e.dispose();
    }
  });
  test('first install and foreign school/UID caches cannot authenticate locally',()async{
    for(final saved in [<String,dynamic>{},identity(null),identity({...access(),'uid':'B'}),
      identity({...access(),'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'})]){
      final e=engine(saved);await e.restore();expect(e.canOpen,false);e.dispose();
    }
  });
  test('real central denial persists while network failures preserve last verified access',()async{
    for(final status in [401,403]){
      Map<String,dynamic>? persisted;
      final e=engine(identity(access()),verify:()async=>throw CentralCloudException(status,'school_cloud','denied'),
        persist:(a,b)async{persisted=b;});
      await e.restore();await Future<void>.delayed(Duration.zero);
      expect(e.canOpen,false);expect(persisted?['allowed'],false);e.dispose();
      final restart=engine(identity(persisted!));await restart.restore();expect(restart.canOpen,false);restart.dispose();
    }
    final e=engine(identity(access()),verify:()async=>throw const CentralCloudException(503,'school_cloud','unavailable'));
    await e.restore();await Future<void>.delayed(Duration.zero);expect(e.canOpen,true);e.dispose();
  });
  test('failed verification retries and refreshes real licence status',()async{
    var calls=0;final e=engine(identity(access()),verify:()async{
      if(calls++==0)throw const SocketException('offline');return access(status:'trial',activated:false);
    });
    await e.restore();await Future<void>.delayed(Duration.zero);expect(e.state,SchoolCloudState.offline);
    await e.verify();expect(e.canOpen,true);expect(e.access?['status'],'trial');e.dispose();
  });
  test('an older school verification cannot install access in a newer school session',()async{
    final pending=Completer<Map<String,dynamic>>();var writes=0;
    var saved=identity(access());
    final e=SchoolCloudEngine(readIdentity:()async=>saved,verify:()=>pending.future,
      activateLocal:()async{},legacyAccess:()async=>null,clock:()=>now,persist:(a,b)async{writes++;});
    await e.restore();saved={'managed':true,'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb','uid':'B','projectId':platformProjectId};
    await e.restore();pending.complete(access());await Future<void>.delayed(Duration.zero);
    expect(e.canOpen,false);expect(e.identity?['uid'],'B');expect(writes,0);e.dispose();
  });
  test('secure storage queue serializes operations and recovers after an error',()async{
    final held=Completer<void>();final order=<String>[];
    final first=WindowsSecureStorage.run(()async{order.add('first');await held.future;throw StateError('failure');});
    final failure=expectLater(first,throwsStateError);
    final second=WindowsSecureStorage.run(()async{order.add('second');return 'saved';});
    await Future<void>.delayed(Duration.zero);expect(order,['first']);held.complete();
    await failure;expect(await second,'saved');expect(order,['first','second']);
  });
  test('sharing violation retries safely without deleting credentials',()async{
    var attempts=0;
    expect(await WindowsSecureStorage.run(()async{
      if(attempts++<2)throw const FileSystemException('sharing violation','credential-file',OSError('busy',32));
      return 'retained';
    }),'retained');expect(attempts,3);
    expect(WindowsSecureStorage.sharingViolation(const FileSystemException('denied','path',OSError('denied',5))),false);
  });
  testWidgets('cached school stays in local UI after cloud fails; no login or blocking connection screen',(tester)async{
    final pending=Completer<Map<String,dynamic>>();final e=engine(identity(access()),verify:()=>pending.future);
    await tester.pumpWidget(MaterialApp(home:WindowsManagedSchoolGate(engine:e,child:const Text('Local School Console'),legacy:const Text('Legacy'))));
    await tester.pump();await tester.pump();expect(find.text('Local School Console'),findsOneWidget);
    pending.completeError(const SocketException('offline'));await tester.pump();await tester.pump();
    expect(find.text('Local School Console'),findsOneWidget);expect(find.text('School Login'),findsNothing);
    expect(find.textContaining('Offline / Sync pending'),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
