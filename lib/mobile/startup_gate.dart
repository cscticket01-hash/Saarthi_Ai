import 'dart:async';
import 'package:flutter/material.dart';

/// Paint before accessing Android Keystore. Never open protected screens until
/// the existing session validation has completed; never erase data on failure.
class MobileStartupGate extends StatefulWidget {
  const MobileStartupGate({super.key, required this.restore,
    required this.readyBuilder, this.onReady,
    this.warningAfter = const Duration(seconds: 8)});
  final Future<void> Function() restore;
  final WidgetBuilder readyBuilder;
  final VoidCallback? onReady;
  final Duration warningAfter;
  @override
  State<MobileStartupGate> createState() => _MobileStartupGateState();
}

class _MobileStartupGateState extends State<MobileStartupGate> {
  Timer? _warning;
  bool _ready = false, _slow = false, _failed = false, _pending = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_restore());
    });
  }
  Future<void> _restore() async {
    if (_pending) return;
    setState(() { _pending = true; _failed = false; _slow = false; });
    _warning = Timer(widget.warningAfter, () {
      if (mounted) setState(() => _slow = true);
    });
    try {
      await widget.restore();
      if (!mounted) return;
      setState(() => _ready = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReady?.call();
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      _warning?.cancel();
      _pending = false;
    }
  }
  @override
  void dispose() { _warning?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.readyBuilder(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(body: Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Vidya Saarthi', style: TextStyle(fontSize: 24)),
          const SizedBox(height: 20),
          if (!_failed) const CircularProgressIndicator(),
          const SizedBox(height: 20),
          Text(_failed
            ? 'Saved session could not be opened. Your saved data has not been cleared.'
            : _slow
              ? 'Secure storage is taking longer than expected. You can close and reopen the app. Do not clear app data.'
              : 'Opening your saved school session…', textAlign: TextAlign.center),
          if (_failed) TextButton(onPressed: () => unawaited(_restore()),
            child: const Text('Retry')),
        ]),
      ))),
    );
  }
}
