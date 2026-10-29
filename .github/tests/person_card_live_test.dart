import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';
import 'package:printing/src/interface.dart';
import 'package:printing/src/method_channel.dart';
import '../../lib/windows_connect/central_school_cloud.dart';
import '../../lib/windows_connect/managed_school_session.dart';
import '../../lib/windows_local_firestore.dart';
import '../../lib/windows_pending_school_sync.dart';
import '../../lib/windows_sync_dependencies.dart';
import '../../lib/windows_firebase_sync.dart';
import '../../lib/windows_backend_bridge.dart';
import '../../lib/windows_document_templates.dart';
import 'person_card_strategy.dart' as strategy;

class _CountingClient extends http.BaseClient {
  _CountingClient(this.delegate);
  final http.Client delegate;
  final actions = <String, int>{};
  @override Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request && request.url.path == '/school-cloud') {
      final body = jsonDecode(request.body) as Map;
      final key = '${body['action']}/${body['operation'] ?? ''}';
      actions[key] = (actions[key] ?? 0) + 1;
    }
    return delegate.send(request);
  }
  @override void close() {} // Per-request wrappers share this test connection.
}

/// Rasterize the actual generated PDF. No synthetic QR raster or fake bytes.
class _ActualPdfRaster extends MethodChannelPrinting {
  @override Stream<PdfRaster> raster(Uint8List document, List<int>? pages, double dpi) async* {
    final dir = await Directory.systemTemp.createTemp('card-raster-');
    try {
      final pdf = File('${dir.path}/card.pdf'); await pdf.writeAsBytes(document);
      final process = await Process.run('python', ['-c',
        'import fitz,sys,pathlib; d=fitz.open(sys.argv[1]); out=pathlib.Path(sys.argv[2]); scale=float(sys.argv[3])/72; '
        '[p.get_pixmap(matrix=fitz.Matrix(scale,scale),alpha=False).save(str(out/(str(i).zfill(3)+".png"))) for i,p in enumerate(d)]',
        pdf.path, dir.path, dpi.toString()]);
      if (process.exitCode != 0) throw StateError('Actual PDF raster failed.');
      final files = (await dir.list().toList()).whereType<File>().where((f) => f.path.endsWith('.png')).toList()
        ..sort((a,b) => a.path.compareTo(b.path));
      for (var i=0;i<files.length;i++) {
        if (pages != null && !pages.contains(i)) continue;
        final image = img.decodePng(await files[i].readAsBytes())!;
        yield PdfRaster(image.width,image.height,image.getBytes(order:img.ChannelOrder.rgba));
      }
    } finally { await dir.delete(recursive:true); }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('one teacher and one student include actual generated ID cards and permanent Drive proof', () async {
    const school='vs-db8afb01a3be46a983c8284714d06e5d';
    const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
    if (Platform.environment['GITHUB_ACTIONS']!='true' || Platform.environment['VS_PERSON_CARD_CONFIRM']!=school)
      throw StateError('Explicit isolated TEST person/card authorization required.');
    HttpOverrides.global=null; FlutterSecureStorage.setMockInitialValues({});
    final mode=Platform.environment['VS_PERSON_CARD_MODE']!;
    if (!{'before','after'}.contains(mode)) throw StateError('Unknown benchmark mode.');
    final report=<String,dynamic>{'status':'RUNNING','mode':mode,'schoolId':school,'samples':[],
      'scope':'Hosted Windows production owner helpers, SQLite, real generated PDF raster/QR checks, real TEST broker/Drive',
      'conditions':'One fresh teacher and one fresh student per mode; sequential runs; renderer adapter process overhead included; unrelated global reconciliation excluded.',
      'physicalDeviceVerified':false,'productionLoadCertified':false};
    final temp=await Directory.systemTemp.createTemp('person-cloud-');
    final delegate=http.Client(), printing=PrintingPlatform.instance;
    final client=_CountingClient(delegate),db=FirebaseFirestore.instance;
    var stage='runtime';
    try { await http.runWithClient(() async {
      final healthResponse=await client.get(Uri.parse('$endpoint/healthz'));
      final runtime=jsonDecode(healthResponse.body) as Map;
      if (healthResponse.statusCode!=200 || runtime['runtimeCommit']!=Platform.environment['VS_EXPECTED_TEST_RUNTIME'])
        throw StateError('TEST runtime mismatch.');
      report['runtimeCommit']=runtime['runtimeCommit'];
      report['comparisonAvailable']=false;
      report['measurementScope']='Candidate client against the installed isolated TEST broker/Script; not a before/after speed claim';
      stage='TEST login';
      final session=await ManagedSchoolSession.login(Platform.environment['VS_TEST_LOGIN_EMAIL']!,
        Platform.environment['VS_TEST_LOGIN_PASSWORD']!,endpoint:endpoint);
      if(session['schoolId']!=school||session['allowed']!=true)throw StateError('TEST membership unavailable.');
      final health=await ManagedSchoolSession.callForSchool(school,'managed/storage/check',{});
      report['installedScriptBundleVersion']=health['scriptBundleVersion'];
      report['candidateScriptVerified']=health['scriptBundleVersion']=='2026-10-29.1'&&health['recordLookupReuseVersion']==1;
      if(health['recordSyncVersion']!=2||health['uploadResumableVersion']!=1)throw StateError('TEST storage capability required.');
      WindowsFirebaseRemote.recordPointReadSupported=health['recordPointReadVersion']==1;
      WindowsFirebaseRemote.recordFieldPatchSupported=health['recordFieldPatchVersion']==1;
      final profile='person-${Platform.environment['GITHUB_RUN_ID']}-$mode';
      await db.changeLocalStorageLocation('${temp.path}/data');
      await db.switchProfile(profile,identity:{'schoolId':school,'schoolSyncId':school});
      await db.applySyncedDocument(db.collection('school_config').doc('school_profile_cache'),
        {'schoolId':school,'schoolName':'SYNTHETIC TIMING SCHOOL','principalName':'Synthetic Principal'});
      PrintingPlatform.instance=_ActualPdfRaster();
      for(final role in ['teacher','student']) {
        stage='$role person/card'; client.actions.clear();
        final collection=role=='student'?'students_directory':'teachers_directory';
        final id='pc-${Platform.environment['GITHUB_RUN_ID']}-$mode-$role';
        final timer=Stopwatch()..start(), sample=<String,dynamic>{'role':role,'id':id,'parentRequests':0};
        WindowsBackendBridge.onLocalDocumentCommitted=(){sample['cardQueuedMillis']=timer.elapsedMilliseconds;};
        await db.collection(collection).doc(id).set({'schoolId':school,'syntheticTest':true,'name':'SYNTHETIC $role $mode',
          'teacherId':id,'class':'10','section':'PC$mode','rollNo':(980000+int.parse(Platform.environment['GITHUB_RUN_ID']!)%10000).toString(),
          'dateOfBirth':'2015-01-01','parentName':'Synthetic parent'});
        sample['localSaveMillis']=timer.elapsedMilliseconds;
        Future<void> push() async {
          final canonical=<String,Map<String,dynamic>>{};
          await WindowsPendingSchoolSync.flush(profileId:profile, respectBackoff:true,
            send:(a,b,c,d)async=>throw StateError('Versioned parent required'),
            prepareVersioned:(ref,item)=>WindowsFirebaseRemote.prepareQueuedRecord(ref,item,school),
            canonicalForAck:(item)=>canonical[item['operationId']],
            sendVersioned:(item)async{
              sample['parentRequests']=(sample['parentRequests'] as int)+1;
              final ack=await WindowsFirebaseRemote.syncManagedRecord(item,school);
              if(ack['record'] is Map)canonical[item['operationId'] as String]=Map<String,dynamic>.from(ack['record']);
              await WindowsSyncDependencies.retain(school,item['collection'] as String,item['documentId'] as String,ack['recordRevision'] as String);
              return ack['recordRevision'] as String;
            });
        }
        await strategy.prepareIdentities(school);
        await push(); sample['firstParentAckMillis']=timer.elapsedMilliseconds;
        Future<void> prepare(Map<String,Set<String>> targets) async {
          final watch=Stopwatch()..start();
          await WindowsDocumentTemplates.publishChangedIdCards(affectedPeople:targets);
          sample['cardPreparationMillis']=watch.elapsedMilliseconds;
        }
        String cardId(String col,String doc,Map<String,dynamic> person)=>WindowsBackendBridge.publishedIdCardOwnerIdForPerson(
          col=='students_directory'?'student':'teacher',doc,person);
        Future<void> send(Set<String> ids)async{
          await WindowsBackendBridge.flushDocumentPending(respectBackoff:true,
            admitRow:(doc,row)=>ids.contains(doc));
        }
        await strategy.publish(school,collection,id,prepare,push,send,cardId);
        sample['personAndCardVerifiedMillis']=timer.elapsedMilliseconds;
        if((await db.collection('_windows_firebase_outbox').get()).docs.isNotEmpty ||
            (await db.collection('_windows_document_outbox').get()).docs.isNotEmpty)throw StateError('Pending work retained; benchmark incomplete.');
        final person=(await db.collection(collection).doc(id).get()).data()!,documentId=cardId(collection,id,person);
        final local=(await db.collection('_local_student_documents').doc(documentId).get()).data();
        final remote=await ManagedSchoolSession.callForSchool(school,'managed/records',{
          'operation':'read','collection':'documents','id':documentId,'syncProtocol':2});
        final doc=(remote['records'] as Map)[documentId] as Map?;
        if(local==null||local['syncState']!='Synced'||doc?['schoolId']!=school||doc?['documentRevision']!=local['documentRevision'])throw StateError('Card metadata verification failed.');
        final bytes=await File((local['optimizedPath']??local['localPath']) as String).readAsBytes();
        final file=await ManagedSchoolSession.callForSchool(school,'managed/file/read',{'fileId':doc!['fileId']});
        final digest=sha256.convert(bytes).toString();
        if(doc['contentHash']!=digest||sha256.convert(base64Decode(file['base64'] as String)).toString()!=digest)throw StateError('Permanent card bytes mismatch.');
        sample['independentProofFinishedMillis']=timer.elapsedMilliseconds;
        sample['sizeBytes']=bytes.length;sample['sha256']=digest;sample['requests']=Map<String,int>.from(client.actions);sample['status']='PASS';
        (report['samples'] as List).add(sample);print(jsonEncode({'sample':sample}));
        await WindowsSyncDependencies.complete(school,await WindowsSyncDependencies.read(school));
      }
      report['status']='PASS';
    },()=>client); }
    catch(error){report['status']='FAIL';report['failedStage']=stage;report['errorType']=error.runtimeType.toString();rethrow;}
    finally {
      WindowsBackendBridge.onLocalDocumentCommitted=null;PrintingPlatform.instance=printing;delegate.close();
      await db.resetVolatileSession();
      final out=File('build/cloud-prerequisites/person-card-$mode.json');await out.parent.create(recursive:true);
      await out.writeAsString(jsonEncode(report));print(jsonEncode(report));
    }
  },timeout:const Timeout(Duration(minutes:30)));
}
