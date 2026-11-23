import 'package:flutter/material.dart';
import 'windows_appearance.dart';
import 'windows_document_templates.dart';
import 'windows_exam_policy.dart';
import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_school_operations.dart';

/// Compact, school-themed Exam Center promotion review.
/// Opening this view / preview never generates a report-card PDF.
class WindowsExamPromotionCenter extends StatefulWidget {
  const WindowsExamPromotionCenter({
    super.key, required this.exam, required this.results,
    required this.onOpenMarks, required this.onRefresh,
  });
  final Map<String, dynamic>? exam;
  final List<Map<String, dynamic>> results;
  final VoidCallback onOpenMarks;
  final Future<void> Function() onRefresh;
  @override
  State<WindowsExamPromotionCenter> createState() => _PromotionPanelState();
}

class _PromotionPanelState extends State<WindowsExamPromotionCenter> {
  final _origin = FirebaseFirestore.instance.activeProfileId;
  final _school = FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
  final _selected = <String>{};
  List<Map<String, dynamic>> _students = [];
  bool _loading = true, _working = false;
  String _filter = '', _error = '';

  bool get _sameSchool => FirebaseFirestore.instance.activeProfileId == _origin &&
      (FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']?.toString() ?? '') == _school;
  String get _examId => widget.exam?['examId']?.toString() ?? '';
  String get _className => widget.exam?['studentClass']?.toString() ?? '';
  bool get _isFinal => widget.exam?['isFinal'] == true;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void didUpdateWidget(covariant WindowsExamPromotionCenter old) {
    super.didUpdateWidget(old);
    if (old.exam?['examId'] != widget.exam?['examId']) {
      _selected.clear();
      _load();
    }
  }
  Future<void> _load() async {
    if (!_sameSchool) return;
    if (mounted) setState(() { _loading = true; _error = ''; });
    try {
      final snapshot = await FirebaseFirestore.instance.collection('students_directory').get();
      if (!mounted || !_sameSchool) return;
      setState(() {
        _students = snapshot.docs.map((doc) => <String, dynamic>{'id':doc.id,...doc.data()})
            .where((row) => WindowsExamPolicy.activeStudent(row) &&
                (row['class'] == _className || _examId.isNotEmpty && row['promotionExamId'] == _examId))
            .toList();
        _students.sort((a,b) => (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
        _selected.removeWhere((id) => !_students.any((s) => s['id'] == id));
        _loading = false;
      });
    } catch (e) {
      if (mounted && _sameSchool) setState(() { _loading = false; _error = '$e'; });
    }
  }
  Map<String,dynamic>? _result(String id) {
    Map<String,dynamic>? found;
    for (final row in widget.results) {
      if (row['examId']?.toString() != _examId || row['studentId']?.toString() != id ||
          row['deleted'] == true || row['_syncDeleted'] == true) continue;
      if (found == null || (row['timestamp'] is num ? row['timestamp'] as num : 0) >
          (found['timestamp'] is num ? found['timestamp'] as num : 0)) found = row;
    }
    return found;
  }
  String _status(Map<String,dynamic> student) {
    if (student['promotionExamId'] == _examId && _examId.isNotEmpty) {
      final movement = student['classMovement'];
      if (movement == 'PROMOTED' || movement == 'FORCE_PROMOTED') return 'Approved locally';
      if (movement == 'RETAINED') {
        // A corrected PASS result requires a new explicit approval.
        if (_result(student['id'].toString())?['result'] == 'PASS')
          return 'Review';
        return 'Retained locally';
      }
      if (movement == 'GRADUATED') return 'Graduated locally';
    }
    return _result(student['id'].toString()) == null ? 'Marks missing' : 'Review';
  }
  String _recommend(Map<String,dynamic> student) {
    final decision = _result(student['id'].toString())?['result'];
    if (decision == 'FAIL') return 'Retain in ' + _className;
    if (decision != 'PASS') return 'Enter marks';
    final n = int.tryParse(_className.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
    if (n == 12) return 'Graduate';
    return n >= 1 && n < 12 ? 'Promote to Class ' + (n+1).toString() : 'Verify class';
  }
  void _notice(String message) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 5)));
  }

