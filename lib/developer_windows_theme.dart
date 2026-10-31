import 'package:flutter/material.dart';

import 'platform/managed_developer_service.dart';
import 'windows_theme_presets.dart';

class DeveloperWindowsTheme extends StatefulWidget {
  const DeveloperWindowsTheme({super.key, this.request});
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
  request;
  @override
  State<DeveloperWindowsTheme> createState() => _DeveloperWindowsThemeState();
}

class _DeveloperWindowsThemeState extends State<DeveloperWindowsTheme> {
  static const quickColours = <String, Color>{
    'Teal': Color(0xFF008C78),
    'Ocean': Color(0xFF2563EB),
    'Violet': Color(0xFF7C3AED),
    'Amber': Color(0xFFD97706),
    'Rose': Color(0xFFE11D48),
  };
  final rgb = List.generate(3, (_) => TextEditingController());
  final hex = TextEditingController();
  Color draft = const Color(0xFF008C78), saved = const Color(0xFF008C78);
  HSVColor hsv = HSVColor.fromColor(const Color(0xFF008C78));
  String revision = 'default';
  String? error, inputError, draftPreset, savedPreset;
  bool busy = true, loaded = false;
  Future<Map<String, dynamic>> call(String action, Map<String, dynamic> body) =>
      (widget.request ?? ManagedDeveloperService.call)(action, body);
  bool get dirty =>
      draft.toARGB32() != saved.toARGB32() || draftPreset != savedPreset;
  @override
  void initState() {
    super.initState();
    fields();
    load();
  }

  @override
  void dispose() {
    for (final c in rgb) c.dispose();
    hex.dispose();
    super.dispose();
  }

  List<int> channels(Color c) => [
    (c.r * 255).round(),
    (c.g * 255).round(),
    (c.b * 255).round(),
  ];
  void fields() {
    final v = channels(draft);
    for (var i = 0; i < 3; i++) rgb[i].text = '${v[i]}';
    hex.text =
        '#${draft.toARGB32().toRadixString(16).substring(2).toUpperCase()}';
  }

  void change(Color c, {HSVColor? selection, String? presetId, bool clearPreset = false}) {
    setState(() {
      // RGB/HEX/HSV edits customize the SELECTED preset instead of
      // silently switching to another preset or generic blue screenshot.
      draftPreset = clearPreset ? null : (presetId ?? draftPreset);
      draft = c;
      hsv = selection ?? HSVColor.fromColor(c);
      inputError = null;
      fields();
    });
  }

  void apply(Map theme) {
    final v = ['red', 'green', 'blue'].map((k) => theme[k]).toList();
    if (v.any((x) => x is! int || x < 0 || x > 255) ||
        theme['revision'] is! String)
      throw const FormatException('Invalid saved theme');
    draft = Color.fromARGB(255, v[0] as int, v[1] as int, v[2] as int);
    saved = draft;
    draftPreset = windowsThemePreset(theme['presetId'] as String?)?.id;
    savedPreset = draftPreset;
    hsv = HSVColor.fromColor(draft);
    revision = theme['revision'];
    inputError = null;
    fields();
  }

