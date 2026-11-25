import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'windows_notification_sound_stub.dart'
  if (dart.library.io) 'windows_notification_sound_io.dart' as native;

/// Settings are PC-local; they never enter the school sync outbox.
class WindowsNotificationSound {
  static const enabledKey = 'windows_notification_sound_enabled_v1';
  static const volumeKey = 'windows_notification_sound_volume_v1';
  static bool _playing = false;
  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(enabledKey) ?? true;
  static Future<int> volume() async =>
      ((await SharedPreferences.getInstance()).getInt(volumeKey) ?? 70).clamp(0, 100).toInt();
  static Future<void> setEnabled(bool value) async {
    if (!await (await SharedPreferences.getInstance()).setBool(enabledKey, value)) {
      throw StateError('Could not save notification sound preference.');
    }
  }
  static Future<void> setVolume(int value) async {
    if (!await (await SharedPreferences.getInstance()).setInt(volumeKey, value.clamp(0, 100).toInt())) {
      throw StateError('Could not save notification volume.');
    }
  }
  static Future<void> playIfEnabled() async {
    if (await enabled()) await play(await volume());
  }
  static Future<void> play(int value) async {
    if (_playing || value <= 0) return;
    _playing = true;
    try { await native.playWarmBell(value.clamp(0, 100).toInt()); }
    finally { _playing = false; }
  }
}

class WindowsNotificationSoundCard extends StatefulWidget {
  const WindowsNotificationSoundCard({super.key});
  @override
  State<WindowsNotificationSoundCard> createState() => _WindowsNotificationSoundCardState();
}

class _WindowsNotificationSoundCardState extends State<WindowsNotificationSoundCard> {
  bool _enabled = true, _loading = true, _saving = false, _testing = false;
  int _volume = 70;
  String? _error;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final preferences = await SharedPreferences.getInstance().timeout(const Duration(seconds: 5));
      final enabled = preferences.getBool(WindowsNotificationSound.enabledKey) ?? true;
      final volume = (preferences.getInt(WindowsNotificationSound.volumeKey) ?? 70).clamp(0, 100).toInt();
      if (mounted) setState(() { _enabled = enabled; _volume = volume; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load sound settings.'; });
    }
  }
  Future<void> _save({bool? enabled, int? volume}) async {
    if (_saving) return;
    setState(() { _saving = true; _error = null; });
    try {
      if (enabled != null) await WindowsNotificationSound.setEnabled(enabled);
      if (volume != null) await WindowsNotificationSound.setVolume(volume);
      if (mounted) setState(() { if (enabled != null) _enabled = enabled; if (volume != null) _volume = volume; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not save sound settings.'; });
      await _load();
    } finally { if (mounted) setState(() => _saving = false); }
  }
  Future<void> _test() async {
    setState(() { _testing = true; _error = null; });
    try { await WindowsNotificationSound.play(_volume); }
    catch (_) { if (mounted) setState(() => _error = 'Could not play sound. Check Windows audio.'); }
    finally { if (mounted) setState(() => _testing = false); }
  }
  @override
  Widget build(BuildContext context) => Card(child: Padding(
    padding: const EdgeInsets.all(16),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text('Notification Sound', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const Text('Warm Bell • Ding Dong'),
      if (_loading) const Text('Loading sound preferences…') else ...[
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Play sound for new notifications'),
          value: _enabled, onChanged: _saving ? null : (v) => _save(enabled: v)),
        Text('Volume: $_volume%'),
        Slider(value: _volume.toDouble(), min: 0, max: 100, divisions: 20,
          label: '$_volume%', onChanged: _saving ? null : (v) => setState(() => _volume = v.round()),
          onChangeEnd: _saving ? null : (v) => _save(volume: v.round())),
        OutlinedButton.icon(onPressed: _testing || _saving || _volume == 0 ? null : _test,
          icon: const Icon(Icons.volume_up_outlined), label: Text(_testing ? 'Playing…' : 'Test Sound')),
      ],
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
    ]),
  ));
}
