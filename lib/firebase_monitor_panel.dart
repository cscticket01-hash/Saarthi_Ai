import 'dart:async';

import 'package:flutter/material.dart';

import 'platform/managed_developer_service.dart';
import 'platform/firebase_metric_samples.dart';

class FirebaseMonitorPanel extends StatefulWidget {
  const FirebaseMonitorPanel({super.key});
  @override
  State<FirebaseMonitorPanel> createState() => _FirebaseMonitorPanelState();
}

class _FirebaseMonitorPanelState extends State<FirebaseMonitorPanel> {
  Timer? timer;
  bool busy = false;
  Map<String, dynamic>? data;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 60), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final d = await ManagedDeveloperService.call('monitor', {});
      if (mounted)
        setState(() {
          data = d;
          error = null;
        });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  String format(dynamic sample, {bool bits = false, String key = ''}) {
    if (sample is! Map) return missingMetricStatus(key);
    final value = sample['value'];
    if (value is! num || !value.toDouble().isFinite)
      return 'Invalid metric sample';
    double n = value.toDouble();
    if (bits) {
      if (n >= 1e9) return '${(n / 1e9).toStringAsFixed(2)} Gbps';
      if (n >= 1e6) return '${(n / 1e6).toStringAsFixed(2)} Mbps';
      return '${(n / 1000).toStringAsFixed(2)} Kbps';
    }
    if (sample['unit'] == 'By') {
      for (final e in [(1073741824, 'GB'), (1048576, 'MB'), (1024, 'KB')]) {
        if (n >= e.$1) return '${(n / e.$1).toStringAsFixed(2)} ${e.$2}';
      }
    }
    return '${n.toStringAsFixed(2)} ${sample['unit'] == '1' ? 'ops/s' : sample['unit'] ?? ''}';
  }

  String missingMetricStatus(String key) {
    final metrics = data?['metrics'];
    return firebaseMetricMissingStatus(
      metrics is Map ? metrics : null,
      key,
      loading: busy,
      apiError: error != null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final metrics = data?['metrics'];
    final cards = metrics is Map ? firebaseMetricCards(metrics) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Central Firebase • Developer Only',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              onPressed: busy ? null : load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const Text(
          'Refresh every 60 seconds. Google metrics have sampling/reporting delay. No speed or usage estimates. Missing samples are not zero usage.',
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        if (metrics is Map && metrics['available'] != true)
          Text('${metrics['reason'] ?? 'Monitoring unavailable'}'),
        const SizedBox(height: 20),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final e in [
              ('Firestore Storage', 'storageBytes', false),
              ('Outbound Traffic', 'outboundBitsPerSecond', true),
              ('Inbound Traffic', 'inboundBitsPerSecond', true),
              ('Reads / Second', 'readsPerSecond', false),
              ('Writes / Second', 'writesPerSecond', false),
              ('Firestore Request Latency', 'latency', false),
            ])
              SizedBox(
                width: 260,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.$1),
                        const SizedBox(height: 12),
                        Text(
                          format(
                            cards is Map ? cards[e.$2] : null,
                            bits: e.$3,
                            key: e.$2,
                          ),
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (cards is Map &&
                            cards[e.$2] is Map &&
                            cards[e.$2]['sampledAt'] is num)
                          Text(
                            'Sample: ${DateTime.fromMillisecondsSinceEpoch((cards[e.$2]['sampledAt'] as num).toInt()).toLocal()}',
                            style: const TextStyle(fontSize: 10),
                          ),
                        if (e.$2.endsWith('PerSecond') && !e.$3)
                          const Text('operations / second'),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 20),
        const Text('Quota / Limits', style: TextStyle(fontSize: 20)),
        if (metrics is Map && metrics['quotas'] is Map) ...[
          if (metrics['quotas']['available'] != true)
            Text(
              '${metrics['quotas']['reason'] ?? 'Quota read access unavailable'}',
            )
          else
            for (final q in (metrics['quotas']['metrics'] as List? ?? []))
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${q['displayName'] ?? q['metric']}'),
                      for (final limit
                          in (q['consumerQuotaLimits'] as List? ?? []))
                        Text(
                          '${limit['unit']}: ${(limit['quotaBuckets'] as List? ?? []).map((b) => b['effectiveLimit']).join(', ')}',
                        ),
                    ],
                  ),
                ),
              ),
        ] else
          const Text('Waiting for verified quota data.'),
        const SizedBox(height: 12),
        const Text(
          'School photos, documents and backups use each school’s Drive. School Drive usage is shown in Schools. Traffic rate is measured throughput, not connection capacity.',
        ),
      ],
    );
  }
}