  Future<void> load() async {
    setState(() => busy = true);
    try {
      final r = await call('theme/get', {});
      if (mounted)
        setState(() {
          apply(r['theme'] as Map);
          loaded = true;
          error = null;
        });
    } catch (_) {
      if (mounted)
        setState(
          () => error =
              'Saved theme could not be loaded. Retry before publishing.',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || !loaded || inputError != null) return;
    setState(() => busy = true);
    final v = channels(draft);
    final selectedPreset = draftPreset;
    try {
      final r = await call('theme/save', {
        'theme': {
          'schemaVersion': 1,
          'red': v[0],
          'green': v[1],
          'blue': v[2],
          'presetId': draftPreset,
          'expectedRevision': revision,
        },
      });
      if ((r['theme'] as Map)['presetId'] != selectedPreset)
        throw const FormatException('Preset was not confirmed by server');
      if (mounted) {
        setState(() {
          apply(r['theme'] as Map);
          error = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Theme saved. Windows applies it after App Lock password unlock.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted)
        setState(
          () => error = 'Theme was not confirmed. Your draft is retained. Reload if another developer changed the saved theme.',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  static const pages = ['dashboard', 'students', 'fees', 'settings'];
  static const pageNames = [
    'Dashboard',
    'Student Records',
    'Fees Collection',
    'Settings',
  ];
  int slide = 0;
  String get previewAsset => draftPreset == null
      ? 'assets/app_screenshot_${pages[slide] == 'settings' ? 'settings_v2' : pages[slide]}.png'
      : 'assets/theme_preview_${draftPreset == 'midnight-glass' ? 'electric-blue' : draftPreset}_${pages[slide] == 'settings' ? 'settings_v2' : pages[slide]}.webp';
  Widget panel(Widget child) => Card(
    margin: EdgeInsets.zero,
    child: Padding(padding: const EdgeInsets.all(14), child: child),
  );
  Widget preview() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Theme Preview',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
            ),
            Text(
              '${pageNames[slide]}  •  ${slide + 1} / 4',
              key: const ValueKey('theme-slide-label'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${windowsThemePreset(draftPreset)?.name ?? 'Custom colour'} • sample app screens',
          key: const ValueKey('theme-preview-name'),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('theme-previous'),
                tooltip: 'Previous screenshot',
                onPressed: () => setState(() => slide = (slide + 3) % 4),
                icon: const Icon(Icons.chevron_left, size: 32),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: Container(
                      key: ValueKey('$previewAsset:${draft.toARGB32()}'),
                      foregroundDecoration: draftPreset == 'midnight-glass'
                          ? BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Colors.white.withValues(alpha: .07),
                                  const Color(0xFF0D1726).withValues(alpha: .13),
                                  const Color(0xFF48E5B5).withValues(alpha: .05),
                                ],
                              ),
                            )
                          : null,
                      child: draftPreset == 'midnight-glass'
                        ? _MidnightGlassPreview(
                            key: const ValueKey('theme-preview-glass'),
                            page: pageNames[slide],
                            tint: draft,
                            screenshot: previewAsset,
                          )
                        : ColorFiltered(
                            colorFilter: ColorFilter.mode(
                              draft,
                              (draftPreset == null || draft.toARGB32() != windowsThemePreset(draftPreset)?.seed.toARGB32())
                                  ? BlendMode.hue : BlendMode.dst,
                            ),
                            child: Image.asset(
                              previewAsset,
                              key: const ValueKey('theme-preview-image'),
                              fit: BoxFit.contain,
                              semanticLabel:
                                  '${pageNames[slide]} in ${windowsThemePreset(draftPreset)?.name ?? 'custom colour'}',
                            ),
                          ),
                    ),
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('theme-next'),
                tooltip: 'Next screenshot',
                onPressed: () => setState(() => slide = (slide + 1) % 4),
                icon: const Icon(Icons.chevron_right, size: 32),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            4,
            (i) => IconButton(
              tooltip: pageNames[i],
              onPressed: () => setState(() => slide = i),
              icon: Icon(
                i == slide ? Icons.circle : Icons.circle_outlined,
                size: 10,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ),
        const Text(
          'Preview only. Save Theme publishes your selection.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
  Widget editor() => panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Custom colour',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (c, s) => GestureDetector(
              onPanUpdate: busy || !loaded
                  ? null
                  : (d) => pick(d.localPosition, s.maxWidth, s.maxHeight),
              onTapDown: busy || !loaded
                  ? null
                  : (d) => pick(d.localPosition, s.maxWidth, s.maxHeight),
              child: CustomPaint(
                painter: _ColourPad(hsv),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 34,
          child: Row(
            children: [
              const Text('Hue'),
              Expanded(
                child: Slider(
                  min: 0,
                  max: 360,
                  value: hsv.hue,
                  onChanged: busy || !loaded
                      ? null
                      : (v) {
                          final next = hsv.withHue(v);
                          change(next.toColor(), selection: next);
                        },
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: TextField(
            key: const ValueKey('theme-hex'),
            controller: hex,
            enabled: !busy && loaded,
            decoration: const InputDecoration(
              labelText: 'HEX',
              isDense: true,
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              border: OutlineInputBorder(),
            ),
            onChanged: (v) {
              if (!RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(v)) {
                setState(() => inputError = 'Enter a six-digit HEX colour.');
                return;
              }
              final c = Color(
                0xFF000000 | int.parse(v.replaceAll('#', ''), radix: 16),
              );
              final text = hex.text;
              change(c);
              hex.text = text;
              hex.selection = TextSelection.collapsed(offset: text.length);
            },
          ),
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < 3; i++)
          SizedBox(
            height: 38,
            child: Row(
              children: [
                SizedBox(width: 16, child: Text(['R', 'G', 'B'][i])),
                Expanded(
                  child: Slider(
                    min: 0,
                    max: 255,
                    divisions: 255,
                    value: channels(draft)[i].toDouble(),
                    onChanged: busy || !loaded
                        ? null
                        : (v) {
                            final ch = channels(draft);
                            ch[i] = v.round();
                            change(Color.fromARGB(255, ch[0], ch[1], ch[2]));
                          },
                  ),
                ),
                SizedBox(
                  width: 54,
                  child: TextField(
                    key: ValueKey('theme-rgb-$i'),
                    controller: rgb[i],
                    enabled: !busy && loaded,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      final ch = rgb.map((c) => int.tryParse(c.text)).toList();
                      if (ch.any((v) => v == null || v < 0 || v > 255)) {
                        setState(
                          () => inputError =
                              'RGB must use whole numbers from 0 to 255.',
                        );
                        return;
                      }
                      final text = rgb[i].text;
                      change(Color.fromARGB(255, ch[0]!, ch[1]!, ch[2]!));
                      rgb[i].text = text;
                      rgb[i].selection = TextSelection.collapsed(
                        offset: text.length,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        if (inputError != null)
          Text(
            inputError!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 86,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: busy || !loaded
                    ? null
                    : () => change(saved, presetId: savedPreset),
                child: const Text('Reset', maxLines: 1),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('theme-save'),
                onPressed: busy || !loaded || inputError != null || !dirty
                    ? null
                    : save,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('Save Theme', maxLines: 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          dirty ? 'Unsaved selection' : 'Saved theme',
          key: const ValueKey('theme-save-status'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      // Scale the complete workspace as one canvas on smaller displays. No page
      // or panel scroll is needed, and Save/arrows are always inside the viewport.
      final width = bounds.maxWidth < 1100 ? 1100.0 : bounds.maxWidth;
      final availableHeight = bounds.hasBoundedHeight
          ? bounds.maxHeight
          : 650.0;
      final height = availableHeight < 650 ? 650.0 : availableHeight;
      return SizedBox(
        width: bounds.maxWidth,
        height: availableHeight,
        child: FittedBox(
          fit: BoxFit.contain,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            height: height,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Windows Theme',
                        style: TextStyle(
                          fontSize: 25,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (busy)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    IconButton(
                      tooltip: 'Reload saved theme',
                      onPressed: busy ? null : load,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const Text(
                  'Choose a preset or RGB colour, check the preview, then Save Theme.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 10),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      error!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                SizedBox(
                  height: 126,
                  child: Row(
                    children: [
                      for (final preset in windowsThemePresets)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: OutlinedButton(
                              key: ValueKey('theme-preset-${preset.id}'),
                              onPressed: busy || !loaded
                                  ? null
                                  : () => change(
                                      preset.seed,
                                      presetId: preset.id,
                                    ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.all(6),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                side: BorderSide(
                                  width: 2,
                                  color: draftPreset == preset.id
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).dividerColor,
                                ),
                              ),
                              child: Column(
                                children: [
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(5),
                                      child: preset.id == 'midnight-glass'
                                          ? const _MidnightGlassTile()
                                          : Image.asset(
                                              preset.image,
                                              fit: BoxFit.contain,
                                              semanticLabel: preset.name,
                                            ),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          preset.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                      if (draftPreset == preset.id)
                                        const Icon(Icons.check, size: 14),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      for (final entry in quickColours.entries)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(
                              entry.key,
                              style: const TextStyle(fontSize: 12),
                            ),
                            avatar: CircleAvatar(backgroundColor: entry.value),
                            onPressed: busy || !loaded
                                ? null
                                : () => change(entry.value, clearPreset: true),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 300, child: editor()),
                      const SizedBox(width: 12),
                      Expanded(child: preview()),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Each Windows PC applies the saved theme after its own App Lock password unlock (v2.1.187+).',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  void pick(Offset position, double width, double height) {
    final next = hsv
        .withSaturation((position.dx / width).clamp(0, 1))
        .withValue((1 - position.dy / height).clamp(0, 1));
    change(next.toColor(), selection: next);
  }
}

class _ColourPad extends CustomPainter {
  _ColourPad(this.hsv);
  final HSVColor hsv;
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()..color = HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.white, Colors.transparent],
        ).createShader(bounds),
    );
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(bounds),
    );
    final point = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    canvas.drawCircle(
      point,
      8,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4,
    );
    canvas.drawCircle(
      point,
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _ColourPad old) => old.hsv != hsv;
}


/// Midnight Glass preview must show the SAME verified Windows app screens
/// used by other presets. This is a screenshot with a subtle glass treatment,
/// not an invented dashboard with empty placeholder panels. Dedicated
/// Glass captures can replace the shared screenshot source later.
class _MidnightGlassPreview extends StatelessWidget {
  const _MidnightGlassPreview({
    super.key,
    required this.page,
    required this.tint,
    required this.screenshot,
  });
  final String page;
  final Color tint;
  final String screenshot;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      ColorFiltered(
        colorFilter: ColorFilter.mode(tint, BlendMode.hue),
        child: Image.asset(
          screenshot,
          key: const ValueKey('theme-preview-image'),
          fit: BoxFit.contain,
          semanticLabel: '$page — verified Windows screen with Midnight Glass tint',
        ),
      ),
      IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFFBEDFFF).withValues(alpha: .27),
              width: 1,
            ),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: .12),
                tint.withValues(alpha: .045),
                Colors.transparent,
                const Color(0xFF06090F).withValues(alpha: .055),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// Asset-free, live-painted frosted glass tile. No remote theme pictures,
/// network access or additional design assets are required.
class _MidnightGlassTile extends StatelessWidget {
  const _MidnightGlassTile();
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Midnight Glass theme: charcoal, translucent navy, azure and mint',
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF112849), Color(0xFF090C14), Color(0xFF211528)],
        ),
      ),
      child: Stack(children: [
        Positioned(top: -18, left: 12,
          child: Container(width: 85, height: 70,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: const Color(0xFF147BD1).withValues(alpha: .33)))),
        Positioned(bottom: -22, right: -16,
          child: Container(width: 95, height: 92,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: const Color(0xFF8C2CC2).withValues(alpha: .31)))),
        Center(child: Container(
          width: 102, height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: const Color(0xFF9BD4FF).withValues(alpha: .53)),
            gradient: LinearGradient(colors: [
              Colors.white.withValues(alpha: .20),
              const Color(0xFF4AB2FF).withValues(alpha: .07),
            ]),
          ),
          child: const Column(mainAxisAlignment: MainAxisAlignment.center,children: [
            Icon(Icons.blur_on_rounded,color: Color(0xFF97D7FF),size:18),
            SizedBox(height:2),
            Text('GLASS',style:TextStyle(color:Colors.white,fontSize:10,fontWeight:FontWeight.w800)),
          ]),
        )),
      ]),
    ),
  );
}
