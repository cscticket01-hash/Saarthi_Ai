import 'dart:async';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'windows_local_firestore.dart' show FirebaseFirestore;
import 'windows_connect/managed_school_session.dart';
import 'windows_sync_recovery.dart';

/// TEST-only quarantine restore. No active profile switch or queue changes.
class WindowsDisasterRehearsal extends StatefulWidget {
  const WindowsDisasterRehearsal({super.key, this.loadJobs});
  final Future<Map<String,dynamic>> Function()? loadJobs;
  @override
  State<WindowsDisasterRehearsal> createState() => _WindowsDisasterRehearsalState();
}

class _WindowsDisasterRehearsalState extends State<WindowsDisasterRehearsal> {
  static const testSchool = 'vs-db8afb01a3be46a983c8284714d06e5d';
  final db = FirebaseFirestore.instance;
  late final origin = db.activeProfileId;
  Map<String, dynamic>? backup, rehearsal;
  bool busy = false, preparing = false, loaded = false;
  String message = '';
  String get school => db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
  void guard() {
    if (school != testSchool || db.activeProfileId != origin) {
      throw StateError('Reopen the isolated TEST school.');
    }
  }

  @override
  void initState() {super.initState();_load();}
  Future<void> _load() async {
    try {
      guard();
      final jobs = await (widget.loadJobs?.call() ?? _savedJobs()).timeout(const Duration(seconds:30));
      guard();
      if (mounted) setState(() {backup = jobs['backup'] as Map<String,dynamic>?;rehearsal = jobs['rehearse'] as Map<String,dynamic>?;loaded = true;});
    } catch (_) {if (mounted) setState(() => message = 'TEST recovery state is unavailable. Pending data is retained.');}
  }
  Future<Map<String,dynamic>> _savedJobs() async {
    final a = await db.collection('_windows_disaster_jobs').doc('backup').get();
    final b = await db.collection('_windows_disaster_jobs').doc('rehearse').get();
    return {'backup':a.data(),'rehearse':b.data()};
  }

  Future<void> _start(String operation) async {
    guard();
    if (operation == 'rehearse' && backup?['complete'] != true) return;
    final approved = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(operation == 'backup' ? 'Capture TEST disaster backup?' : 'Restore into a separate TEST rehearsal?'),
      content: const Text('Copy managed cloud records, tombstones and uploaded file bytes into private recovery storage. Verification reads every copied file and the rehearsal spreadsheet. Active school storage and pending operations remain unchanged. Unfinished recovery copies and operation intents are retained when a new generation starts. Firebase credentials, Windows queues and active disaster cutover are outside this rehearsal.'),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Authorize TEST copy'))],
    ));
    if (approved != true || !mounted) return;
    guard();
    final random = Random.secure();
    final job = <String, dynamic>{'operation': operation, 'operationId': sha256.convert(List<int>.generate(32, (_) => random.nextInt(256))).toString(),
      if (operation == 'rehearse') 'sourceFileId': backup!['fileId'], 'complete': false, 'phase': 'not_started', 'schoolId': school};
    // Retain the prior operation before approving a new capture generation.
    final prior=operation=='backup'?backup:rehearsal;
    if(prior!=null){
      final id=prior['operationId'];if(id is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(id))throw StateError('Recovery intent needs review.');
      await db.collection('_windows_disaster_job_history').doc(id).set(prior);
      guard();
    }
    // Persist the original identity before contacting the cloud.
    await db.collection('_windows_disaster_jobs').doc(operation).set(job);
    guard();
    if (mounted) setState(() {if (operation == 'backup') {backup = job;} else {rehearsal = job;}});
    await _resume(operation);
  }
  Future<void> _begin(String operation) async {
    if (busy || preparing || !loaded) return;
    setState(() => preparing = true);
    try {await _start(operation);}
    catch (error) {if (mounted) setState(() => message = windowsSyncRecovery(error).message);}
    finally {if (mounted) setState(() => preparing = false);}
  }

  Future<void> _resume(String operation) async {
    if (busy) return;
    setState(() {busy = true;message = '';});
    try {
      guard();
      var job = Map<String, dynamic>.from((operation == 'backup' ? backup : rehearsal)!);
      // Three bounded steps per explicit resume, never an aggressive retry loop.
      for (var n = 0; n < 3 && job['complete'] != true; n++) {
        guard();
        final result = await ManagedSchoolSession.callForSchool(school, 'managed/disaster', {
          'operation': operation, 'operationId': job['operationId'],
          if (operation == 'rehearse') 'fileId': job['sourceFileId'],
        }).timeout(const Duration(seconds: 40));
        guard();
        if (result['success'] != true || result['schoolId'] != school || result['disasterVersion'] != 5 ||
            result['operationId'] != job['operationId'] || result['operation'] != operation || result['activeStorageChanged'] != false ||
            result['fileId'] is! String || result['phase'] is! String || result['complete'] is! bool ||
            result['complete'] == true && (result['verified'] != true || result['verifiedAt'] is! num || (result['verifiedAt'] as num) <= 0)) {
          throw StateError('Disaster acknowledgement is unverified.');
        }
        job = {...job, ...result};
        await db.collection('_windows_disaster_jobs').doc(operation).set(job);
        guard();
        if (mounted) setState(() {if (operation == 'backup') {backup = job;} else {rehearsal = job;}});
        if (n < 2 && job['complete'] != true) await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (mounted) setState(() => message = job['complete'] == true
        ? 'Verified TEST ${operation == 'backup' ? 'backup' : 'Sheets/Drive rehearsal'}. Active disaster cutover remains unverified.'
        : 'Checkpoint saved. Continue when ready; the original operation ID is retained.');
    } catch (error) {
      if (mounted) setState(() => message = error is TimeoutException
        ? 'Request timed out. Cloud completion is unverified. Resume uses the same operation ID.'
        : 'Recovery copy remains unverified. Stored copies and the original operation ID are retained. Resume the same operation, or authorize a new generation if the source changed.');
    } finally {if (mounted) setState(() => busy = false);}
  }

  Widget _job(String title, String operation, Map<String, dynamic>? job) => Card(child: Padding(
    padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.titleLarge),
      Text(job == null ? 'Not started' : 'Phase: ${job['phase']} · Files copied: ${job['copied'] ?? 0}/${job['binaryCount'] ?? '?'}'),
      Text(job?['complete'] == true ? 'Verified at ${DateTime.fromMillisecondsSinceEpoch((job!['verifiedAt'] as num).toInt()).toLocal()}' : 'Completion unverified'),
      if (job != null && job['complete'] != true) OutlinedButton(onPressed: busy ? null : () => _resume(operation), child: const Text('Continue same operation')),
      FilledButton(onPressed: !loaded || busy || preparing || operation == 'rehearse' && backup?['complete'] != true
        ? null : () => _begin(operation), child: Text(operation == 'backup' ? 'New TEST backup generation' : 'Authorize separate TEST restore')),
    ])));

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('TEST Disaster Recovery Rehearsal')),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      const Text('Private recovery copies only. Original school storage, financial records and pending queues are preserved.'),
      _job('Managed records and uploaded bytes', 'backup', backup), _job('Separate spreadsheet and file restore', 'rehearse', rehearsal),
      if (busy) const LinearProgressIndicator(), if (message.isNotEmpty) Text(message),
    ]));
}
