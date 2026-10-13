import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'universal_health.dart';
import 'health_diagnostics.dart';
import 'health_knowledge.dart';

/// Equal-weight component availability score. Every registered provider must
/// have a conclusive state; missing, stale, monitoring or paused evidence hides
/// the score. Healthy=100, degraded=50, recovering=25, needsAttention=0.
int? healthScore(UniversalHealth engine) => engine.measuredScore;

String monitoringHeadline(UniversalHealth engine) {
  if (engine.paused) return 'Monitoring Paused';
  if (!engine.monitoringActive) return 'Monitoring inactive · auto-repair off';
  return engine.admissionHistoryVerified && engine.reviewedPlaybookCount > 0
      ? 'Monitoring active · limited safe repairs enabled'
      : 'Monitoring active · auto-repair off';
}

class HealthPoint {
  const HealthPoint(this.at, this.score);
  final DateTime at;
  final int? score;
}

class WindowsHealingMonitor extends StatefulWidget {
  const WindowsHealingMonitor({super.key, this.engine});
  final UniversalHealth? engine;
  @override
  State<WindowsHealingMonitor> createState() => _WindowsHealingMonitorState();
}

class _WindowsHealingMonitorState extends State<WindowsHealingMonitor> {
  late final UniversalHealth engine = widget.engine ?? UniversalHealth.instance;
  StreamSubscription<void>? subscription;
  final List<HealthPoint> points = [];
  Duration window = const Duration(hours: 24);
  bool diagnosing = false;
  Widget knowledgeBrowser() => _KnowledgeBrowser();
  void exportDiagnostics() {
    final report = const JsonEncoder.withIndent('  ').convert({
      'schema': 2,
      'knowledgeVersion': HealthKnowledge.version,
      'actualPatterns': HealthKnowledge.instance.rules.length,
      'state': engine.overall.name,
      'measuredAt': engine.now().toUtc().toIso8601String(),
      'diagnosis': HealthDiagnostics.report(engine),
      'history': engine.history.map((event) => event.toJson()).toList(),
    });
    details('Sanitized diagnostics export', Column(children: [
      SelectableText(report),
      TextButton(onPressed: () async {
        await Clipboard.setData(ClipboardData(text: report));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sanitized diagnostics copied')));
      }, child: const Text('Copy report')),
    ]));
  }
  static const cyan = Color(0xff20dbed);
  static const muted = Color(0xffa4bbcf);
  @override
  void initState() {
    super.initState();
    capture();
    subscription = engine.changes.listen((_) {
      if (mounted) setState(capture);
    });
  }

