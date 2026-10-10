import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'windows_local_firestore.dart' show FirebaseFirestore, SetOptions;
import 'windows_connect/managed_school_session.dart';
import 'windows_sync_engine.dart';

typedef RecycleCall = Future<Map<String, dynamic>> Function(String school, Map<String, dynamic> body);

/// Administrator-only server inventory; never guesses deletion ACK or restores local snapshots.
class WindowsRecycleBin extends StatefulWidget {
  const WindowsRecycleBin({super.key, this.call});
  final RecycleCall? call;
  @override
  State<WindowsRecycleBin> createState() => _WindowsRecycleBinState();
}

class _WindowsRecycleBinState extends State<WindowsRecycleBin> {
  final db = FirebaseFirestore.instance;
  late final origin = db.activeProfileId;
  late final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
  final clock = Stopwatch();
  Timer? timer;
  String collection = 'students_directory', message = '';
  bool busy = false, verified = false, partial = false;
  int serverNow = 0;
  String? nextAfter;
  List<Map<String, dynamic>> entries = [];
  static const categories = ['students_directory','teachers_directory','documents','fee_payments','fee_ledger','teacher_salary','school_expenses','attendance_records','school_notices','school_calendar','exam_results'];
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(minutes: 1), (_) {if(mounted)setState((){});});
    unawaited(_load());
  }
  @override
  void dispose() {timer?.cancel(); super.dispose();}
  void checkOrigin() {
    if(school.isEmpty || db.activeProfileId != origin) throw StateError('School context changed');
  }
  Future<Map<String,dynamic>> call(Map<String,dynamic> body) async {
    checkOrigin();
    final result = await (widget.call != null ? widget.call!(school,body) : ManagedSchoolSession.callForSchool(school,'managed/recycle',body)).timeout(const Duration(seconds:95));
    checkOrigin();
    if(result['success'] != true || result['schoolId'] != school) throw StateError('Unverified school response');
    return result;
  }
  Future<void> _load({bool more = false}) async {
    if(busy)return;
    setState(() {busy=true; verified=false; message='';});
    try {
      final result = await call({'operation':'list','collection':collection,'after':more ? nextAfter ?? '' : ''});
      if(result['recycleVersion'] != 1 || result['serverNow'] is! int || result['entries'] is! List || result['partial'] is! bool)
        throw StateError('Unsupported recycle inventory');
      final rows = (result['entries'] as List).map((r)=>Map<String,dynamic>.from(r as Map)).toList();
      if(rows.length>25 || rows.any((r)=>r['collection']!=collection || r['id'] is! String || r['fileId'] is! String || r['deletedRevision'] is! String || !{'recoverable','expired','needsReview'}.contains(r['status']) ||
          (r['status']!='needsReview' && (r['recoverUntil'] is! int || r['deletedAt'] is! int)))) throw StateError('Invalid recycle inventory');
      if(result['partial']==true && (result['nextAfter'] is! String || (result['nextAfter'] as String).isEmpty)) throw StateError('Incomplete recycle cursor');
      if(!mounted)return;
      setState(() {
        entries = more ? [...entries,...rows] : rows;
        serverNow=result['serverNow'];clock.reset();clock.start();
        partial=result['partial'];nextAfter=result['nextAfter'] as String?;verified=true;
      });
    } catch (_) {
      if(mounted)setState(() => message='Recycle inventory unavailable or unverified. Existing records are retained. The school must have the verified recycle capability enabled.');
    } finally {if(mounted)setState(()=>busy=false);}
  }
  int remaining(Map<String,dynamic> row) => row['recoverUntil'] is int ? (row['recoverUntil'] as int) - serverNow - clock.elapsedMilliseconds : 0;
  Future<void> restore(Map<String,dynamic> row) async {
    final approved = await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
      title:const Text('Administrator restore approval'),
      content:const Text('Restore this exact verified deletion snapshot? Financial and document records require administrator review. Newer cloud versions and pending local edits must be retained. No permanent purge is performed.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('Approve restore'))]));
    if(approved!=true || !mounted || busy)return;
    setState(() {busy=true; message='';});
    try {
      checkOrigin();
      for(final queue in ['_windows_firebase_outbox','_windows_document_outbox']) {
        final pending = await db.collection(queue).get();
        checkOrigin();
        if(pending.docs.any((d)=>d.data()['documentId']==row['id'] && (queue=='_windows_document_outbox'||d.data()['collection']==row['collection']))) throw StateError('Pending local version requires review');
      }
      final operationId=sha256.convert(utf8.encode('$school/${row['fileId']}/${row['deletedRevision']}/restore')).toString();
      final intent=db.collection('_windows_recycle_requests').doc(operationId);
      final body={'operation':'restore','fileId':row['fileId'],'operationId':operationId,'expectedRecordRevision':row['deletedRevision']};
      await intent.set({'schoolId':school,'collection':row['collection'],'documentId':row['id'],'body':body,'state':'pending'},SetOptions(merge:true));
      final result=await call(body);
      if(result['restored']!=true || result['syncProtocol']!=2 || result['recordRevision'] is! String || (result['recordRevision'] as String).isEmpty || result['recordRevision']==row['deletedRevision']) throw StateError('Durable restore ACK required');
      await intent.set({'state':'verified','recordRevision':result['recordRevision'],'verifiedAt':DateTime.now().millisecondsSinceEpoch},SetOptions(merge:true));
      if(mounted)setState(() {row['status']='restored'; message='Cloud restore verified. Refresh Sync to reconcile the authorized local view; pending local edits remain protected.';});
      unawaited(WindowsSyncEngine.instance.requestSync());
    } catch (_) {
      if(mounted)setState(()=>message='Restore not verified. Snapshot and any pending intent are retained; review conflicts or retry the same item.');
    } finally {if(mounted)setState(()=>busy=false);}
  }
  String stamp(dynamic value)=>value is int ? DateTime.fromMillisecondsSinceEpoch(value).toLocal().toString() : 'Not recorded';
  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('Protected Recycle Bin')),
    body:ListView(padding:const EdgeInsets.all(24),children:[
      const Text('24-hour restore eligibility is enforced by the server. Financial/audit evidence is retained. This page never permanently purges records.'),
      DropdownButton<String>(value:collection,items:[for(final c in categories)DropdownMenuItem(value:c,child:Text(c))],onChanged:busy?null:(value){if(value!=null){setState(() {collection=value;entries=[];});unawaited(_load());}}),
      Wrap(spacing:12,children:[OutlinedButton(onPressed:busy?null:()=>_load(),child:const Text('Refresh verified inventory')),if(partial)OutlinedButton(onPressed:busy?null:()=>_load(more:true),child:const Text('Load more'))]),
      if(busy)const LinearProgressIndicator(),if(message.isNotEmpty)SelectableText(message),
      Text(verified ? 'Cloud deletion inventory verified; ${entries.length} entries loaded${partial ? ' (more available)' : ''}.' : 'Cloud deletion inventory unverified.'),
      if(verified && entries.isEmpty)const Text('No recycle entries in the selected category. This does not verify other categories.'),
      for(final row in entries)Card(child:ListTile(
        title:Text('${row['name'] ?? row['id']} • ${row['collection']}'),
        subtitle:Text('Deleted: ${stamp(row['deletedAt'])}\nDeleted by: ${row['deletedBy'] ?? 'Not recorded'}\nStatus: ${row['status']} • remaining: ${remaining(row)>0 ? '${(remaining(row)/60000).ceil()} minutes' : 'Restore window unavailable/expired'}'),
        trailing:TextButton(onPressed:busy||!verified||row['status']!='recoverable'||remaining(row)<=0 ? null : ()=>restore(row),child:const Text('Restore')))),
    ]));
}
