import 'dart:async';

import 'package:flutter/material.dart' hide Text;

import 'windows_connection_center.dart';
import 'windows_ui_localization.dart';

/// The optional school connection check never prevents opening the local app.
/// The outer licence gate and the child's saved password still apply.
class WindowsOnlineStartupGate extends StatefulWidget {
  const WindowsOnlineStartupGate({
    super.key,
    required this.child,
    this.initializeConnections = WindowsConnectionCenter.initialize,
  });

  final Widget child;
  final Future<void> Function() initializeConnections;

  @override
  State<WindowsOnlineStartupGate> createState() =>
      _WindowsOnlineStartupGateState();
}

class _WindowsOnlineStartupGateState extends State<WindowsOnlineStartupGate> {
  bool _opened = false;
  bool _checking = true;
  int _attempt = 0;
  String? _message;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final attempt = ++_attempt;
    try {
      await widget.initializeConnections().timeout(const Duration(seconds: 8));
      if (!mounted || _opened || attempt != _attempt) return;
      setState(() => _opened = true);
    } catch (error) {
      if (!mounted || _opened || attempt != _attempt) return;
      debugPrint('Windows optional startup connection check: $error');
      setState(() {
        _checking = false;
        _message = 'Online check is unavailable. You can still open the app.';
      });
    }
  }

  void _open() {
    // Continue only past this optional check, never past a password/licence.
    ++_attempt;
    setState(() => _opened = true);
  }

  void _retry() {
    setState(() {
      _checking = true;
      _message = null;
    });
    _check();
  }

  @override
  Widget build(BuildContext context) {
    if (_opened) return widget.child;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.school_rounded,
                    size: 52, color: Color(0xFF00D9A5)),
                const SizedBox(height: 18),
                const Text('Opening Vidya Saarthi',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Text(
                  _message ??
                      'Checking school connections. You can open the app offline.',
                  textAlign: TextAlign.center,
                ),
                if (_checking) ...[
                  const SizedBox(height: 18),
                  const Center(child: CircularProgressIndicator()),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const ValueKey('windows-startup-skip'),
                  onPressed: _open,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('Skip / Open app'),
                ),
                if (!_checking)
                  TextButton(
                    key: const ValueKey('windows-startup-retry'),
                    onPressed: _retry,
                    child: const Text('Retry online check'),
                  ),
                const SizedBox(height: 12),
                const Text('Your saved password and licence still apply.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
