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
  // Preloaded presets only: custom HSV, HEX and RGB editors are not exposed.
  Widget editor() => panel(Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    const Text('Selected preset',style:TextStyle(fontSize:18,fontWeight:FontWeight.w700)),
    const SizedBox(height:12),
    Text(windowsThemePreset(draftPreset)?.name??'Choose a preset above',maxLines:2,style:const TextStyle(fontSize:15)),
    const SizedBox(height:12),
    OutlinedButton(onPressed:busy||!loaded?null:()=>change(saved,presetId:savedPreset,clearPreset:savedPreset==null),child:const Text('Reset')),
    const SizedBox(height:8),
    FilledButton.icon(key:const ValueKey('theme-save'),onPressed:busy||!loaded||!dirty||draftPreset==null?null:save,
      icon:const Icon(Icons.save_outlined,size:17),label:const Text('Save Theme')),
    const SizedBox(height:8),
    Text(dirty?'Unsaved preset':'Saved preset',key:const ValueKey('theme-save-status'),style:const TextStyle(fontSize:11)),
  ]));
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
                  'Choose one preset, review the preview, then Save Theme.',
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


/// Liquid Glass preview keeps the SAME verified Windows app screens
/// used by other presets. A translucent treatment overlays each screenshot,
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
          semanticLabel: '$page — verified Windows screen with Liquid Glass tint',
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
                Colors.white.withValues(alpha: .19),
                tint.withValues(alpha: .055),
                const Color(0xFFB1C7FF).withValues(alpha: .025),
                const Color(0xFF06121F).withValues(alpha: .12),
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
    label: 'Liquid Glass theme: frosted navy, luminous blue and soft violet',
    child: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E4664), Color(0xFF081725), Color(0xFF342A53)],
        ),
      ),
      child: Stack(children: [
        Positioned(top: -18, left: 12,
          child: Container(width: 85, height: 70,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: const Color(0xFF58ADEA).withValues(alpha: .43)))),
        Positioned(bottom: -22, right: -16,
          child: Container(width: 95, height: 92,
            decoration: BoxDecoration(shape: BoxShape.circle,
              color: const Color(0xFFA28BEA).withValues(alpha: .40)))),
        Center(child: Container(
          width: 102, height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: const Color(0xFF9BD4FF).withValues(alpha: .53)),
            gradient: LinearGradient(colors: [
              Colors.white.withValues(alpha: .20),
              const Color(0xFF9BC8FF).withValues(alpha: .10),
            ]),
          ),
          child: const Column(mainAxisAlignment: MainAxisAlignment.center,children: [
            Icon(Icons.blur_on_rounded,color: Color(0xFFC9F1FF),size:18),
            SizedBox(height:2),
            Text('LIQUID GLASS',style:TextStyle(color:Colors.white,fontSize:9,fontWeight:FontWeight.w800)),
          ]),
        )),
      ]),
    ),
  );
}
