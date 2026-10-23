import 'school_request_deadlines.dart';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

/// The exact school PDF; a failed/empty load stays retryable, never a fake card.
class PublishedIdCard extends StatefulWidget {
  const PublishedIdCard({
    super.key,
    required this.load,
    required this.refresh,
    required this.open,
    this.openExternally,
    this.rasterize,
    this.automatic = false,
    this.loadTimeout = schoolIdLoadTimeout,
    this.previewTimeout = const Duration(seconds: 8),
  });
  final Future<Uint8List?> Function() load;
  final Future<void> Function() refresh;
  final Future<void> Function(Uint8List) open;
  final Future<void> Function(Uint8List)? openExternally;
  final Future<Uint8List> Function(Uint8List)? rasterize;
  final bool automatic;
  final Duration loadTimeout, previewTimeout;
  @override
  State<PublishedIdCard> createState() => _PublishedIdCardState();
}

class _PublishedIdCardState extends State<PublishedIdCard> {
  Uint8List? _pdf;
  List<Uint8List> _images = [];
  bool _loading = true, _failed = false, _previewFailed = false;
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
      _previewFailed = false;
    });
    try {
      final pdf = await (() async {
        if (refresh) await widget.refresh();
        var result = await widget.load();
        if (result == null && !refresh && widget.automatic) {
          await widget.refresh();
          if (!mounted || generation != _generation) return null;
          result = await widget.load();
        }
        return result;
      })().timeout(widget.loadTimeout);
      if (!mounted || generation != _generation) return;
      // Publish verified bytes before waiting on the native raster plugin.
      setState(() {
        _pdf = pdf;
        _images = [];
        _loading = false;
      });
      if (pdf != null) unawaited(_preview(pdf, generation));
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (mounted && generation == _generation)
        setState(() => _loading = false);
    }
  }

  Future<void> _preview(Uint8List pdf, int generation) async {
    try {
      final images = await (() async {
        if (widget.rasterize != null) return [await widget.rasterize!(pdf)];
        final pages = <Uint8List>[];
        await for (final page in Printing.raster(pdf, dpi: 120).take(2)) {
          pages.add(await page.toPng());
        }
        if (pages.isEmpty) throw StateError('Empty preview');
        return pages;
      })().timeout(widget.previewTimeout);
      if (mounted && generation == _generation)
        setState(() => _images = images);
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() => _previewFailed = true);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (_images.isNotEmpty)
        for (final image in _images)
          InkWell(
            onTap: () => widget.open(_pdf!),
            child: Image.memory(image, height: 280, fit: BoxFit.contain),
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
                : widget.automatic
                ? 'Your school has not published an ID card for this account yet.'
                : 'Your school is preparing your ID card. Refresh to check again.',
            textAlign: TextAlign.center,
          ),
        ),
      if (_pdf != null && (!widget.automatic || _previewFailed))
        FilledButton.icon(
          onPressed: () => widget.open(_pdf!),
          icon: const Icon(Icons.badge_outlined),
          label: const Text('Open my ID card'),
        ),
      if (_pdf != null && _previewFailed && widget.openExternally != null)
        TextButton.icon(
          onPressed: () => widget.openExternally!(_pdf!),
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open PDF viewer'),
        ),
      TextButton.icon(
        onPressed: _loading ? null : () => _load(true),
        icon: const Icon(Icons.refresh),
        label: const Text('Refresh ID card'),
      ),
    ],
  );
}
