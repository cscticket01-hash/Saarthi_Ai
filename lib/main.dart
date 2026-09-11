import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const SaarthiApp());

class SaarthiApp extends StatelessWidget {
  const SaarthiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Saarthi AI',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData.dark(useMaterial3: true),
      home: const SaarthiChatScreen(),
    );
  }
}

class SaarthiChatScreen extends StatefulWidget {
  const SaarthiChatScreen({super.key});

  @override
  State<SaarthiChatScreen> createState() => _SaarthiChatScreenState();
}

class _SaarthiChatScreenState extends State<SaarthiChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final _storage = const FlutterSecureStorage();
  final ImagePicker _picker = ImagePicker();

  GenerativeModel? _model;
  bool _isLoading = false;
  Uint8List? _selectedImageBytes;
  String _provider = 'Gemini (Cloud)'; // Default provider

  @override
  void initState() {
    super.initState();
    _initAI();
  }

  Future<void> _initAI() async {
    String? apiKey = await _storage.read(key: 'AI_API_KEY');
    String? savedProvider = await _storage.read(key: 'AI_PROVIDER');
    if (savedProvider != null) _provider = savedProvider;

    if (apiKey != null && apiKey.trim().isNotEmpty) {
      setState(() {
        if (_provider == 'Gemini (Cloud)') {
          _model = GenerativeModel(
            model: 'gemini-3.6-flash',
            apiKey: apiKey.trim(),
          );
        }
      });
    }
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      final bytes = await image.readAsBytes();
      setState(() {
        _selectedImageBytes = bytes;
      });
    }
  }

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty && _selectedImageBytes == null) return;

    final imageBytes = _selectedImageBytes;
    setState(() {
      _messages.add({
        'sender': 'user',
        'text': text,
        'image': imageBytes,
      });
      _isLoading = true;
      _selectedImageBytes = null;
    });
    _controller.clear();

    String? apiKey = await _storage.read(key: 'AI_API_KEY');
    if (apiKey == null || apiKey.isEmpty) {
      setState(() {
        _isLoading = false;
        _messages.add({
          'sender': 'saarthi',
          'text': '⚠️ Pehle Settings icon (⚙️) me jakar API Key save karein!'
        });
      });
      _showSettingsDialog();
      return;
    }

    if (_provider == 'Open-Source (Custom Endpoint)') {
      String? endpoint = await _storage.read(key: 'CUSTOM_ENDPOINT');
      if (endpoint == null || endpoint.isEmpty) {
        setState(() {
          _isLoading = false;
          _messages.add({
            'sender': 'saarthi',
            'text': '⚠️ Settings me Server URL daalna bhool gaye!'
          });
        });
        return;
      }

     try {
        // Photo ko simple Base64 text me convert karna
        String base64Image = base64Encode(imageBytes!);

        final response = await http.post(
          Uri.parse('$endpoint/animate_base64'),
          headers: {
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'image_base64': base64Image,
            'prompt': text.isNotEmpty ? text : 'dance',
          }),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          setState(() {
            _messages.add({
              'sender': 'saarthi',
              'text': '🎬 Video safalta-purvak ban gayi hai!',
              'video_base64': data['video_base64'],
            });
          });
        } else {
          setState(() {
            _messages.add({
              'sender': 'saarthi',
              'text': 'Server Error: ${response.statusCode} - ${response.body}',
            });
          });
        }
      } catch (e) {
        setState(() {
          _messages.add({
            'sender': 'saarthi',
            'text': 'Connection Error: ${e.toString()}',
          });
        });
      }
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    // Default Gemini AI Logic
    try {
      List<Part> parts = [];
      if (imageBytes != null) {
        parts.add(DataPart('image/jpeg', imageBytes));
      }
      if (text.isNotEmpty) {
        parts.add(TextPart(text));
      }

      final response = await _model!.generateContent([Content.multi(parts)]);
      setState(() {
        _messages.add({
          'sender': 'saarthi',
          'text': response.text ?? 'Response generate nahi hua.'
        });
      });
    } catch (e) {
      setState(() {
        _messages.add({
          'sender': 'saarthi',
          'text': 'Error: ${e.toString()}'
        });
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _showSettingsDialog() {
    final keyController = TextEditingController();
    final urlController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('AI Server Settings'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('AI Provider Select Karein:', style: TextStyle(fontWeight: FontWeight.bold)),
                DropdownButton<String>(
                  value: _provider,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(value: 'Gemini (Cloud)', child: Text('Google Gemini (Text/Vision)')),
                    DropdownMenuItem(value: 'Open-Source (Custom Endpoint)', child: Text('Open-Source Video (Colab/Self-host)')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => _provider = val);
                      setState(() => _provider = val);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: keyController,
                  decoration: const InputDecoration(
                    labelText: 'API Key',
                    hintText: 'Paste Gemini ya Open-Source Key',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (_provider == 'Open-Source (Custom Endpoint)') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: urlController,
                    decoration: const InputDecoration(
                      labelText: 'Server URL (Colab / Localhost)',
                      hintText: 'https://xyz.ngrok-free.app',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final key = keyController.text.trim();
                if (key.isNotEmpty) {
                  await _storage.write(key: 'AI_API_KEY', value: key);
                  await _storage.write(key: 'AI_PROVIDER', value: _provider);
                  if (urlController.text.isNotEmpty) {
                    await _storage.write(key: 'CUSTOM_ENDPOINT', value: urlController.text.trim());
                  }
                  await _initAI();
                  if (mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Settings Save Ho Gayi!')),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saarthi AI 🇮🇳'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'AI Settings',
            onPressed: _showSettingsDialog,
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Saarthi AI me aapka swagat hai!\nPhoto chunein ya prompt likhein.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                  )
                : ListView.builder(
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final msg = _messages[i];
                      final isUser = msg['sender'] == 'user';
                      return Align(
                        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
                          padding: const EdgeInsets.all(12),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.75,
                          ),
                          decoration: BoxDecoration(
                            color: isUser ? Colors.deepPurple : Colors.grey.shade800,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (msg['image'] != null)
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(
                                    msg['image'],
                                    height: 150,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              if (msg['image'] != null && (msg['text'] as String).isNotEmpty)
                                const SizedBox(height: 8),
                              if ((msg['text'] as String).isNotEmpty)
                                Text(
                                  msg['text'] ?? '',
                                  style: const TextStyle(color: Colors.white, fontSize: 15),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_selectedImageBytes != null)
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.black26,
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(_selectedImageBytes!, height: 60, width: 60, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 8),
                  const Text('Photo Selected'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.red),
                    onPressed: () => setState(() => _selectedImageBytes = null),
                  ),
                ],
              ),
            ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.photo_library),
                  color: Colors.deepPurpleAccent,
                  onPressed: _pickImage,
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Prompt likhiye ya command dijiye...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  color: Colors.deepPurpleAccent,
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
