import 'package:flutter/material.dart';
import 'windows_appearance.dart';
import 'windows_backend_bridge.dart';
import 'windows_exam_history_records.dart';
import 'windows_local_firestore.dart';

/// Read-only history: never replays pending saves or creates cloud operations.
class WindowsExamHistoryScreen extends StatefulWidget {
  const WindowsExamHistoryScreen({super.key});

  @override
  State<WindowsExamHistoryScreen> createState() =>
      _WindowsExamHistoryScreenState();
}

class _WindowsExamHistoryScreenState extends State<WindowsExamHistoryScreen> {
  late final String _profile;
  late final String _school;
  bool _loading = true;
  String? _error;
  String _query = '';
  String _session = '';
  List<Map<String, dynamic>> _exams = [];
  List<Map<String, dynamic>> _results = [];

  bool get _sameSchool =>
      FirebaseFirestore.instance.activeProfileId == _profile &&
      (FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']
                  ?.toString() ??
              '') ==
          _school;

  @override
  void initState() {
    super.initState();
    _profile = FirebaseFirestore.instance.activeProfileId;
    _school =
        FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']
            ?.toString() ??
        '';
    _load();
  }

  Future<void> _load() async {
    if (!_sameSchool) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await WindowsBackendBridge.localExamAction({
        'action': 'list_exam_center',
      });
      if (!mounted) return;
      if (!_sameSchool) {
        setState(() => _loading = false);
        return;
      }
      if (data['success'] != true)
        throw StateError('Unable to load exam history.');
      List<Map<String, dynamic>> rows(dynamic value) => (value as List? ?? [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      setState(() {
        _exams = windowsExamHistoryRecords(
          rows(data['exams']),
          schoolId: _school,
        );
        _results = rows(data['results']);
        if (!_exams.any((row) => row['academicSession'] == _session))
          _session = '';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      if (!_sameSchool) {
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  String _savedAt(Map<String, dynamic> exam) {
    final timestamp = int.tryParse(exam['timestamp']?.toString() ?? '');
    if (timestamp == null || timestamp <= 0 || timestamp > 8640000000000000)
      return 'Saved date unavailable';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return 'Saved ${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    if (!_sameSchool) {
      return Scaffold(
        appBar: AppBar(title: const Text('Exam History')),
        body: const Center(child: Text('School changed. Reopen exam history.')),
      );
    }
    final exams = windowsExamHistoryRecords(
      _exams,
      schoolId: _school,
      query: _query,
      session: _session,
    );
    final sessions =
        _exams
            .map((row) => row['academicSession']?.toString() ?? '')
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
    return Scaffold(
      backgroundColor: WindowsAppearance.resolve(const Color(0xFF0B141A)),
      appBar: AppBar(
        title: const Text('Exam History'),
        actions: [
          IconButton(
            tooltip: 'Refresh saved history',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Saved exams and results • All academic sessions • Read only',
          ),
          const SizedBox(height: 16),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Search exam, class or session',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _session,
            decoration: const InputDecoration(labelText: 'Academic session'),
            items: [
              const DropdownMenuItem(value: '', child: Text('All sessions')),
              for (final session in sessions)
                DropdownMenuItem(value: session, child: Text(session)),
            ],
            onChanged: (value) => setState(() => _session = value ?? ''),
          ),
          const SizedBox(height: 16),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            ListTile(
              title: Text(_error!),
              trailing: TextButton(
                onPressed: _load,
                child: const Text('Retry'),
              ),
            ),
          Text('${exams.length} exam class records'),
          if (!_loading && exams.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('No saved exams match this selection.'),
            ),
          for (final exam in exams) _examCard(exam),
        ],
      ),
    );
  }

  Widget _examCard(Map<String, dynamic> exam) {
    final results = windowsExamHistoryResults(
      _results,
      schoolId: _school,
      examId: exam['examId']?.toString() ?? '',
    );
    final passed = results.where((row) => row['result'] == 'PASS').length;
    final failed = results.where((row) => row['result'] == 'FAIL').length;
    return Card(
      child: ExpansionTile(
        key: ValueKey('${exam['examId']}_${exam['academicSession']}'),
        leading: const Icon(Icons.history_edu_rounded),
        title: Text(
          '${exam['examName'] ?? 'Exam'} • ${exam['studentClass'] ?? 'Class unavailable'}',
        ),
        subtitle: Text(
          '${exam['academicSession'] ?? 'Session not recorded'} • ${_savedAt(exam)}\n'
          '${results.length} results • $passed pass • $failed fail',
        ),
        children: [
          if (results.isEmpty)
            const ListTile(
              title: Text('No saved student results for this exam.'),
            ),
          for (final row in results)
            ListTile(
              title: Text(row['studentName']?.toString() ?? 'Student'),
              subtitle: Text(
                'Roll ${row['rollNo'] ?? '—'} • ${row['result'] ?? 'Result pending'}',
              ),
              trailing: Text(
                '${row['totalMarks'] ?? row['total'] ?? '—'} marks • '
                '${num.tryParse(row['percentage']?.toString() ?? '')?.toStringAsFixed(1) ?? '—'}%',
              ),
            ),
        ],
      ),
    );
  }
}
