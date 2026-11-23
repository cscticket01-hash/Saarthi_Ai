import 'package:flutter/material.dart' hide Text;
import 'windows_ui_localization.dart';

/// One measured local volume and only evidence-backed active transfer links.
class WindowsSyncFlow extends StatelessWidget {
  const WindowsSyncFlow({
    super.key,
    required this.phase,
    required this.label,
    required this.local,
    required this.cloud,
    required this.drive,
    required this.pending,
    this.serverAck = 'Waiting for verified ACK',
    this.pendingText,
    this.uploadProgress,
    this.lastMicros,
    this.active = const {},
  });

  final String phase, label, local, cloud, drive, serverAck;
  final int pending;
  final String? pendingText;
  final ({int offset, int total})? uploadProgress;
  final int? lastMicros;
  final Set<String> active;

  @override
  Widget build(BuildContext context) {
    final bytes = uploadProgress;
    final fraction = bytes == null ? null : bytes.offset / bytes.total;
    final percent = bytes == null ? null : bytes.offset * 100 ~/ bytes.total;
    final theme = Theme.of(context);
    // Drive is a server-owned background lane. Once this device is Idle, a
    // late Google receipt (or even a lingering drive activity signal) must
    // never restart the outgoing transfer ring.
    final running = phase != 'paused' && phase != 'idle' &&
        (active.contains('local') || active.contains('cloud'));
    final ringColor = phase == 'idle' || running
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    final verifiedAck = serverAck.startsWith('Last ACK: ');
    final driveQueued = drive.contains('Google Drive pending');

    Widget stage({
      required String title, required String detail, required IconData icon,
      required Color accent, bool first = false, bool last = false,
      bool highlighted = false, Key? boxKey, Widget? extra,
    }) {
      return IntrinsicHeight(child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 22, child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(top: first ? 24 : 0, bottom: last ? 24 : 0,
                child: ColoredBox(color: theme.colorScheme.outlineVariant,
                  child: const SizedBox(width: 2))),
              Align(alignment: Alignment.center, child: Container(
                width: 10, height: 10,
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(color: accent, width: 2),
                ),
              )),
            ],
          )),
          Expanded(child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: DecoratedBox(
              key: boxKey,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accent.withValues(alpha: highlighted ? .9 : .32)),
                color: accent.withValues(alpha: highlighted ? .12 : .045),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(children: [
                  Icon(icon, size: 21, color: accent),
                  const SizedBox(width: 9),
                  Expanded(child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                      if (extra != null) extra,
                    ],
                  )),
                ]),
              ),
            ),
          )),
        ],
      ));
    }

    return LayoutBuilder(builder: (context, constraints) {
      final stacked = constraints.maxWidth < 420;
      final diameter = stacked ? 116.0 : 164.0;
      final ring = SizedBox.square(
        dimension: diameter,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(child: CircularProgressIndicator(
              value: running ? fraction : 0,
              strokeWidth: stacked ? 6 : 9,
              strokeCap: StrokeCap.round,
              color: ringColor,
              backgroundColor: ringColor.withValues(alpha: .22),
            )),
            Padding(
              padding: const EdgeInsets.all(14),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(phase == 'idle' ? Icons.check_circle_outline : Icons.cloud_upload_outlined,
                    color: ringColor),
                  const SizedBox(height: 4),
                  Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  Text(pendingText ?? '$pending pending', style: const TextStyle(fontSize: 11)),
                  if (running && percent != null) Text('$percent%'),
                  if (phase == 'idle')
                    Text(lastMicros == null ? 'Last sync: —'
                      : 'Last sync: ${(lastMicros! / 1000000).toStringAsFixed(2)} sec',
                      key: const ValueKey('last-verified-transfer'),
                      style: const TextStyle(fontSize: 11)),
                ]),
              ),
            ),
          ],
        ),
      );
      final stages = Column(children: [
        stage(title: 'Local Save', detail: local, icon: Icons.desktop_windows_outlined,
          accent: Colors.lightBlueAccent, first: true),
        stage(title: 'School Server ACK', detail: cloud, icon: Icons.dns_outlined,
          accent: theme.colorScheme.primary, highlighted: running && active.contains('cloud'),
          boxKey: const ValueKey('school-server-stage'),
          extra: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (running && bytes != null) ...[
                const SizedBox(height: 4),
                LinearProgressIndicator(value: fraction),
                Text('$percent% · ${bytes.offset} / ${bytes.total} bytes',
                  style: const TextStyle(fontSize: 11)),
              ],
              const SizedBox(height: 4),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.verified_outlined, size: 15,
                  color: verifiedAck ? Colors.greenAccent : theme.colorScheme.outline),
                const SizedBox(width: 6),
                Expanded(child: Text(serverAck, maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12))),
              ]),
            ],
          )),
        stage(title: 'Google Drive', detail: drive, icon: Icons.backup_outlined,
          accent: driveQueued ? Colors.cyanAccent : theme.colorScheme.outline, last: true),
      ]);
      if (stacked) {
        return Column(children: [ring, const SizedBox(height: 10), stages]);
      }
      return Row(children: [
        ring,
        const SizedBox(width: 10),
        Expanded(child: stages),
      ]);
    });
  }
}
