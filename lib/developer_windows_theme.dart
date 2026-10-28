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

  void change(Color c, {HSVColor? selection, String? presetId}) {
    setState(() {
      draftPreset = presetId;
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

  Widget panel(Widget child) => Card(
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
  Widget preview() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Windows App Screenshots',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      const Text('App screens • sample data'),
      const SizedBox(height: 12),
      for (final entry in const {
        'dashboard': 'Dashboard',
        'students': 'Student Records',
        'fees': 'Fees Collection',
        'settings': 'Settings',
      }.entries) ...[
        Text(entry.value, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => showDialog<void>(
            context: context,
            builder: (c) => Dialog(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: 'Close screenshot',
                      onPressed: () => Navigator.pop(c),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  Flexible(
                    child: InteractiveViewer(
                      child: Image.asset(
                        'assets/app_screenshot_${entry.key}.png',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.asset(
              'assets/app_screenshot_${entry.key}.png',
              semanticLabel: '${entry.value} app screenshot',
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    ],
  );
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Windows App Theme',
        style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
      const Text(
        'Select an image preset to activate it for the next App Lock unlock, or save a custom RGB colour.',
      ),
      const SizedBox(height: 20),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const Text(
        'Preset Themes',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: windowsThemePresets
            .map(
              (preset) => SizedBox(
                width: 250,
                child: OutlinedButton(
                  onPressed: busy || !loaded
                      ? null
                      : () async {
                          change(preset.seed, presetId: preset.id);
                          await save();
                        },
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.all(8),
                    side: BorderSide(
                      color: draftPreset == preset.id
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).dividerColor,
                      width: 2,
                    ),
                  ),
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset(
                          preset.image,
                          semanticLabel: preset.name,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: Text(preset.name)),
                          if (savedPreset == preset.id)
                            const Icon(Icons.check_circle, size: 18),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            )
            .toList(),
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: quickColours.entries
            .map(
              (entry) => ActionChip(
                label: Text(entry.key),
                avatar: CircleAvatar(backgroundColor: entry.value),
                onPressed: busy || !loaded ? null : () => change(entry.value),
              ),
            )
            .toList(),
      ),
      const SizedBox(height: 16),
      LayoutBuilder(
        builder: (context, size) {
          final editor = panel(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Custom colour',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                AspectRatio(
                  aspectRatio: 1.35,
                  child: LayoutBuilder(
                    builder: (c, s) => GestureDetector(
                      onPanUpdate: busy || !loaded
                          ? null
                          : (d) =>
                                pick(d.localPosition, s.maxWidth, s.maxHeight),
                      onTapDown: busy || !loaded
                          ? null
                          : (d) =>
                                pick(d.localPosition, s.maxWidth, s.maxHeight),
                      child: CustomPaint(
                        painter: _ColourPad(hsv),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
                Row(
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
                TextField(
                  key: const ValueKey('theme-hex'),
                  controller: hex,
                  enabled: !busy && loaded,
                  decoration: const InputDecoration(
                    labelText: 'HEX',
                    prefixIcon: Icon(Icons.palette_outlined),
                  ),
                  onChanged: (v) {
                    if (!RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(v)) {
                      setState(
                        () => inputError = 'Enter a six-digit HEX colour.',
                      );
                      return;
                    }
                    final c = Color(
                      0xFF000000 | int.parse(v.replaceAll('#', ''), radix: 16),
                    );
                    final text = hex.text;
                    change(c);
                    hex.text = text;
                    hex.selection = TextSelection.collapsed(
                      offset: text.length,
                    );
                  },
                ),
                const SizedBox(height: 12),
                for (var i = 0; i < 3; i++)
                  Row(
                    children: [
                      SizedBox(width: 20, child: Text(['R', 'G', 'B'][i])),
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
                                  change(
                                    Color.fromARGB(255, ch[0], ch[1], ch[2]),
                                  );
                                },
                        ),
                      ),
                      SizedBox(
                        width: 70,
                        child: TextField(
                          key: ValueKey('theme-rgb-$i'),
                          controller: rgb[i],
                          enabled: !busy && loaded,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (_) {
                            final ch = rgb
                                .map((c) => int.tryParse(c.text))
                                .toList();
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
                if (inputError != null)
                  Text(
                    inputError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton(
                      onPressed: busy || !loaded
                          ? null
                          : () => change(saved, presetId: savedPreset),
                      child: const Text('Reset draft'),
                    ),
                    FilledButton.icon(
                      onPressed: busy || !loaded || inputError != null || !dirty
                          ? null
                          : save,
                      icon: const Icon(Icons.save),
                      label: const Text('Save Windows Theme'),
                    ),
                    TextButton(
                      onPressed: busy ? null : load,
                      child: const Text('Reload saved theme'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  dirty
                      ? 'Unsaved colour • schools still use the saved theme'
                      : 'Saved theme • no unpublished changes',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Windows applies the saved theme only after App Lock password unlock. All registered school PCs must reach App Lock first. Dark / Light remains available in the app.',
                ),
              ],
            ),
          );
          final screen = panel(preview());
          if (size.maxWidth < 1100) return Column(children: [editor, screen]);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 370, child: editor),
              const SizedBox(width: 12),
              Expanded(child: screen),
            ],
          );
        },
      ),
    ],
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
