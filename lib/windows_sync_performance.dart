import 'package:flutter/material.dart';

/// Bounded, own-profile, observed samples only. Durations overlap and must not
/// be added together; a fast staged acceptance is not a verified Drive ACK.
class WindowsSyncPerformance extends StatelessWidget {
  const WindowsSyncPerformance({super.key, required this.summary});
  final Map<String, dynamic> summary;
  static const stages = {
    'queueWaitMillis': 'Local queue wait',
    'cloudAckMicros': 'Verified record ACK request',
    'scriptRoundTripMillis': 'Google Script round trip',
    'edgeQueueWaitMillis': 'Cloudflare delivery queue wait',
    'edgeDeliveryMillis': 'Cloudflare delivery attempt',
    'recordUploadStageMicros': 'Record upload stage',
    'priorityCardStageMicros': 'Priority ID-card stage',
    'recordRepairStageMicros': 'Record repair stage',
    'recordDownloadStageMicros': 'Record download stage',
    'cardRepairStageMicros': 'ID-card repair stage',
    'syncCycleMicros': 'Completed sync cycle',
    'syncCycleFailureMicros': 'Failed sync cycle',
    'recordUploadStageFailureMicros': 'Failed record upload stage',
    'priorityCardStageFailureMicros': 'Failed priority ID-card stage',
    'recordRepairStageFailureMicros': 'Failed record repair stage',
    'recordDownloadStageFailureMicros': 'Failed record download stage',
    'cardRepairStageFailureMicros': 'Failed ID-card repair stage',
  };
  @override
  Widget build(BuildContext context) {
    final rows = <DataRow>[];
    for (final stage in stages.entries) {
      final sample = summary[stage.key];
      if (sample is! Map || sample['samples'] is! int || sample['samples'] <= 0 ||
          !['p50', 'p95', 'p99'].every((p) => sample[p] is num && sample[p] >= 0)) continue;
      String duration(String p) => '${((sample[p] as num) / (stage.key.endsWith('Micros') ? 1000 : 1)).toStringAsFixed(1)} ms';
      rows.add(DataRow(cells: [DataCell(Text(stage.value)), DataCell(Text('${sample['samples']}')),
        for (final p in ['p50', 'p95', 'p99']) DataCell(Text(duration(p)))]));
    }
    return ExpansionTile(
      title: const Text('Measured sync timings'),
      subtitle: const Text('This session only. Stage timings overlap; small samples are not an SLA.'),
      children: [if (rows.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No measured samples yet.'))
        else SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
          columns: [for (final label in ['Stage', 'Samples', 'p50', 'p95', 'p99']) DataColumn(label: Text(label))], rows: rows))],
    );
  }
}
