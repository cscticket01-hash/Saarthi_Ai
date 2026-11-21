import 'windows_appearance.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_dragmarker/flutter_map_dragmarker.dart';
import 'package:latlong2/latlong.dart';
import 'windows_school_map.dart';

const double _schoolPickerAreaMeters = 1000.0;

Future<SchoolMapPin?> selectWindowsSchoolMapPin(BuildContext context,
    {required String schoolName, SchoolMapPin? current, double radiusMeters = schoolAttendanceRadiusMeters}) {
  return showDialog<SchoolMapPin>(
    context: context,
    builder: (_) => _SchoolMapPinDialog(
      schoolName: schoolName,
      current: current,
      radiusMeters: radiusMeters,
    ),
  );
}

class _SchoolMapPinDialog extends StatefulWidget {
  const _SchoolMapPinDialog({
    required this.schoolName,
    this.current,
    required this.radiusMeters,
  });

  final String schoolName;
  final double radiusMeters;
  final SchoolMapPin? current;

  @override
  State<_SchoolMapPinDialog> createState() => _SchoolMapPinDialogState();
}

class _SchoolMapPinDialogState extends State<_SchoolMapPinDialog> {
  final _mapController = MapController();
  final _input = TextEditingController();
  late SchoolMapPin _areaCenter;
  SchoolMapPin? _pin;
  String? _error;
  bool _busy = false;
  int _pinRevision = 0;

  @override
  void initState() {
    super.initState();
    // Use the school's already saved coordinates. For a new school the
    // coordinate field below can set the centre before picking the pin.
    _pin = widget.current?.valid == true ? widget.current : null;
    _areaCenter = _pin ?? const SchoolMapPin(20.5937, 78.9629);
    _input.text = _pin?.coordinates ?? '';
  }

  @override
  void dispose() {
    _input.dispose();
    _mapController.dispose();
    super.dispose();
  }

  void _selectOnMap(SchoolMapPin candidate) {
    if (!candidate.valid) {
      setState(() => _error = 'Please select valid school coordinates.');
      return;
    }
    if (schoolDistanceMeters(_areaCenter, candidate) > _schoolPickerAreaMeters) {
      setState(() {
        _pinRevision++;
        _error = 'Red pin ko 1 km selection circle ke andar rakhein.';
      });
      return;
    }
    setState(() {
      _pinRevision++;
      _pin = candidate;
      _input.text = candidate.coordinates;
      _error = null;
    });
  }

  Future<void> _resolveCoordinates() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Keep existing exact coordinates / Google place-pin parser as a
      // fallback for new schools, but do not launch an external browser.
      final pin = await WindowsSchoolMaps.resolve(_input.text);
      if (!mounted) return;
      if (pin == null || !pin.valid) {
        setState(() => _error =
            'Valid latitude, longitude ya exact Google Maps place-pin link dalein.');
        return;
      }
      setState(() {
        _areaCenter = pin;
        _pin = pin;
        _pinRevision++;
        _input.text = pin.coordinates;
        _error = null;
      });
      _mapController.move(LatLng(pin.latitude, pin.longitude), 16);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Location read nahi hui. Latitude, longitude check karein.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    WindowsAppearance.watch(context);
    final area = LatLng(_areaCenter.latitude, _areaCenter.longitude);
    final height = MediaQuery.sizeOf(context).height;
    final width = MediaQuery.sizeOf(context).width;
    return AlertDialog(
      title: const Text('Pinpoint School Location'),
      content: SizedBox(
        width: (width * 0.84).clamp(300.0, 850.0),
        height: (height * 0.72).clamp(350.0, 650.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.schoolName.isEmpty ? 'School location' : widget.schoolName,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 5),
            const Text('Map par click karein ya red pin drag karein. Pin 1 km circle ke andar rahega.'),
            const SizedBox(height: 10),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: area,
                      initialZoom: 16,
                      minZoom: 3,
                      maxZoom: 19,
                      onTap: (_, point) => _selectOnMap(
                          SchoolMapPin(point.latitude, point.longitude)),
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'org.saarthi.school',
                      ),
                      CircleLayer(circles: [
                        CircleMarker(
                          point: area,
                          radius: _schoolPickerAreaMeters,
                          useRadiusInMeter: true,
                          color: const Color(0x2255B3A6),
                          borderColor: const Color(0xFF008E80),
                          borderStrokeWidth: 2,
                        ),
                      ]),
                      DragMarkers(markers: [
                        DragMarker(
                            key: ValueKey('win002-red-pin-${_pinRevision}'),
                            point: LatLng(
                              (_pin ?? _areaCenter).latitude,
                              (_pin ?? _areaCenter).longitude,
                            ),
                            size: const Size.square(54),
                            offset: const Offset(0, -18),
                            builder: (_) => const Icon(
                              Icons.location_on,
                              color: Colors.red,
                              size: 52,
                            ),
                            onDragEnd: (_, point) => _selectOnMap(
                                SchoolMapPin(point.latitude, point.longitude)),
                          ),
                      ]),
                    ],
                  ),
                  Positioned(
                    right: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      color: Colors.white,
                      child: const Text('© OpenStreetMap contributors',
                          style: TextStyle(color: Colors.black87, fontSize: 10)),
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Text('Selected: ${_pin?.coordinates ?? 'Map par school pin select karein'}'),
            Text('Selection area: 1 km • Attendance boundary: ${widget.radiusMeters.toStringAsFixed(0)} metres',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(
              controller: _input,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Latitude, longitude or exact Google Maps link (optional)',
                hintText: '24.8000000, 92.8000000',
              ),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : () async {
                  final clip = await Clipboard.getData(Clipboard.kTextPlain);
                  if (!mounted) return;
                  _input.text = clip?.text?.trim() ?? '';
                  await _resolveCoordinates();
                },
                icon: const Icon(Icons.content_paste),
                label: const Text('Paste location'),
              ),
              OutlinedButton(
                onPressed: _busy ? null : _resolveCoordinates,
                child: const Text('Read location'),
              ),
            ]),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          key: const ValueKey('win002-save-location'),
          onPressed: _busy || _pin == null ? null : () => Navigator.pop(context, _pin),
          child: const Text('Save Location'),
        ),
      ],
    );
  }
}
