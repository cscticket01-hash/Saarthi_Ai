import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'windows_school_map.dart';

Future<SchoolMapPin?> selectWindowsSchoolMapPin(BuildContext context,
    {required String schoolName, SchoolMapPin? current, double radiusMeters = schoolAttendanceRadiusMeters}) {
  return showDialog<SchoolMapPin>(context: context,
      builder: (_) => _SchoolMapPinDialog(schoolName: schoolName, current: current, radiusMeters: radiusMeters));
}

class _SchoolMapPinDialog extends StatefulWidget {
  const _SchoolMapPinDialog({required this.schoolName, this.current, required this.radiusMeters});
  final String schoolName;
  final double radiusMeters;
  final SchoolMapPin? current;
  @override
  State<_SchoolMapPinDialog> createState() => _SchoolMapPinDialogState();
}

class _SchoolMapPinDialogState extends State<_SchoolMapPinDialog> with WidgetsBindingObserver {
  final _input = TextEditingController();
  SchoolMapPin? _pin;
  String? _error;
  bool _busy = false;
  bool _mapOpened = false;
  String _clipboardBeforeMap = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pin = widget.current?.valid == true ? widget.current : null;
    _input.text = _pin?.coordinates ?? '';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _input.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _mapOpened && !_busy) {
      _importClipboard(onlyNew: true);
    }
  }

  Future<void> _open({bool preview = false}) async {
    try {
      _clipboardBeforeMap = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
      final query = widget.schoolName.trim().isNotEmpty ? widget.schoolName : 'school';
      final uri = preview ? _pin!.mapsUri : schoolMapsSearchUri(query);
      await WindowsSchoolMaps.open(uri);
      if (mounted) setState(() { _mapOpened = true; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _importClipboard({bool onlyNew = false}) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted || (onlyNew && (text.isEmpty || text == _clipboardBeforeMap))) return;
    if (onlyNew && parseSchoolMapPin(text) == null &&
        !text.startsWith('https://maps.app.goo.gl/')) return;
    _input.text = text;
    await _resolve();
  }

  Future<void> _resolve() async {
    if (_busy) return;
    setState(() { _busy = true; _pin = null; _error = null; });
    try {
      final pin = await WindowsSchoolMaps.resolve(_input.text);
      if (!mounted) return;
      setState(() {
        _pin = pin;
        if (pin == null) {
          _error = 'Selected school location nahi mila. Google Maps mein school ke exact point par right-click karke pehli coordinate line copy karein. Sirf map ka camera-centre link accept nahi hota.';
        }
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Map link read nahi hua. School location ke latitude, longitude copy karke paste karein.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select school location on Google Maps'),
      content: SizedBox(width: 590, child: SingleChildScrollView(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.schoolName.isEmpty ? 'School location' : widget.schoolName,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          const Text('1. Open Google Maps and zoom to the school campus.\n2. Right-click the exact attendance point; copy the first latitude, longitude line.\n3. Return here, paste the location and confirm it.'),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: _busy ? null : () => _open(),
              icon: const Icon(Icons.map), label: const Text('Open Google Maps in browser')),
          const SizedBox(height: 16),
          TextField(controller: _input, maxLines: 2,
              onChanged: (_) => setState(() { _pin = null; _error = null; }),
              decoration: const InputDecoration(border: OutlineInputBorder(),
                  labelText: 'School location coordinates or Google Maps place link',
                  hintText: '24.8000000, 92.8000000')),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: _busy ? null : () => _importClipboard(),
                icon: const Icon(Icons.content_paste), label: const Text('Paste selected location')),
            OutlinedButton(onPressed: _busy ? null : _resolve, child: const Text('Read location')),
          ]),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (_pin != null) ...[
            const SizedBox(height: 12),
            Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_pin!.name.isNotEmpty) Text(_pin!.name),
                SelectableText('School location: ${_pin!.coordinates}'),
                Text('Attendance boundary: ${widget.radiusMeters.toStringAsFixed(0)} metres from this location'),
                TextButton.icon(onPressed: () => _open(preview: true),
                    icon: const Icon(Icons.location_on), label: const Text('Verify this exact location in Google Maps')),
              ]))),
          ],
          const SizedBox(height: 8),
          const Text('Choose the school campus point, not this PC location. GPS accuracy on the attendance device is checked separately.'),
        ],
      ))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy || _pin == null ? null : () => Navigator.pop(context, _pin),
            child: Text('Use this school location • ${widget.radiusMeters.toStringAsFixed(0)} m')),
      ],
    );
  }
}
