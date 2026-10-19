import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

/// The exact school PDF; a failed/empty load stays retryable, never a fake card.
class PublishedIdCard extends StatefulWidget {
  const PublishedIdCard({
    super.key,
    required this.load,
    required this.refresh,
    required this.open,
    this.rasterize,
  });
  final Future<Uint8List?> Function() load;
  final Future<void> Function() refresh;
  final Future<void> Function(Uint8List) open;
  final Future<Uint8List> Function(Uint8List)? rasterize;
  @override
  State<PublishedIdCard> createState() => _PublishedIdCardState();
}

class _PublishedIdCardState extends State<PublishedIdCard> {
  Uint8List? _pdf, _image;
  bool _loading = true, _failed = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load(false);
  }

  Future<void> _load(bool refresh) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      if (refresh) await widget.refresh();
      final pdf = await widget.load();
      Uint8List? image;
      if (pdf != null) {
        try {
          image = widget.rasterize != null
              ? await widget.rasterize!(pdf)
              : await (await Printing.raster(
                  pdf,
                  pages: [0],
                  dpi: 100,
                ).first).toPng();
        } catch (_) {
          /* A preview failure must not disable the actual PDF. */
        }
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _pdf = pdf;
        _image = image;
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation)
        setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (_image != null)
        InkWell(
          onTap: () => widget.open(_pdf!),
          child: Image.memory(_image!, height: 240, fit: BoxFit.contain),
        )
      else
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _loading
                ? 'Loading your ID card…'
                : _failed
                ? 'Unable to load your ID card. Please try again.'
                : _pdf != null
                ? 'Your school ID card is ready.'
                : 'Your school is preparing your ID card. Refresh to check again.',
            textAlign: TextAlign.center,
          ),
        ),
      if (_pdf != null)
        FilledButton.icon(
          onPressed: () => widget.open(_pdf!),
          icon: const Icon(Icons.badge_outlined),
          label: const Text('Open my ID card'),
        ),
      TextButton.icon(
        onPressed: _loading ? null : () => _load(true),
        icon: const Icon(Icons.refresh),
        label: const Text('Refresh ID card'),
      ),
    ],
  );
}