  void capture() {
    points
      ..clear()
      ..addAll(engine.samples.map((s) => HealthPoint(s.at, s.score)));
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  Widget card(Widget child) => Container(
    padding: const EdgeInsets.all(24),
    decoration: BoxDecoration(
      color: const Color(0xff0b2032),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xff1a4963)),
    ),
    child: child,
  );
  Text label(String value, {double size = 14, Color? color}) => Text(
    value,
    style: TextStyle(fontSize: size, color: color ?? muted),
  );
  Widget diagnosisReport() {
    final report = HealthDiagnostics.report(engine);
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            engine.paused
                ? 'Automatic repair is paused.'
                : engine.admissionHistoryVerified
                ? 'Repair admission history verified; ${engine.reviewedPlaybookCount} reviewed playbooks available. Owner checks, cooldown and circuit limits still apply.'
                : 'Automatic repair is off: durable admission history is unavailable or unverified. History and school data are retained.',
          ),
          const SizedBox(height: 12),
          if (report.isEmpty)
            const Text(
              'No actionable failure category was observed. Unknown components still require owner evidence.',
            ),
          for (final text in report)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(text),
            ),
        ],
      ),
    );
  }

  void details(String title, Widget content) => showDialog<void>(
    context: context,
    builder: (context) => Theme(
      data: ThemeData.dark(),
      child: AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(child: content),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
  Future<void> runDiagnostics() async {
    if (diagnosing) return;
    setState(() => diagnosing = true);
    try {
      final result = await engine.runDiagnostics();
      if (!mounted) return;
      details(
        'Diagnostics results',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.interrupted
                  ? 'Diagnostics stopped: monitoring paused, school changed or no school is bound.'
                  : 'Checked ${result.checked.length} components. Skipped ${result.skipped.length} busy components.',
            ),
            const SizedBox(height: 12),
            if (!result.interrupted)
              for (final id in result.checked)
                Text(
                  '$id: ${engine.observations[id]?.state.name ?? "unknown"} · ${engine.observations[id]?.failure.name ?? "none"}',
                ),
            if (result.skipped.isNotEmpty)
              Text('Not checked: ${result.skipped.join(", ")}'),
            const SizedBox(height: 12),
            if (!result.interrupted) ...[
              const Text('Actionable diagnosis & repair guidance'),
              const SizedBox(height: 8),
              diagnosisReport(),
            ],
            const SizedBox(height: 12),
            const Text(
              'Unknown means no fresh verification is available. Diagnostics do not upload data, clear queues or resolve conflicts.',
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted)
        details(
          'Diagnostics unavailable',
          const Text(
            'The diagnostic check could not finish. Existing school data and queues are retained.',
          ),
        );
    } finally {
      if (mounted) setState(() => diagnosing = false);
    }
  }

  Widget events(Iterable<HealthEvent> items) => Column(
    children: [
      for (final e in items)
        ListTile(
          leading: Icon(
            e.stage == 'verified' ? Icons.check_circle : Icons.monitor_heart,
            color: e.stage == 'verified' ? const Color(0xff25dfab) : cyan,
          ),
          title: Text('${e.component} · ${e.stage}'),
          subtitle: Text('${e.failure.name} · ${e.at.toLocal()}'),
          trailing: Text(switch (e.stage) {
            'verified' || 'quarantineVerified' => 'Successful',
            'started' => 'In Progress',
            'unverified' ||
            'timeout' ||
            'checkFailed' ||
            'persistenceFailed' => 'Failed',
            'blocked' || 'circuitOpen' => 'Repair blocked',
            _ => 'Observed',
          }, style: const TextStyle(fontSize: 12)),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final score = healthScore(engine), state = engine.overall;
    final critical = engine.observations.values.any(
      (e) =>
          e.state == HealthState.needsAttention &&
          {
            HealthFailure.corrupt,
            HealthFailure.storage,
            HealthFailure.identity,
            HealthFailure.authorization,
          }.contains(e.failure),
    );
    final warning = engine.observations.values.any(
      (e) =>
          e.failure != HealthFailure.none ||
          e.state == HealthState.degraded ||
          e.state == HealthState.needsAttention,
    );
    final title = critical
        ? 'Critical'
        : warning
        ? 'Attention Required'
        : state == HealthState.healthy
        ? 'System Healthy'
        : 'Status Unknown';
    final color = critical
        ? Colors.redAccent
        : warning
        ? Colors.amber
        : state == HealthState.healthy
        ? cyan
        : muted;
    final alerts = engine.observations.entries
        .where(
          (e) =>
              e.value.failure != HealthFailure.none ||
              e.value.state == HealthState.needsAttention ||
              e.value.state == HealthState.degraded,
        )
        .toList();
    final history = engine.history.reversed.toList();
    final filtered = points
        .where((p) => engine.now().difference(p.at) <= window)
        .toList();
    final hero = card(
      LayoutBuilder(
        builder: (context, c) => Flex(
          direction: c.maxWidth < 600 ? Axis.vertical : Axis.horizontal,
          children: [
            SizedBox(
              width: c.maxWidth < 600 ? 240 : math.min(340, c.maxWidth * .48),
              height: 300,
              child: CustomPaint(
                painter: _Ring(score, color),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.health_and_safety_outlined,
                      size: 72,
                      color: color,
                    ),
                    const SizedBox(height: 18),
                    label(title, size: 24, color: Colors.white),
                    label(
                      score == null ? '—' : '$score%',
                      size: 36,
                      color: color,
                    ),
                    label(
                      score == null
                          ? 'Insufficient diagnostic evidence'
                          : 'Health Score',
                    ),
                  ],
                ),
              ),
            ),
            ExpandedIf(
              horizontal: c.maxWidth >= 600,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    label(
                      monitoringHeadline(engine),
                      size: 26,
                      color: Colors.white,
                    ),
                    const SizedBox(height: 20),
                    label('Current school · local diagnostics'),
                    const Divider(height: 36),
                    label(
                      '${engine.paused
                          ? 'Paused'
                          : engine.monitoringActive
                          ? 'Monitoring enabled'
                          : 'Monitoring not running'}',
                    ),
                    const SizedBox(height: 14),
                    label('${engine.registeredCount} diagnostic providers'),
                    const SizedBox(height: 14),
                    label('${engine.activeRepairs} authorized repairs running'),
                    const SizedBox(height: 14),
                    label('Business data remains owner-controlled'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    final stats = LayoutBuilder(
      builder: (context, c) => Wrap(
        spacing: 16,
        runSpacing: 16,
        children: [
          stat(
            'Schools',
            engine.context?.school.isNotEmpty == true ? '1' : 'Unknown',
            Icons.domain,
            Colors.blue,
            (c.maxWidth - 16) / 2,
            () => details(
              'School scope',
              label('Only the currently bound school profile is monitored.'),
            ),
          ),
          stat(
            'Devices',
            'Unknown',
            Icons.desktop_windows,
            cyan,
            (c.maxWidth - 16) / 2,
            () => details(
              'Devices',
              label(
                'Registered-device inventory has not been verified for this school. Unknown until authorized registry data is available.',
              ),
            ),
          ),
          stat(
            'Active Repairs',
            '${engine.activeRepairs}',
            Icons.build,
            const Color(0xff25dfab),
            (c.maxWidth - 16) / 2,
            () => details(
              'Authorized recovery',
              label(
                '${engine.activeRepairs} executing · ${engine.unsettledRepairs} quarantined. Only registered reviewed capabilities may run.',
              ),
            ),
          ),
          stat(
            'Component Alerts',
            '${alerts.length}',
            Icons.notifications_active,
            Colors.amber,
            (c.maxWidth - 16) / 2,
            () => details(
              'Unresolved component alerts (each may group multiple queued items)',
              Column(
                children: [
                  for (final e in alerts)
                    ListTile(
                      title: Text(e.key),
                      subtitle: Text(
                        '${e.value.state.name} · ${e.value.failure.name}',
                      ),
                    ),
                  const Divider(),
                  diagnosisReport(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    final trend = card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.show_chart, color: cyan),
              const SizedBox(width: 12),
              Expanded(
                child: label('Health Trend', size: 22, color: Colors.white),
              ),
              DropdownButton<Duration>(
                value: window,
                items: [
                  for (final h in [1, 24, 168])
                    DropdownMenuItem(
                      value: Duration(hours: h),
                      child: Text(
                        h == 168
                            ? 'Last 7 days'
                            : 'Last $h ${h == 1 ? 'hour' : 'hours'}',
                      ),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => window = v);
                },
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 220,
            width: double.infinity,
            child: filtered.where((p) => p.score != null).length < 2
                ? Center(
                    child: label(
                      'Insufficient recorded history\nSamples collect while this monitor is open.',
                    ),
                  )
                : CustomPaint(painter: _Trend(filtered, engine.now(), window)),
          ),
          label(
            'Local observed samples · gaps are not interpolated as healthy',
          ),
        ],
      ),
    );
    final recent = card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history, color: cyan),
              const SizedBox(width: 12),
              Expanded(
                child: label('Recent Actions', size: 22, color: Colors.white),
              ),
              TextButton(
                onPressed: () => details(
                  'Activity history · retained engine events',
                  history.isEmpty
                      ? label('No recorded events')
                      : events(history),
                ),
                child: const Text('View All'),
              ),
            ],
          ),
          if (history.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('No recorded monitoring events'),
            )
          else
            events(history.take(5)),
        ],
      ),
    );
    return Theme(
      data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xff041322),
        colorScheme: ColorScheme.fromSeed(
          seedColor: cyan,
          brightness: Brightness.dark,
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Vidya Saarthi'),
          backgroundColor: const Color(0xff071b2c),
        ),
        body: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= 1100;
            return SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  label('Self-Healing Monitor', size: 30, color: Colors.white),
                  const SizedBox(height: 8),
                  label(
                    'Autonomous protection, recovery and health supervision.',
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    children: [
                      TextButton.icon(
                        onPressed: () => details(
                          'Problem diagnosis & next actions',
                          diagnosisReport(),
                        ),
                        icon: const Icon(Icons.troubleshoot),
                        label: const Text('Problem diagnosis'),
                      ),
                      TextButton.icon(
                        onPressed: () => details('Error knowledge 2.1', knowledgeBrowser()),
                        icon: const Icon(Icons.search),
                        label: const Text('View Error Knowledge'),
                      ),
                      TextButton.icon(
                        onPressed: exportDiagnostics,
                        icon: const Icon(Icons.file_download_outlined),
                        label: const Text('Export Sanitized Diagnostics'),
                      ),
                      TextButton.icon(
                        onPressed: engine.paused ? engine.resume : engine.pause,
                        icon: Icon(
                          engine.paused ? Icons.play_arrow : Icons.pause,
                        ),
                        label: Text(
                          engine.paused
                              ? 'Resume monitoring'
                              : 'Pause monitoring',
                        ),
                      ),
                      TextButton.icon(
                        onPressed: engine.paused || diagnosing
                            ? null
                            : runDiagnostics,
                        icon: diagnosing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.fact_check),
                        label: Text(
                          diagnosing
                              ? 'Running diagnostics…'
                              : 'Run diagnostics',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: hero),
                        const SizedBox(width: 18),
                        Expanded(flex: 2, child: stats),
                      ],
                    )
                  else ...[
                    hero,
                    const SizedBox(height: 18),
                    stats,
                  ],
                  const SizedBox(height: 20),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: trend),
                        const SizedBox(width: 18),
                        Expanded(flex: 2, child: recent),
                      ],
                    )
                  else ...[
                    trend,
                    const SizedBox(height: 18),
                    recent,
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget stat(
    String title,
    String value,
    IconData icon,
    Color color,
    double width,
    VoidCallback action,
  ) => SizedBox(
    width: width,
    child: InkWell(
      onTap: action,
      borderRadius: BorderRadius.circular(16),
      child: card(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 16),
            label(value, size: 28, color: Colors.white),
            label(title),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

class ExpandedIf extends StatelessWidget {
  const ExpandedIf({super.key, required this.horizontal, required this.child});
  final bool horizontal;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      horizontal ? Expanded(child: child) : child;
}

class _Ring extends CustomPainter {
  _Ring(this.score, this.color);
  final int? score;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2),
        r = math.min(size.width, size.height) / 2 - 12;
    for (final d in [0.0, 9.0]) {
      canvas.drawCircle(
        center,
        r + d,
        Paint()
          ..color = color.withValues(alpha: .15)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r - 4),
      -math.pi / 2,
      2 * math.pi * (score == null ? 0.12 : score! / 100),
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_Ring old) => score != old.score || color != old.color;
}

class _Trend extends CustomPainter {
  _Trend(this.points, this.now, this.window);
  final List<HealthPoint> points;
  final DateTime now;
  final Duration window;
  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = const Color(0xff193e54);
    for (var i = 0; i <= 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final paint = Paint()
      ..color = const Color(0xff20dbed)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    Offset? previous;
    DateTime? previousAt;
    for (final p in points) {
      if (p.score == null) {
        previous = null;
        previousAt = null;
        continue;
      }
      final x =
              size.width *
              (1 - now.difference(p.at).inMilliseconds / window.inMilliseconds),
          point = Offset(x, size.height * (1 - p.score! / 100));
      if (previous != null &&
          p.at.difference(previousAt!) <= const Duration(minutes: 2))
        canvas.drawLine(previous, point, paint);
      canvas.drawCircle(point, 2, Paint()..color = paint.color);
      previous = point;
      previousAt = p.at;
    }
  }

  @override
  bool shouldRepaint(_Trend old) => true;
}

class _KnowledgeBrowser extends StatefulWidget {
  @override
  State<_KnowledgeBrowser> createState() => _KnowledgeBrowserState();
}
class _KnowledgeBrowserState extends State<_KnowledgeBrowser> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final knowledge = HealthKnowledge.instance;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${knowledge.rules.length} source-backed diagnostic cases / 1000 target. A: safe infrastructure; B: owner guidance; C: escalation. Catalog entries grant no repair permission.'),
      TextField(maxLength: 120, decoration: const InputDecoration(labelText: 'Search error, component or solution'),
        onChanged: (value) => setState(() => query = value)),
      for (final rule in knowledge.search(query))
        ExpansionTile(title: Text('${rule.id} · Level ${rule.level}'), subtitle: Text(rule.name),
          children: [ListTile(title: Text(rule.solution), subtitle: Text('Verify: ${rule.verification}\nSource: ${(rule.data['source'] as List).join(', ')}\nEvidence: ${rule.data['evidenceType']}'))]),
    ]);
  }
}
