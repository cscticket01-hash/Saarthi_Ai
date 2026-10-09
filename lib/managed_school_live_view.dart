import 'dart:async';
import 'package:flutter/material.dart';

/// A read-only view of the existing school's acknowledged cloud records.
/// Polls revision metadata only while visible; unchanged groups remain cached.
class ManagedSchoolLiveView extends StatefulWidget {
  const ManagedSchoolLiveView({super.key, required this.schoolId,
    required this.schoolName, required this.load});
  final String schoolId, schoolName;
  final Future<Map<String, dynamic>> Function(Map<String, String>) load;
  @override
  State<ManagedSchoolLiveView> createState() => _ManagedSchoolLiveViewState();
}
class _ManagedSchoolLiveViewState extends State<ManagedSchoolLiveView>
    with WidgetsBindingObserver {
  static const labels = <String, String>{'exams':'Examinations',
    'examResults':'Exam Results', 'fee_settings':'Fee Structure',
    'fee_ledger':'Fees', 'fee_payments':'Payments', 'school_notices':'Notices',
    'school_config':'School Profile', 'school_settings':'School Settings'};
  final _revisions = <String, String>{};
  final _groups = <String, Map<String, dynamic>>{};
  Timer? _timer;
  bool _busy = false, _follow = false;
  String _selected = 'exams';
  String? _error;
  DateTime? _verifiedAt;
  bool get _visible => WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  void initState() {
    super.initState(); WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds:15), (_) {
      if (_visible) _refresh();
    });
  }
  @override
  void dispose() {
    _timer?.cancel(); WidgetsBinding.instance.removeObserver(this);super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_busy) _follow = true; else _refresh();
    }
  }
  Future<void> _refresh() async {
    if (!mounted || _busy) return;
    setState(() => _busy = true);
    try {
      final response = await widget.load(Map<String, String>.from(_revisions));
      if (!mounted) return;
      if (response['schoolId'] != widget.schoolId) throw StateError('School response mismatch');
      final groups = Map<String, dynamic>.from(response['groups'] as Map);
      final revisions = Map<String, String>.from(response['revisions'] as Map);
      final parsed = <String, Map<String, dynamic>>{};
      for (final entry in groups.entries) {
        if (!labels.containsKey(entry.key)) throw StateError('Unknown school group');
        final group = Map<String, dynamic>.from(entry.value as Map);
        final rows = (group['rows'] as List).whereType<Map>().toList();
        if (rows.length != (group['rows'] as List).length ||
            rows.any((row) => row['schoolId'] != widget.schoolId) ||
            group['count'] is! int || (group['count'] as int) < rows.length) {
          throw StateError('School record mismatch');
        }
        parsed[entry.key] = group;
      }
      if (revisions.keys.any((key) => !labels.containsKey(key))) throw StateError('Unknown checkpoint');
      setState(() {
        _groups.addAll(parsed); _revisions.addAll(revisions);
        _verifiedAt = DateTime.now(); _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Cloud verification failed. Retained records may be stale.');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_follow && _visible) { _follow = false; unawaited(_refresh()); }
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    final group = _groups[_selected];
    final rows = (group?['rows'] as List? ?? []).whereType<Map>();
    return AlertDialog(title:Text('${widget.schoolName} — Cloud Records'),
      content:SizedBox(width:760,height:460,child:Column(children:[
        DropdownButton<String>(value:_selected,isExpanded:true,
          items:labels.entries.map((entry) => DropdownMenuItem(
            value:entry.key,child:Text(entry.value))).toList(),
          onChanged:(value) { if(value != null) setState(() => _selected=value); }),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (_verifiedAt != null) Text('Last verified: ${_verifiedAt!.toLocal()}'),
        if (group != null) Text('Showing ${rows.length} of ${group['count']} records'),
        Expanded(child:ListView(children:[for(final row in rows)
          ListTile(title:Text('${row['examName'] ?? row['title'] ?? row['name'] ?? row['studentName'] ?? row['className'] ?? row['id']}'),
            subtitle:Text(row.entries.where((entry) =>
              !entry.key.startsWith('_sync') && entry.key != 'schoolId').map((entry) =>
                '${entry.key}: ${entry.value}').join(' • '))),
          if(group != null && rows.isEmpty) const Text('No acknowledged records.'),
        ])),
      ])),actions:[TextButton(onPressed:_busy?null:_refresh,child:const Text('Refresh')),
        TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Close'))]);
  }
}
