import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'school_session.dart';

/// Complaints stay in the authenticated school inbox; history has no disk cache.
class MobileComplaintScreen extends StatefulWidget {
  const MobileComplaintScreen({super.key, required this.session});
  final SchoolSession session;
  @override
  State<MobileComplaintScreen> createState() => _MobileComplaintScreenState();
}

class _MobileComplaintScreenState extends State<MobileComplaintScreen> {
  final _message = TextEditingController();
  late final Object? _owner = widget.session.link;
  final List<Map<String, dynamic>> _history = [];
  String? _cursor, _pendingId, _pendingText, _error;
  bool _sending = false, _loading = false;
  bool get _current =>
      mounted &&
      identical(_owner, widget.session.link) &&
      widget.session.loggedIn;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (_loading || !_current) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final out = await widget.session.platformCall('complaint/list', {
        if (more && _cursor != null) 'cursor': _cursor,
      });
      if (!_current) return;
      final rows = (out['complaints'] as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
      setState(() {
        if (!more) _history.clear();
        _history.addAll(rows);
        _cursor = out['cursor'] as String?;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _message.text.trim();
    if (text.length < 3 || text.length > 3000) {
      setState(() => _error = 'Use 3–3000 characters.');
      return;
    }
    if (!_current) return;
    _pendingText ??= text;
    _pendingId ??= List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      String device =
          '${Platform.operatingSystem} • ${Platform.operatingSystemVersion}';
      try {
        device =
            await const MethodChannel(
              'vidyasaarthi/school_messaging',
            ).invokeMethod<String>('deviceInfo') ??
            device;
      } catch (_) {}
      if (!_current) return;
      await widget.session.platformCall('complaint/create', {
        'complaintId': _pendingId,
        'message': _pendingText,
        'version': SchoolSession.version,
        'deviceId': widget.session.deviceId,
        'device': device,
      });
      if (!_current) return;
      _pendingId = null;
      _pendingText = null;
      _message.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Complaint sent to your school.')),
      );
      await _load();
    } catch (e) {
      if (mounted)
        setState(
          () => _error =
              '$e\nRetry sends the same complaint without creating a duplicate.',
        );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Report a problem'),
      actions: [
        IconButton(
          onPressed: _loading ? null : () => _load(),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: !_current
        ? const Center(child: Text('School account changed. Reopen this page.'))
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text('Send a complaint to your school'),
              const SizedBox(height: 12),
              TextField(
                controller: _message,
                enabled: !_sending && _pendingId == null,
                minLines: 4,
                maxLines: 8,
                maxLength: 3000,
                decoration: const InputDecoration(
                  hintText: 'Describe what happened. Do not include passwords.',
                ),
              ),
              FilledButton.icon(
                onPressed: _sending || !_current ? null : _send,
                icon: const Icon(Icons.send),
                label: Text(
                  _sending
                      ? 'Sending…'
                      : _pendingId != null
                      ? 'Retry complaint'
                      : 'Send complaint',
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(_error!),
                ),
              const Divider(height: 32),
              const Text(
                'Complaint history',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const Text(
                'Solved complaints are deleted three months after resolution.',
              ),
              if (_loading) const LinearProgressIndicator(),
              if (!_loading && _history.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No complaints yet.'),
                ),
              for (final row in _history)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(row['message'].toString()),
                        Text(
                          '${row['status']} • ${DateTime.fromMillisecondsSinceEpoch((row['createdAt'] as num).toInt()).toLocal()}',
                        ),
                        if ((row['reply'] ?? '').toString().isNotEmpty)
                          Text('School: ${row['reply']}'),
                      ],
                    ),
                  ),
                ),
              if (_cursor != null)
                TextButton(
                  onPressed: _loading ? null : () => _load(more: true),
                  child: const Text('Load older complaints'),
                ),
            ],
          ),
  );
}
