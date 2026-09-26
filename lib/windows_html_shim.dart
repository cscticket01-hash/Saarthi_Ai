import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

// A very small Windows compatibility layer for the browser APIs used by
// main_dashboard_screen.dart. It intentionally implements only the members
// that Vidya Saarthi currently uses.

final Document document = Document();
final Window window = Window();

class MouseEvent {}
class Event {}

class Style {
  String display = '';
  String backgroundColor = '';
}

class _Children {
  final List<Object> _items = <Object>[];

  void add(Object value) {
    _items.add(value);
  }
}

class Element {
  final Style style = Style();

  void remove() {}
}

class HtmlElement extends Element {
  final _Children children = _Children();
}

class Document {
  final HtmlElement? documentElement = HtmlElement();
  final HtmlElement? body = HtmlElement();
  final StreamController<MouseEvent> _clickController =
      StreamController<MouseEvent>.broadcast();

  Stream<MouseEvent> get onClick => _clickController.stream;

  void dispatchClick() {
    if (!_clickController.isClosed) {
      _clickController.add(MouseEvent());
    }
  }
}

class Navigator {
  String get userAgent => 'windows vidya-saarthi-desktop';
}

class _PersistentStorage extends MapBase<String, String> {
  _PersistentStorage() {
    _load();
  }

  final Map<String, String> _values = <String, String>{};

  io.File get _file {
    final appData = io.Platform.environment['APPDATA'] ??
        io.Platform.environment['LOCALAPPDATA'] ??
        io.Directory.systemTemp.path;
    final dir = io.Directory('$appData${io.Platform.pathSeparator}VidyaSaarthi');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return io.File(
      '${dir.path}${io.Platform.pathSeparator}portal_session.json',
    );
  }

  void _load() {
    try {
      final f = _file;
      if (!f.existsSync()) return;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          _values[entry.key.toString()] = entry.value?.toString() ?? '';
        }
      }
    } catch (_) {}
  }

  void _save() {
    try {
      _file.writeAsStringSync(jsonEncode(_values), flush: true);
    } catch (_) {}
  }

  @override
  String? operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, String value) {
    _values[key] = value;
    _save();
  }

  @override
  void clear() {
    _values.clear();
    _save();
  }

  @override
  Iterable<String> get keys => _values.keys;

  @override
  String? remove(Object? key) {
    final old = _values.remove(key);
    _save();
    return old;
  }
}

class Window {
  final _PersistentStorage localStorage = _PersistentStorage();
  final Navigator navigator = Navigator();

  void open(String url, String target) {
    final value = url.trim();
    if (value.isEmpty) return;

    unawaited(
      (() async {
        try {
          await io.Process.start(
            'cmd.exe',
            <String>['/c', 'start', '', value],
            runInShell: true,
            mode: io.ProcessStartMode.detached,
          );
        } catch (_) {}
      })(),
    );
  }
}

class Notification {
  Notification(
    String title, {
    String? body,
    String? tag,
  });

  static bool get supported => false;
  static String? get permission => 'denied';

  static Future<String> requestPermission() async => 'denied';

  final StreamController<MouseEvent> _clickController =
      StreamController<MouseEvent>.broadcast();

  Stream<MouseEvent> get onClick => _clickController.stream;

  void close() {
    if (!_clickController.isClosed) {
      _clickController.close();
    }
  }
}

class Blob {
  Blob(List<dynamic> parts, [this.type = 'application/octet-stream']) {
    final builder = BytesBuilder(copy: false);
    for (final part in parts) {
      if (part is Uint8List) {
        builder.add(part);
      } else if (part is List<int>) {
        builder.add(part);
      } else if (part is String) {
        builder.add(utf8.encode(part));
      }
    }
    bytes = builder.takeBytes();
  }

  final String type;
  late final Uint8List bytes;
}

class Url {
  static final Map<String, Blob> _blobs = <String, Blob>{};
  static int _counter = 0;

  static String createObjectUrlFromBlob(Blob blob) {
    final id = 'vidya-blob://${++_counter}';
    _blobs[id] = blob;
    return id;
  }

  static Blob? blobFor(String url) => _blobs[url];

  static void revokeObjectUrl(String url) {
    _blobs.remove(url);
  }
}

class AnchorElement extends Element {
  AnchorElement({this.href});

  String? href;
  final Map<String, String> _attributes = <String, String>{};

  void setAttribute(String name, String value) {
    _attributes[name] = value;
  }

  void click() {
    final source = href ?? '';
    final blob = Url.blobFor(source);
    if (blob == null) {
      if (source.startsWith('http://') || source.startsWith('https://')) {
        window.open(source, '_blank');
      }
      return;
    }

    final rawName = _attributes['download'] ?? 'download.bin';
    final safeName = rawName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

    try {
      final userProfile = io.Platform.environment['USERPROFILE'];
      final downloads = userProfile == null || userProfile.trim().isEmpty
          ? io.Directory.current
          : io.Directory(
              '$userProfile${io.Platform.pathSeparator}Downloads',
            );

      if (!downloads.existsSync()) {
        downloads.createSync(recursive: true);
      }

      io.File(
        '${downloads.path}${io.Platform.pathSeparator}$safeName',
      ).writeAsBytesSync(blob.bytes, flush: true);
    } catch (_) {}
  }
}

class File {
  File({
    required this.name,
    required this.type,
    required this.bytes,
  });

  final String name;
  final String type;
  final Uint8List bytes;

  int get size => bytes.length;
}

class FileUploadInputElement extends Element {
  String accept = '';
  List<File>? files;

  final StreamController<Event> _changeController =
      StreamController<Event>.broadcast();

  Stream<Event> get onChange => _changeController.stream;

  void click() {
    unawaited(_pickFile());
  }

  Future<void> _pickFile() async {
    try {
      const script = r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'Select Student Document'
$dialog.Filter = 'PDF or Image (*.pdf;*.jpg;*.jpeg)|*.pdf;*.jpg;*.jpeg|All files (*.*)|*.*'
$dialog.Multiselect = $false
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  Write-Output $dialog.FileName
}
''';

      final result = await io.Process.run(
        'powershell.exe',
        <String>[
          '-NoProfile',
          '-STA',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
        runInShell: true,
      );

      final path = result.stdout.toString().trim();
      if (result.exitCode == 0 && path.isNotEmpty) {
        final nativeFile = io.File(path);
        if (await nativeFile.exists()) {
          final bytes = await nativeFile.readAsBytes();
          final lower = path.toLowerCase();
          var mime = 'application/octet-stream';
          if (lower.endsWith('.pdf')) {
            mime = 'application/pdf';
          } else if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
            mime = 'image/jpeg';
          }

          files = <File>[
            File(
              name: path.split(RegExp(r'[\\/]')).last,
              type: mime,
              bytes: bytes,
            ),
          ];
        }
      }
    } catch (_) {
      files = <File>[];
    } finally {
      if (!_changeController.isClosed) {
        _changeController.add(Event());
      }
    }
  }
}

class FileReader {
  dynamic result;

  final StreamController<Event> _loadController =
      StreamController<Event>.broadcast();

  Stream<Event> get onLoad => _loadController.stream;

  void readAsDataUrl(File file) {
    unawaited(
      Future<void>(() {
        result = 'data:${file.type};base64,${base64Encode(file.bytes)}';
        if (!_loadController.isClosed) {
          _loadController.add(Event());
        }
      }),
    );
  }
}
