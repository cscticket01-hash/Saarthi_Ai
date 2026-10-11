import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart';

Future<String> readWindowsImportIdentity() async {
  final db=FirebaseFirestore.instance;
  final profile=db.activeProfileId;
  final saved=await CentralSchoolCloud.saved();
  if(db.activeProfileId!=profile || saved['managed']!=true || db.activeProfileIdentity['schoolSyncId']!=saved['schoolId']) throw StateError('School profile changed. Reopen Student Import.');
  return jsonEncode([profile,saved['schoolId'],saved['uid'],saved['endpoint']]);
}

class WindowsStudentImport extends StatefulWidget {
  const WindowsStudentImport({super.key, this.cloudCall=ManagedSchoolSession.call, this.readIdentity=readWindowsImportIdentity});
  final Future<Map<String,dynamic>> Function(String action, [Map<String,dynamic> body]) cloudCall;
  final Future<String> Function() readIdentity;
  @override
  State<WindowsStudentImport> createState() => _WindowsStudentImportState();
}
class _WindowsStudentImportState extends State<WindowsStudentImport> {
  Map<String,dynamic>? sheet, readback, preview, outcome;
  bool busy=false;
  String? error;
  bool commitAttempted=false;
  bool planExpired=false;
  String? origin;
  bool identityChanged=false;
  Timer? identityTimer;
  @override
  void initState() {
    super.initState();
    ManagedSchoolSession.changed.addListener(invalidateIdentity);
    unawaited(checkIdentity().catchError((Object _) {}));
    identityTimer=Timer.periodic(const Duration(seconds:1), (_) {unawaited(checkIdentity().catchError((Object _) {}));});
  }
  @override
  void dispose() {
    identityTimer?.cancel();
    ManagedSchoolSession.changed.removeListener(invalidateIdentity);
    super.dispose();
  }
  void invalidateIdentity() {
    if(!mounted || identityChanged) return;
    setState(() {identityChanged=true; sheet=null; readback=null; preview=null; outcome=null; error='School identity changed. Reopen Student Import for the current school.';});
  }
  Future<void> checkIdentity() async {
    if(identityChanged) throw StateError('School identity changed. Reopen Student Import.');
    try {
      final identity=await widget.readIdentity();
      if(!mounted || identityChanged) throw StateError('Import page is no longer active.');
      if(origin==null) origin=identity;
      else if(origin!=identity) {invalidateIdentity();throw StateError('School identity changed.');}
    } catch(e) {invalidateIdentity();rethrow;}
  }
  Future<Map<String,dynamic>> guardedCall(String action,[Map<String,dynamic> body=const {}]) async {
    await checkIdentity();
    final value=await widget.cloudCall(action,body);
    await checkIdentity();
    return value;
  }
  Future<void> run(Future<void> Function() operation) async {
    if(identityChanged) return;
    setState(() { busy=true; error=null; });
    try { await checkIdentity(); await operation(); }
    catch(e) { if(mounted && !identityChanged) setState(() => error=e.toString()); }
    finally { if(mounted) setState(() => busy=false); }
  }
  Future<bool> confirm(String title,String message) async => await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
    title:Text(title), content:Text(message), actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),
      FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Confirm'))],
  )) == true;
  Future<void> setup() async {
    if(!await confirm('Create designated Import Sheet?', 'Create only this school’s controlled Import Sheet. Internal storage Sheets are not import sources.')) return;
    await run(() async {
      final value=await guardedCall('managed/student-import/sheet/setup', {'confirmCreate':true});
      if(value['success']!=true || value['headerVersion']!=1 || value['sheetId'] is! String || value['maxRows']!=100) throw StateError('Import Sheet contract could not be verified.');
      if(mounted)setState(() {sheet=value;});
    });
  }
  Future<void> inspect() => run(() async {
    final value=await guardedCall('managed/student-import/sheet/read');
    if(value['success']!=true || value['rows'] is! List || value['fingerprint'] is! String) throw StateError('Import readback could not be verified.');
    if(mounted)setState(() {readback=value;});
  });
  Future<void> plan() async {
    if(commitAttempted && !planExpired) {
      if(!await confirm('Replace an unresolved import preview?', 'The current plan has pending or uncertain results. Retrying its existing plan preserves operation IDs. Create a new preview only after reviewing conflicts and outstanding results.')) return;
    }
    await run(() async {
    final value=await guardedCall('managed/student-import/preview',{'source':'designated-sheet'});
    if(value['success']!=true || value['planId'] is! String) throw StateError('Import preview could not be verified.');
    if(mounted)setState(() {preview=value; outcome=null; commitAttempted=false; planExpired=false;});
    });
  }
  Future<void> commit() async {
    final planned=preview;
    if(planExpired || planned==null || (planned['errors'] is List && (planned['errors'] as List).isNotEmpty)) return;
    if(!await confirm('Commit reviewed student import?', 'The server will recheck the Sheet and record revisions. Conflicts and uncertain acknowledgements remain pending. Existing student edits are not forcibly overwritten.')) return;
    await run(() async {
      commitAttempted=true;
      Map<String,dynamic> value;
      try {
        value=await guardedCall('managed/student-import/commit',{'source':'designated-sheet','planId':planned['planId']});
      } catch(e) {
        if(e is CentralCloudException && e.status==409 && e.message.contains('Import preview changed or expired')) planExpired=true;
        rethrow;
      }
      if(value['success']!=true || value['planId']!=planned['planId']) throw StateError('Import result not verified. The original plan is retained; retry its readback before replacing it.');
      final completed=value['verified']==true && value['remaining']==0 && value['outcomes'] is List &&
          (value['outcomes'] as List).every((row)=>row is Map && row['state']=='verified');
      if(mounted)setState(() {
        outcome=value;
        if(completed) {preview=null; commitAttempted=false;}
      });
    });
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar:AppBar(title:const Text('Designated Student Import Sheet')),
    body:ListView(padding:const EdgeInsets.all(24),children:[
      const Text('School-scoped import, maximum 100 rows per reviewed batch. Use only the designated Sheet. Preview before committing; cloud acknowledgement determines each result.'),
      if(busy)const LinearProgressIndicator(),
      if(error!=null)Text(error!),
      if(planExpired)const Text('The import plan changed or expired. Review pending outcomes, then explicitly create a new preview.'),
      if(commitAttempted && preview!=null && !planExpired)const Text('Original import plan retained. Retry uses the same plan and operation IDs until authoritative verification.'),
      Wrap(spacing:12,children:[
        OutlinedButton(onPressed:busy||identityChanged?null:setup,child:const Text('Create / locate Import Sheet')),
        OutlinedButton(onPressed:busy||identityChanged?null:inspect,child:const Text('Read designated Sheet')),
        OutlinedButton(onPressed:busy||identityChanged?null:plan,child:const Text('Validate and preview')),
        FilledButton(onPressed:busy||identityChanged||preview==null||planExpired?null:commit,child:Text(commitAttempted?'Retry original import plan':'Review and commit')),
      ]),
      if(sheet!=null)SelectableText('Sheet: ${sheet!['sheetUrl'] ?? sheet!['sheetId']}'),
      if(readback!=null)Text('Rows: ${(readback!['rows'] as List).length}\nWarnings: ${readback!['warnings'] ?? []}\nErrors: ${readback!['errors'] ?? []}'),
      if(preview!=null)SelectableText('Server preview (redacted):\n${const JsonEncoder.withIndent('  ').convert(preview)}'),
      if(outcome!=null)SelectableText('Import outcomes — verified / pending / conflict / remaining:\n${const JsonEncoder.withIndent('  ').convert(outcome)}'),
    ]));
}