  Future<void> _apply(String decision) async {
    if (_working || !_sameSchool || widget.exam == null || !_isFinal) return;
    final chosen = _students.where((student) {
      final id = student['id'].toString();
      return _selected.contains(id) && _status(student) == 'Review' &&
          _result(id)?['result'] == decision;
    }).toList();
    if (chosen.isEmpty) {
      _notice('Select students with saved ' + decision + ' results awaiting approval.');
      return;
    }
    if (!WindowsLocalSecurity.configured) {
      _notice('Configure Administrator Settings Lock to approve promotions.');
      return;
    }
    final adminPassword = TextEditingController();
    try {
    final proceed = await showDialog<bool>(context:context,
      builder:(ctx)=>AlertDialog(
        title: Text(decision == 'FAIL' ? 'Confirm retention' : 'Approve promotion'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Apply to ' + chosen.length.toString() +
            ' students? Permanent IDs, fees, attendance, documents and history remain linked.'),
          const SizedBox(height: 12),
          TextField(controller: adminPassword, obscureText: true,
            decoration: const InputDecoration(labelText: 'Administrator lock password')),
        ]),
        actions:[
          TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
          FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Confirm')),
        ],
      ));
    if (proceed != true || !mounted || !_sameSchool) return;
    if (!WindowsLocalSecurity.verifyPassword(adminPassword.text)) {
      _notice('Invalid Administrator password. Nothing was changed.');
      return;
    }
    setState(() => _working = true);
    var done = 0;
    final failures = <String>[];
    for (final student in chosen) {
      if (!_sameSchool) break;
      try {
        await SchoolPromotionService.apply(
          studentId:student['id'].toString(),student:student,
          exam:widget.exam!,result:decision);
        done++;
      } catch (e) {
        failures.add((student['name']?.toString() ?? 'Student') + ': ' + e.toString());
      }
    }
    if (mounted && _sameSchool) {
      setState(() { _working = false; _selected.clear(); });
      await _load();
      await widget.onRefresh();
      _notice(done.toString() + ' locally recorded; ' + failures.length.toString() +
          ' need review.' + (failures.isEmpty ? ' Cloudflare ACK pending.' : ' ' + failures.first));
    }
    } finally {
      adminPassword.dispose();
    }
  }

  Future<void> _override() async {
    if (_working || !_sameSchool || _selected.length != 1 || !_isFinal || widget.exam == null) return;
    final matches = _students.where((row) => _selected.contains(row['id'])).toList();
    if (matches.isEmpty) return;
    final student = matches.first;
    if (_result(student['id'].toString())?['result'] != 'FAIL' ||
        student['classMovement'] != 'RETAINED' ||
        student['promotionExamId'] != _examId) {
      _notice('Admin override is only for a retained Final Exam FAIL student.');
      return;
    }
    if (!WindowsLocalSecurity.configured) {
      _notice('Configure the local Administrator Settings Lock before overriding a result.');
      return;
    }
    final reason = TextEditingController();
    final password = TextEditingController();
    try {
      final proceed = await showDialog<bool>(context:context,
        builder:(ctx)=>AlertDialog(
          title:const Text('Administrator override'),
          content:Column(mainAxisSize:MainAxisSize.min,children:[
            const Text('Exception requires school policy permission and an audit reason.'),
            TextField(controller:reason,maxLength:500,maxLines:3,
              decoration:const InputDecoration(labelText:'Required reason')),
            TextField(controller:password,obscureText:true,
              decoration:const InputDecoration(labelText:'Administrator lock password')),
          ]),
          actions:[
            TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),
            FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Confirm override')),
          ],
        ));
      if (proceed != true || !mounted || !_sameSchool) return;
      if (reason.text.trim().isEmpty || !WindowsLocalSecurity.verifyPassword(password.text)) {
        _notice('Override blocked: enter an audit reason and valid administrator password.');
        return;
      }
      setState(() => _working = true);
      try {
        await SchoolPromotionService.apply(
          studentId:student['id'].toString(),student:student,
          exam:widget.exam!,result:'FAIL',force:true,reason:reason.text.trim());
        await _load();
        await widget.onRefresh();
        _notice('Override recorded locally; Cloudflare ACK pending.');
      } catch (e) {
        _notice('Override blocked: ' + e.toString());
      } finally {
        if (mounted) setState(() => _working = false);
      }
    } finally { reason.dispose(); password.dispose(); }
  }

  Future<void> _history() async {
    if (!_sameSchool || _examId.isEmpty || _working) return;
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('school_settings')
          .where('examId', isEqualTo: _examId).get();
      if (!mounted || !_sameSchool) return;
      final records = snapshot.docs
          .where((doc) => doc.id.startsWith('promotion_event_') &&
              doc.data()['movement'] is String &&
              doc.data()['studentId'] is String)
          .map((doc) => <String, dynamic>{'id': doc.id, ...doc.data()})
          .toList()
        ..sort((a, b) => (b['at'] as num? ?? 0)
            .compareTo(a['at'] as num? ?? 0));
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Local Promotion Audit History'),
          content: SizedBox(width: 650, height: 430,
            child: records.isEmpty
                ? const Center(child: Text('No promotion approvals recorded for this exam.'))
                : ListView.separated(
                    itemCount: records.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final item = records[i];
                      final ms = (item['at'] as num?)?.toInt() ?? 0;
                      final at = ms > 0
                          ? DateTime.fromMillisecondsSinceEpoch(ms).toLocal().toString()
                          : 'Time unavailable';
                      return ListTile(
                        leading: const Icon(Icons.history_edu_outlined),
                        title: Text((item['movement']?.toString() ?? 'Action') +
                            ' • ' + (item['studentId']?.toString() ?? 'Student')),
                        subtitle: Text(
                          (item['fromClass']?.toString() ?? '—') + ' → ' +
                          (item['toClass']?.toString() ?? '—') +
                          '\n' + at +
                          ' • ' + (item['actor']?.toString() ?? 'School Admin') +
                          ((item['reason']?.toString().trim().isNotEmpty ?? false)
                              ? '\nReason: ' + item['reason'].toString() : ''),
                        ),
                      );
                    }),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        ),
      );
    } catch (error) {
      if (mounted) _notice('Promotion history needs review: ' + error.toString());
    }
  }

  Future<void> _preview() async {
    if (!_sameSchool || _selected.length != 1) {
      _notice('Select one student to preview a report card.'); return;
    }
    final result = _result(_selected.first);
    if (result == null) { _notice('Save marks first.'); return; }
    await WindowsDocumentTemplates.previewReport(context,result);
  }

  Widget _statusChip(String label) {
    final color = {'PASS','Promoted','Graduated'}.contains(label)
        ? const Color(0xFF90DDBE) : {'FAIL','Retained'}.contains(label)
        ? const Color(0xFFFFA7A7) : const Color(0xFFA3DDEC);
    return Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:4),
      decoration:BoxDecoration(
        color:WindowsAppearance.background(color.withOpacity(.12)),
        borderRadius:BorderRadius.circular(12),
        border:Border.all(color:WindowsAppearance.outline(color.withOpacity(.25)))),
      child:Text(label,style:TextStyle(fontSize:10.5,fontWeight:FontWeight.w700,
        color:WindowsAppearance.foreground(color))));
  }
  Widget _step(String label,IconData icon) => Expanded(
    child:Container(
      padding:const EdgeInsets.symmetric(vertical:12,horizontal:4),
      decoration:BoxDecoration(
        color:WindowsAppearance.background(const Color(0xFF28485F)),
        borderRadius:BorderRadius.circular(12),
        border:Border.all(color:WindowsAppearance.outline(Colors.white24))),
      child:Column(children:[
        Icon(icon,size:25,color:WindowsAppearance.foreground(const Color(0xFF90DCE9))),
        const SizedBox(height:6),
        Text(label,textAlign:TextAlign.center,
          style:TextStyle(color:WindowsAppearance.foreground(Colors.white),
            fontSize:11,fontWeight:FontWeight.w700)),
      ])));

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    if (!_sameSchool) return const Center(child:Text('School changed. Reopen Exam Center.'));
    final white = WindowsAppearance.foreground(Colors.white);
    final visible = _students.where((s)=>_filter.trim().isEmpty ||
        (s['name']?.toString() ?? '').toLowerCase().contains(_filter.toLowerCase()) ||
        (s['rollNo']?.toString() ?? '').contains(_filter)).toList();
    return Container(
      padding:const EdgeInsets.all(16),
      decoration:BoxDecoration(
        color:WindowsAppearance.background(const Color(0xFF213B50)),
        borderRadius:BorderRadius.circular(17),
        border:Border.all(color:WindowsAppearance.outline(Colors.white30))),
      child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        Row(children:[
          Icon(Icons.groups_rounded,color:WindowsAppearance.foreground(const Color(0xFF8EDDE7)),size:27),
          const SizedBox(width:9),
          Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Text('Promotion Center',style:TextStyle(color:white,fontSize:19,fontWeight:FontWeight.w800)),
            Text(widget.exam == null ? 'Select a final exam to review student results'
              : (widget.exam!['examName']?.toString() ?? 'Exam') + ' • ' + _className,
              maxLines:1,overflow:TextOverflow.ellipsis,
              style:TextStyle(color:WindowsAppearance.foreground(Colors.white60),fontSize:11)),
          ])),
          IconButton(tooltip:'Refresh student list',onPressed:_working?null:_load,
              icon:const Icon(Icons.refresh_rounded)),
        ]),
        const SizedBox(height:14),
        Row(children:[
          _step('Save Marks',Icons.save_outlined),const SizedBox(width:7),
          _step('Review Result',Icons.fact_check_outlined),const SizedBox(width:7),
          _step('Approve',Icons.verified_user_outlined),const SizedBox(width:7),
          _step('Sync Update',Icons.cloud_done_outlined),
        ]),
        const SizedBox(height:12),
        Container(padding:const EdgeInsets.all(11),
          decoration:BoxDecoration(
            borderRadius:BorderRadius.circular(10),
            color:WindowsAppearance.background(const Color(0xFF34495B)),
            border:Border.all(color:WindowsAppearance.outline(const Color(0xFF9DC8D9)))),
          child:Row(children:[
            Icon(Icons.info_outline,color:WindowsAppearance.foreground(const Color(0xFFABDDE7)),size:18),
            const SizedBox(width:8),
            Expanded(child:Text(
              'Save Marks only saves results. Promotion happens after review and approval.',
              style:TextStyle(color:white,fontWeight:FontWeight.w600,fontSize:11.5))),
          ])),
        const SizedBox(height:10),
        Row(children:[
          Expanded(child:TextField(
            onChanged:(value)=>setState(()=>_filter=value),
            style:TextStyle(color:white,fontSize:12),
            decoration:InputDecoration(isDense:true,hintText:'Search student or roll no.',
              prefixIcon:const Icon(Icons.search_rounded,size:19),
              border:OutlineInputBorder(borderRadius:BorderRadius.circular(10))))),
          const SizedBox(width:8),
          OutlinedButton.icon(onPressed:widget.exam==null?null:widget.onOpenMarks,
              icon:const Icon(Icons.edit_note_rounded,size:18),
              label:const Text('Enter Marks')),
        ]),
        if (_error.isNotEmpty) Padding(
            padding:const EdgeInsets.only(top:6),
            child:Text(_error,style:const TextStyle(color:Colors.orangeAccent))),
        if (widget.exam!=null && !_isFinal)
          const Padding(padding:EdgeInsets.symmetric(vertical:7),
            child:Text('Only Final Exams allow promotion. Other exams support marks and report cards.')),
        const SizedBox(height:8),
        Container(padding:const EdgeInsets.symmetric(horizontal:10,vertical:9),
          decoration:BoxDecoration(color:WindowsAppearance.background(const Color(0xFF1A3247)),
            borderRadius:BorderRadius.circular(8)),
          child:Row(children:[
            SizedBox(width:30,child:Checkbox(
              value:visible.isNotEmpty&&visible.every((s)=>_selected.contains(s['id'])),
              onChanged:_working?null:(v)=>setState((){
                if(v==true) _selected.addAll(visible.map((s)=>s['id'].toString()));
                else _selected.removeAll(visible.map((s)=>s['id'].toString()));
              }))),
            const SizedBox(width:5),
            Expanded(flex:3,child:Text('Student',style:TextStyle(color:white,fontWeight:FontWeight.bold,fontSize:11))),
            Expanded(flex:2,child:Text('Result',style:TextStyle(color:white,fontWeight:FontWeight.bold,fontSize:11))),
            Expanded(flex:4,child:Text('Recommended Action',style:TextStyle(color:white,fontWeight:FontWeight.bold,fontSize:11))),
            Expanded(flex:2,child:Text('Status',style:TextStyle(color:white,fontWeight:FontWeight.bold,fontSize:11))),
          ])),
        Expanded(child:_loading ? const Center(child:CircularProgressIndicator())
          : widget.exam==null ? const Center(child:Text('Create or select an exam from the list.'))
          : visible.isEmpty ? const Center(child:Text('No students found for this class.'))
          : ListView.separated(
            itemCount:visible.length,
            separatorBuilder:(_,__)=>Divider(height:1,color:WindowsAppearance.outline(Colors.white12)),
            itemBuilder:(context,i){
              final student=visible[i],id=student['id'].toString();
              final result=_result(id);
              return InkWell(
                onTap:_working?null:()=>setState((){
                  if(!_selected.add(id))_selected.remove(id);
                }),
                child:Padding(padding:const EdgeInsets.symmetric(vertical:5,horizontal:7),
                  child:Row(children:[
                    SizedBox(width:30,child:Checkbox(value:_selected.contains(id),
                      onChanged:_working?null:(v)=>setState((){
                        if(v==true)_selected.add(id);else _selected.remove(id);
                      }))),
                    const SizedBox(width:5),
                    Expanded(flex:3,child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                      Text(student['name']?.toString() ?? id,maxLines:1,
                        overflow:TextOverflow.ellipsis,style:TextStyle(color:white,
                          fontSize:11.5,fontWeight:FontWeight.w700)),
                      Text('Roll ' + (student['rollNo']?.toString() ?? '—'),
                        style:TextStyle(color:WindowsAppearance.foreground(Colors.white54),fontSize:10)),
                    ])),
                    Expanded(flex:2,child:Align(alignment:Alignment.centerLeft,
                      child:_statusChip(result?['result']?.toString() ?? 'Missing'))),
                    Expanded(flex:4,child:Text(_recommend(student),
                      style:TextStyle(fontSize:11,
                        color:WindowsAppearance.foreground(Colors.white70)))),
                    Expanded(flex:2,child:Align(alignment:Alignment.centerLeft,
                      child:_statusChip(_status(student)))),
                  ])));
            })),
        const SizedBox(height:9),
        if(_working) const LinearProgressIndicator(),
        Wrap(spacing:7,runSpacing:6,children:[
          FilledButton.icon(onPressed:_working?null:()=>_apply('PASS'),
            icon:const Icon(Icons.check_circle_outline,size:17),
            label:const Text('Approve Promotion'),
            style:FilledButton.styleFrom(
              backgroundColor:WindowsAppearance.primary,
              foregroundColor:WindowsAppearance.onPrimary)),
          OutlinedButton.icon(onPressed:_working?null:()=>_apply('FAIL'),
            icon:const Icon(Icons.person_off_outlined,size:17),
            label:const Text('Retain Selected')),
          OutlinedButton.icon(onPressed:_working?null:_preview,
            icon:const Icon(Icons.visibility_outlined,size:17),
            label:const Text('Preview Report Card')),
          OutlinedButton.icon(onPressed:_working?null:_history,
            icon:const Icon(Icons.history_edu_rounded,size:17),
            label:const Text('Promotion History')),
          TextButton.icon(onPressed:_working?null:_override,
            icon:const Icon(Icons.admin_panel_settings_outlined,size:17),
            label:const Text('Admin Override')),
        ]),
        const SizedBox(height:4),
        Text('Student ID unchanged • Check Sync Center for verified Cloudflare status • PDF only on Download',
          style:TextStyle(color:WindowsAppearance.foreground(Colors.white54),fontSize:10)),
      ]));
  }
}
