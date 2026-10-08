import 'package:flutter/material.dart' hide Text, InputDecoration;

import 'windows_ui_localization.dart';
import 'windows_platform_client.dart';

class WindowsTrialBanner extends StatelessWidget {
  const WindowsTrialBanner({
    super.key,
    required this.state,
    this.onActivate,
    this.licenseSkipped = false,
  });
  final WindowsLicenseState state;
  final VoidCallback? onActivate;
  final bool licenseSkipped;
  @override
  Widget build(BuildContext context) {
    final licensed = state.allowed && state.status == 'licensed';
    // A skipped licence keeps showing a red warning until real activation.
    if (licensed) return const SizedBox.shrink();
    final end = state.expiresAt.toLocal();
    final date =
        '${end.day.toString().padLeft(2, '0')}/${end.month.toString().padLeft(2, '0')}/${end.year}';
    final dateLabel = state.status == 'trial'
        ? 'Trial ends: $date'
        : state.status == 'expired'
        ? 'Trial/licence ended: $date'
        : state.status == 'blocked'
        ? 'Licence blocked • Saved expiry: $date'
        : state.status == 'clock_error'
        ? 'Correct device date/time to verify expiry'
        : 'Expiry date pending verification';
    if (licenseSkipped) {
      return Material(
        key: const ValueKey('license-not-activated-banner'),
        color: const Color(0xFF661B24),
        child: InkWell(
          onTap: onActivate,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFFF8A8A),
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Wrap(
                      spacing: 18,
                      runSpacing: 4,
                      children: [
                        const Text(
                          'License not activated — Activate now',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          dateLabel,
                          style: const TextStyle(
                            color: Color(0xFFFFC4C4),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onActivate != null)
                    const Icon(Icons.chevron_right, color: Colors.white),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Material(
      color: const Color(0xFF661B24),
      child: InkWell(
        onTap: onActivate,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFFF8A8A),
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    state.status == 'checking'
                        ? 'Checking licence. Free trial is limited to five days.'
                        : state.allowed
                        ? 'Free trial: ${state.daysLeft} days remaining. Ends $date. Add a licence key to continue.'
                        : 'Free trial or licence ended. Add a valid school licence key to continue.',
                    style: const TextStyle(
                      color: Color(0xFFFFB4B4),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (onActivate != null)
                  const Icon(Icons.chevron_right, color: Color(0xFFFFB4B4)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// First-run flow of the Windows app:
///   License screen -> (Skip) -> Admin Setup -> Home.
/// The licence screen only asks for a key and offers Skip; no school/Firebase
/// configuration, no "Check again", no connection-error UI is shown here.
class WindowsLicenseGate extends StatefulWidget {
  static final resetSignal = ValueNotifier<int>(0);
  static void reopenAfterReset() => resetSignal.value++;
  const WindowsLicenseGate({
    super.key,
    required this.child,
    this.connectionBuilder,
  });
  final Widget child;

  /// Kept optional so Settings can still surface advanced connections later;
  /// the first-run licence screen never shows it.
  final WidgetBuilder? connectionBuilder;
  @override
  State<WindowsLicenseGate> createState() => _WindowsLicenseGateState();
}

class _WindowsLicenseGateState extends State<WindowsLicenseGate> {
  final _key = TextEditingController();
  bool _busy = false, _showActivation = false;
  bool _resolved = false, _skipped = false, _entered = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WindowsLicenseGate.resetSignal.addListener(_reset);
    WindowsPlatformClient.instance.licenseSkipped().then((value) {
      if (mounted)
        setState(() {
          _skipped = value;
          _resolved = true;
        });
    });
  }

  void _reset() {
    if (mounted)
      setState(() {
        _skipped = false;
        _entered = false;
        _showActivation = false;
        _resolved = true;
        _error = null;
      });
  }

  @override
  void dispose() {
    WindowsLicenseGate.resetSignal.removeListener(_reset);
    _key.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await WindowsPlatformClient.instance.activate(_key.text);
      _key.clear();
      if (mounted)
        setState(() {
          _showActivation = false;
          _skipped = false;
        });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _skip() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await WindowsPlatformClient.instance.markLicenseSkipped();
      if (mounted)
        setState(() {
          _skipped = true;
          _showActivation = false;
        });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save Skip: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _licenseScreen({
    required WindowsLicenseState s,
    bool blocking = false,
  }) => Scaffold(
    appBar: blocking
        ? null
        : AppBar(
            title: const Text('School licence'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _busy
                  ? null
                  : () => setState(() => _showActivation = false),
            ),
          ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(
                Icons.vpn_key_rounded,
                size: 52,
                color: Colors.orangeAccent,
              ),
              const SizedBox(height: 18),
              const Text(
                'Activate Vidya Saarthi',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                s.status == 'clock_error'
                    ? 'Device date/time changed. Correct the clock and reconnect.'
                    : s.allowed
                    ? 'Enter the school licence key issued by the developer website.'
                    : 'Your trial or school license has ended. Activate a valid key, or Skip to continue using the app.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _key,
                decoration: const InputDecoration(
                  labelText: 'School license key',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null)
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _activate,
                child: Text(_busy ? 'Verifying…' : 'Activate / Verify license'),
              ),
              ...[
                const SizedBox(height: 6),
                TextButton(
                  key: const ValueKey('license-skip-button'),
                  onPressed: _busy ? null : _skip,
                  child: const Text('Skip'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<WindowsLicenseState>(
    valueListenable: WindowsPlatformClient.instance.state,
    builder: (context, s, _) {
      // Fresh installs see ONLY the licence key screen first.
      if (!_resolved)
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      final licensed = s.allowed && s.status == 'licensed';
      final showFirstRun = !_entered && !_skipped && !licensed;
      if (showFirstRun) return _licenseScreen(s: s, blocking: true);
      // Skip grants local app access independently of the licence/trial state.
      // Keep verification strict: only a valid licence can remove the warning.
      _entered = true;
      final activating = _showActivation;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          WindowsTrialBanner(
            state: s,
            licenseSkipped: !licensed,
            onActivate: () => setState(() => _showActivation = true),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Keep routes and unsaved forms mounted while visiting activation.
                Offstage(
                  offstage: activating,
                  child: TickerMode(enabled: !activating, child: widget.child),
                ),
                if (activating) _licenseScreen(s: s),
              ],
            ),
          ),
        ],
      );
    },
  );
}
