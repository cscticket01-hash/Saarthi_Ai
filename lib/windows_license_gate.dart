import 'package:flutter/material.dart';
import 'windows_platform_client.dart';

class WindowsLicenseGate extends StatefulWidget {
  const WindowsLicenseGate(
      {super.key, required this.child, required this.connectionBuilder});
  final Widget child;
  final WidgetBuilder connectionBuilder;
  @override
  State<WindowsLicenseGate> createState() => _WindowsLicenseGateState();
}

class _WindowsLicenseGateState extends State<WindowsLicenseGate> {
  final _key = TextEditingController();
  bool _busy = false, _editingConnections = false;
  String? _error;
  @override
  void dispose() {
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
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<
          WindowsLicenseState>(
      valueListenable: WindowsPlatformClient.instance.state,
      builder: (context, s, _) {
        if (s.allowed) return widget.child;
        if (_editingConnections)
          return Scaffold(
              appBar: AppBar(
                  title: const Text('School connections'),
                  leading: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () =>
                          setState(() => _editingConnections = false))),
              body: Navigator(
                  onGenerateRoute: (_) =>
                      MaterialPageRoute(builder: widget.connectionBuilder)));
        return Scaffold(
            body: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Padding(
                        padding: const EdgeInsets.all(28),
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Icon(Icons.vpn_key_rounded,
                                  size: 52, color: Colors.orangeAccent),
                              const SizedBox(height: 18),
                              const Text('Activate Vidya Saarthi',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 25,
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 12),
                              Text(
                                  s.status == 'clock_error'
                                      ? 'Device date/time changed. Correct the clock and reconnect.'
                                      : 'Your five-day trial or school license has ended. Ask the developer for your school license key.',
                                  textAlign: TextAlign.center),
                              const SizedBox(height: 20),
                              TextField(
                                  controller: _key,
                                  decoration: const InputDecoration(
                                      labelText: 'School license key',
                                      border: OutlineInputBorder())),
                              if (_error != null)
                                Text(_error!,
                                    style: const TextStyle(
                                        color: Colors.redAccent)),
                              const SizedBox(height: 12),
                              FilledButton(
                                  onPressed: _busy ? null : _activate,
                                  child: Text(_busy
                                      ? 'Verifying…'
                                      : 'Activate license')),
                              TextButton(
                                  onPressed: () => setState(
                                      () => _editingConnections = true),
                                  child:
                                      const Text('School connection settings')),
                              TextButton(
                                  onPressed: () =>
                                      WindowsPlatformClient.instance.refresh(),
                                  child: const Text('Check again')),
                            ])))));
      });
}
