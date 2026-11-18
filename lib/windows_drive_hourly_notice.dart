import 'dart:async';
import 'package:flutter/material.dart';

/// Presentation only. Never estimates a school-wide total from a 25-row
/// history, local ACKs, elapsed time, or an unverified transfer.
class WindowsDriveHourlyNotice extends StatefulWidget {
  const WindowsDriveHourlyNotice({super.key, required this.summary, this.nowMillis});
  final Map<String, dynamic>? summary;
  final int Function()? nowMillis;

  @override
  State<WindowsDriveHourlyNotice> createState() => _WindowsDriveHourlyNoticeState();
}

class _WindowsDriveHourlyNoticeState extends State<WindowsDriveHourlyNotice> {
  Timer? _hide;
  int? _shownHour;
  String? _message;

  @override
  void initState() {
    super.initState();
    _accept();
  }

  @override
  void didUpdateWidget(WindowsDriveHourlyNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    _accept();
  }

  void _accept() {
    final s = widget.summary;
    if (s == null || s['scope'] != 'liveRecordBackups' ||
        s['liveProtocol'] != 1 || s['verifiedCount'] is! int ||
        s['hourStart'] is! int || s['hourEnd'] is! int) return;
    final count = s['verifiedCount'] as int;
    final start = s['hourStart'] as int, end = s['hourEnd'] as int;
    final now = widget.nowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;
    if (count <= 0 || count > 1000000 ||
        end - start != const Duration(hours: 1).inMilliseconds ||
        start % const Duration(hours: 1).inMilliseconds != 0 ||
        end > now + 5000 || now - end > const Duration(minutes: 5).inMilliseconds ||
        _shownHour == start) return;
    _shownHour = start;
    _hide?.cancel();
    _message = 'Google Drive verified · $count live records in the last hour';
    _hide = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _message = null);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _message == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_message!, key: const ValueKey('hourly-verified-drive')),
        );
}
