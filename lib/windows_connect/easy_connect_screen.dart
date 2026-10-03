import '../windows_admin_setup.dart';
import '../windows_local_firestore.dart';
import 'package:flutter/material.dart';
import '../windows_connection_center.dart';
import '../windows_firebase_sync.dart';
import '../windows_sync_engine.dart';
import 'google_authorization.dart';
import 'central_school_cloud.dart';

class EasySchoolConnectScreen extends StatefulWidget {
  const EasySchoolConnectScreen({super.key, this.googleDrive = false});
  final bool googleDrive;
  @override
  State<EasySchoolConnectScreen> createState() => _EasySchoolConnectScreenState();
}
class _EasySchoolConnectScreenState extends State<EasySchoolConnectScreen> {
  final _name = TextEditingController();
  final _auth = GoogleAuthorization();
  CentralSchoolCloud? _cloud;
  bool _migrate = false;
  bool _busy = false, _done = false, _google = false, _firebase = false, _drive = false;
  String _message = '', _email = '';
  @override
  void initState() {super.initState();_name.text=WindowsAdminSetup.schoolName;}
  @override
  void dispose() { _cloud?.close(); _auth.close(); _name.dispose(); super.dispose(); }
  Future<void> _start() async {
    if (_busy) return;
    setState(() { _busy=true; _done=false; _google=false; _firebase=false; _drive=false; });
    try {
      final previous = await CentralSchoolCloud.saved();
      final existing = await WindowsFirebaseRemote.status();
      final initialProfile=(await FirebaseFirestore.instance.collection('school_config').doc('school_profile_cache').get()).data() ?? <String,dynamic>{};
      if (previous.isEmpty && existing.configSaved && !_migrate) throw StateError('An existing school connection is retained. To copy its verified records safely, select the migration option. Source data is never deleted.');
      Map<String,dynamic>? migration;
      if (previous.isEmpty && existing.authenticated && _migrate) {
        final sourceToken = await WindowsFirebaseRemote.freshIdToken();
        final records = <Map<String,dynamic>>[];
        for (final collection in ['students_directory','teachers_directory','school_config','school_settings',
          'school_notices','school_calendar','attendance_records','exam_results','teacher_salary',
          'fee_settings','fee_ledger','fee_payments']) {
          final rows = await WindowsFirebaseRemote.readCollection(projectId:existing.projectId,idToken:sourceToken,collection:collection);
          if (FirebaseFirestore.instance.activeProfileIdentity['firebaseProjectId'] == existing.projectId) {
            final local = await FirebaseFirestore.instance.collection(collection).get();
            for (final doc in local.docs) { rows[doc.id] = doc.data(); }
          }
          for (final entry in rows.entries) {
            records.add({'collection':collection,'id':entry.key,'data':entry.value});
          }
        }
        migration={'projectId':existing.projectId,'token':sourceToken,'records':records};
      } else if (previous.isEmpty && existing.configSaved) throw StateError('Verify the existing school administrator connection before migration.');
      final name = _name.text.trim().isEmpty ? previous['schoolName']?.toString() ?? '' : _name.text.trim();
      if (name.length < 2) throw StateError('Enter your school name.');
      setState(() => _message='Sign in to your school Google account and allow Drive access');
      final account = await _auth.authorize(script:false,schoolCloud:true);
      if (!mounted) return;
      if (migration != null && existing.email.toLowerCase() != account.email.toLowerCase()) throw StateError('Use the original verified school Google account for migration.');
      setState(() { _google=true; _email=account.email; _message='Preparing your school’s isolated cloud data and Google Drive folder'; });
      final cloud = CentralSchoolCloud(); _cloud=cloud;
      final connection=await cloud.connect(account,name,migration:migration);
      if (previous.isEmpty && !existing.configSaved) {
        final profile=<String,dynamic>{'schoolName':name,
          'principalName':initialProfile['principalName']?.toString() ?? WindowsAdminSetup.principalName};
        for(final prefix in ['logo','seal','principalSignature']) {
          final source=initialProfile['${prefix}Url']?.toString() ?? '';
          if (source.startsWith('data:image/')) {
            final mime=source.substring(5,source.indexOf(';'));
            final file=await cloud.upload('$prefix.png',mime,source);
            profile['${prefix}Url']=file['fileUrl'];profile['${prefix}FileId']=file['fileId'];
          }
        }
        await cloud.api({'action':'profile/initialize','schoolId':connection['schoolId'],'profile':profile},
          token:await CentralSchoolCloud.firebaseToken());
      }
      await WindowsSyncEngine.instance.activateCurrentConnections(allowPairing:false);
      await WindowsConnectionCenter.reload();
      if (mounted) setState(() { _firebase=true; _drive=true; _done=true; _message='Connected. Your school data is isolated and files use your school’s Google Drive.'; });
    } catch(e) {
      if (mounted) setState(() => _message=e.toString().replaceFirst('Bad state: ',''));
    } finally { if (mounted) setState(() => _busy=false); }
  }
  Widget _status(String label,bool verified,{bool ready=false}) => ListTile(
    dense:true,contentPadding:EdgeInsets.zero,
    leading:Icon(verified ? Icons.check_circle:Icons.radio_button_unchecked,color:verified ? Colors.greenAccent:Colors.white54),
    title:Text('$label: ${verified ? (ready ? 'Ready':'Connected'):'Not verified'}'));
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar:AppBar(title:const Text('Connect School Cloud')),
    body:Center(child:ConstrainedBox(constraints:const BoxConstraints(maxWidth:640),
      child:ListView(padding:const EdgeInsets.all(24),shrinkWrap:true,children:[
        Icon(_done ? Icons.verified_user:Icons.cloud_outlined,size:52,color:Colors.tealAccent),
        const SizedBox(height:18),
        const Text('Your school. Your Google account.',style:TextStyle(fontSize:23,fontWeight:FontWeight.bold)),
        const SizedBox(height:10),
        const Text('Sign in with Google and allow access. Your school data stays separate, and school files use your own Google Drive. No Firebase Console, project creation, API keys or scripts are needed from the school.'),
        if (!GoogleAuthorization.configured) Card(child:Padding(padding:const EdgeInsets.all(16),child:Text(GoogleAuthorization.configurationIssue))),
        if (!CentralSchoolCloud.configured) const Card(child:Padding(padding:EdgeInsets.all(16),child:Text('Developer setup is pending for the central school cloud service in this preview. Existing connections and data are retained.'))),
        TextField(controller:_name,enabled:!_busy,decoration:const InputDecoration(labelText:'School name')),
        CheckboxListTile(contentPadding:EdgeInsets.zero,value:_migrate,
          onChanged:_busy ? null:(v)=>setState(()=>_migrate=v ?? false),
          title:const Text('Copy records from an existing verified school connection'),
          subtitle:const Text('Only for migration. Existing source data, files and credentials are retained; existing destination records are never overwritten.')),
        if (_email.isNotEmpty) Text('School account: $_email'),
        _status('Google account',_google), _status('Firebase',_firebase), _status('Firestore',_firebase,ready:true),
        _status('Google Drive',_drive), _status('School storage',_drive,ready:true),
        if (_busy) const LinearProgressIndicator(),
        if (_message.isNotEmpty) Padding(padding:const EdgeInsets.symmetric(vertical:14),child:Text(_message)),
        if (!_done) FilledButton.icon(key:const ValueKey('school-google-sign-in'),
          onPressed:_busy || !GoogleAuthorization.configured || !CentralSchoolCloud.configured ? null:_start,
          icon:const Icon(Icons.login),label:const Text('Sign in with Google / Reconnect')),
        if (_busy) TextButton(onPressed:(){_auth.cancel();_cloud?.close();},child:const Text('Cancel')),
        if (_done) OutlinedButton.icon(onPressed:_busy ? null:() async {
          setState(()=>_busy=true);
          final cloud=CentralSchoolCloud();
          try {await cloud.backup();if(mounted)setState(()=>_message='School data backup saved to your Google Drive.');}
          catch(e){if(mounted)setState(()=>_message=e.toString().replaceFirst('Bad state: ',''));}
          finally{cloud.close();if(mounted)setState(()=>_busy=false);}
        },icon:const Icon(Icons.backup),label:const Text('Back up school data to Google Drive')),
        if (_done) FilledButton(onPressed:()=>Navigator.of(context).pop(true),child:const Text('Done')),
      ]))),
  );
}
