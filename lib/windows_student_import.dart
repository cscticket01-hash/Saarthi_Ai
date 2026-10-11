import 'dart:convert';
import 'package:flutter/material.dart';
import 'windows_connect/managed_school_session.dart';

class WindowsStudentImport extends StatefulWidget {
  const WindowsStudentImport({super.key});
  @override
  State<WindowsStudentImport> createState() => _WindowsStudentImportState();
}
class _WindowsStudentImportState extends State<WindowsStudentImport> {
  Map<String,dynamic>? sheet, readback, preview, outcome;
  bool busy=false;
  String? error;
  Future<void> run(Future<void> Function() operation) async {
    setState(() { busy=true; error=null; });
    try { await operation(); }
    catch(e) { if(mounted) setState(() => error=e.toString()); }
    finally { if(mounted) setState(() => busy=false); }
  }
  Future<bool> confirm(String title,String message) async => await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
    title:Text(title), content:Text(message), actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),
      FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Confirm'))],
  )) == true;
  Future<void> setup() async {
    if(!await confirm('Create designated Import Sheet?', 'Create only this school’s controlled Import Sheet. Internal storage Sheets are not import sources.')) return;
    await run(() async {
      final value=await ManagedSchoolSession.call('managed/student-import/sheet/setup', {'confirmCreate':true});
      if(value['success']!=true || value['headerVersion']!=1 || value['sheetId'] is! String || value['maxRows']!=100) throw StateError('Import Sheet contract could not be verified.');
      if(mounted)setState(() {sheet=value; preview=null; outcome=null;});
    });
  }
  Future<void> inspect() => run(() async {
    final value=await ManagedSchoolSession.call('managed/student-import/sheet/read');
    if(value['success']!=true || value['rows'] is! List || value['fingerprint'] is! String) throw StateError('Import readback could not be verified.');
    if(mounted)setState(() {readback=value; preview=null; outcome=null;});
  });
  Future<void> plan() => run(() async {
    final value=await ManagedSchoolSession.call('managed/student-import/preview',{'source':'designated-sheet'});
    if(value['success']!=true || value['planId'] is! String) throw StateError('Import preview could not be verified.');
    if(mounted)setState(() {preview=value; outcome=null;});
  });
  Future<void> commit() async {
    final planned=preview;
    if(planned==null || (planned['errors'] is List && (planned['errors'] as List).isNotEmpty)) return;
    if(!await confirm('Commit reviewed student import?', 'The server will recheck the Sheet and record revisions. Conflicts and uncertain acknowledgements remain pending. Existing student edits are not forcibly overwritten.')) return;
    await run(() async {
      final value=await ManagedSchoolSession.call('managed/student-import/commit',{'source':'designated-sheet','planId':planned['planId']});
      if(value['success']!=true)throw StateError('Import result not verified. Preview again before retry.');
      if(mounted)setState(() {outcome=value; preview=null;});
    });
  }
  @override
  Widget build(BuildContext context) => Scaffold(appBar:AppBar(title:const Text('Designated Student Import Sheet')),
    body:ListView(padding:const EdgeInsets.all(24),children:[
      const Text('School-scoped import, maximum 100 rows per reviewed batch. Use only the designated Sheet. Preview before committing; cloud acknowledgement determines each result.'),
      if(busy)const LinearProgressIndicator(),
      if(error!=null)Text(error!),
      Wrap(spacing:12,children:[
        OutlinedButton(onPressed:busy?null:setup,child:const Text('Create / locate Import Sheet')),
        OutlinedButton(onPressed:busy?null:inspect,child:const Text('Read designated Sheet')),
        OutlinedButton(onPressed:busy?null:plan,child:const Text('Validate and preview')),
        FilledButton(onPressed:busy||preview==null?null:commit,child:const Text('Review and commit')),
      ]),
      if(sheet!=null)SelectableText('Sheet: ${sheet!['sheetUrl'] ?? sheet!['sheetId']}'),
      if(readback!=null)Text('Rows: ${(readback!['rows'] as List).length}\nWarnings: ${readback!['warnings'] ?? []}\nErrors: ${readback!['errors'] ?? []}'),
      if(preview!=null)SelectableText('Server preview (redacted):\n${const JsonEncoder.withIndent('  ').convert(preview)}'),
      if(outcome!=null)SelectableText('Import outcomes — verified / pending / conflict / remaining:\n${const JsonEncoder.withIndent('  ').convert(outcome)}'),
    ]));
}
