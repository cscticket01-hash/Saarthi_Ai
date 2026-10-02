import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'windows_ui_localization.dart';
import 'windows_platform_client.dart';

class WindowsTrialBanner extends StatelessWidget {
  const WindowsTrialBanner({super.key, required this.state, this.onActivate});
  final WindowsLicenseState state;
  final VoidCallback? onActivate;
  @override
  Widget build(BuildContext context) {
    if (state.allowed && state.status == 'licensed') return const SizedBox.shrink();
    final end = state.expiresAt.toLocal();
    final date = '${end.day}/${end.month}/${end.year}';
    return Material(color: const Color(0xFF661B24), child: InkWell(
      onTap: onActivate, child: SafeArea(bottom: false,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(children: [
          const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF8A8A), size: 22),
          const SizedBox(width: 10),
          Expanded(child: Text(state.status == 'checking'
            ? 'Checking licence. Free trial is limited to five days.'
            : state.allowed
              ? 'Free trial: ${state.daysLeft} days remaining. Ends $date. Add a licence key to continue.'
              : 'Free trial or licence ended. Add a valid school licence key to continue.',
            style: const TextStyle(color: Color(0xFFFFB4B4), fontWeight: FontWeight.w700))),
          if (onActivate != null) const Icon(Icons.chevron_right, color: Color(0xFFFFB4B4)),
        ])))));
  }
}

class WindowsLicenseGate extends StatefulWidget {
  const WindowsLicenseGate({super.key, required this.child, required this.connectionBuilder});
  final Widget child;
  final WidgetBuilder connectionBuilder;
  @override
  State<WindowsLicenseGate> createState() => _WindowsLicenseGateState();
}
class _WindowsLicenseGateState extends State<WindowsLicenseGate> {
  final _key = TextEditingController();
  bool _busy = false, _editingConnections = false, _showActivation = false;
  String? _error;
  @override
  void dispose() { _key.dispose(); super.dispose(); }
  Future<void> _activate() async {
    setState(() { _busy = true; _error = null; });
    try {
      await WindowsPlatformClient.instance.activate(_key.text);
      if (mounted) setState(() { _showActivation = false; _editingConnections = false; });
    }
    catch (e) { if (mounted) setState(() => _error = '$e'); }
    finally { if (mounted) setState(() => _busy = false); }
  }
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<WindowsLicenseState>(
    valueListenable: WindowsPlatformClient.instance.state,
    builder: (context, s, _) {
      final Widget page;
      if (_editingConnections) {
        page = Scaffold(appBar: AppBar(title: const Text('School connections'),
          leading: IconButton(icon: const Icon(Icons.arrow_back),
            onPressed: () => setState(() => _editingConnections = false))),
          body: Navigator(onGenerateRoute: (_) => MaterialPageRoute(builder: widget.connectionBuilder)));
      } else {
        page = Scaffold(appBar: s.allowed ? AppBar(title: const Text('School licence'),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: _busy ? null : () => setState(() => _showActivation = false))) : null,
          body: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Icon(Icons.vpn_key_rounded, size: 52, color: Colors.orangeAccent),
              const SizedBox(height: 18),
              const Text('Activate Vidya Saarthi', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text(s.status == 'clock_error'
                ? 'Device date/time changed. Correct the clock and reconnect.'
                : s.allowed ? 'Enter the school licence key issued by the developer website.'
                : 'Your five-day trial or school license has ended. Ask the developer for your school license key.',
                textAlign: TextAlign.center),
              const SizedBox(height: 20),
              TextField(controller: _key, decoration: const InputDecoration(
                labelText: 'School license key', border: OutlineInputBorder())),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              const SizedBox(height: 12),
              FilledButton(onPressed: _busy ? null : _activate,
                child: Text(_busy ? 'Verifying…' : 'Activate license')),
              TextButton(onPressed: _busy ? null : () => setState(() => _editingConnections = true),
                child: const Text('School connection settings')),
              TextButton(onPressed: () => WindowsPlatformClient.instance.refresh(), child: const Text('Check again')),
            ])))));
      }
      // Reserve layout space above the navigator, never overlay its app bars.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [WindowsTrialBanner(state: s, onActivate: () => setState(() {
          _showActivation = true; _editingConnections = false;
        })), Expanded(child: Stack(fit: StackFit.expand, children: [
          // Keep routes and unsaved forms mounted while visiting activation.
          if (s.allowed) Offstage(offstage: _showActivation || _editingConnections,
            child: TickerMode(enabled: s.allowed && !_showActivation && !_editingConnections, child: widget.child)),
          if (!s.allowed || _showActivation || _editingConnections) page,
        ]))],
      );
    });
}
