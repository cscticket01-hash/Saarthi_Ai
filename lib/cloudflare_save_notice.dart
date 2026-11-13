import 'dart:async';
import 'package:flutter/material.dart';

/// Presentation of already authenticated, durably retained acceptance receipts.
/// This widget never writes queue state or acknowledges Google delivery.
class CloudflareSaveNotice extends StatefulWidget {
  const CloudflareSaveNotice({super.key, required this.rows});
  final List<Map<String, dynamic>> rows;
  @override State<CloudflareSaveNotice> createState() => _CloudflareSaveNoticeState();
}
class _CloudflareSaveNoticeState extends State<CloudflareSaveNotice> {
  Timer? _expiry;
  String? _seen, _message;
  int _latestAt = 0;
  @override void initState() { super.initState(); _accept(); }
  @override void didUpdateWidget(CloudflareSaveNotice oldWidget) {
    super.didUpdateWidget(oldWidget); _accept();
  }
  void _accept() {
    final rows = widget.rows.where((r) => r['cloudflareAccepted'] == true &&
      (r['operationId'] ?? r['id']) is String && r['acceptedAt'] is int && r['acceptedAt'] > 0).toList()
      ..sort((a,b) => (b['acceptedAt'] as int).compareTo(a['acceptedAt'] as int));
    if (rows.isEmpty) {
      _expiry?.cancel(); _message = null; return;
    }
    final row = rows.first, identity = rowIdentity(rows.first);
    if (_seen == identity || (row['acceptedAt'] as int) < _latestAt) return;
    _latestAt = row['acceptedAt'] as int;
    _seen = identity;
    _expiry?.cancel();
    final operation = row['operation'];
    _message = 'Cloudflare saved · ${row['collection'] ?? 'data'} · '
        '${operation == 'write' || operation == 'delete' ? operation : 'accepted'} · ${row['recordId'] ?? row['id'] ?? ''}';
    _expiry = Timer(const Duration(seconds:5), () {
      if (mounted) setState(() => _message = null);
    });
  }
  String rowIdentity(Map row) => '${row['operationId'] ?? row['id']}:${row['acceptedAt']}';
  @override void dispose() { _expiry?.cancel(); super.dispose(); }
  @override Widget build(BuildContext context) => _message == null
      ? const SizedBox.shrink()
      : Padding(padding: const EdgeInsets.only(top:8), child: Text(_message!,
          key: const ValueKey('cloudflare-save-success')));
}
