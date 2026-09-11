import 'dart:convert';
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
  bool _isLoading = false;
  Uint8List? _selectedImageBytes;
  final ImagePicker _picker = ImagePicker();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String _provider = 'Gemini Pro';
  String? _customEndpoint;
  GenerativeModel? _geminiModel;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    String? p = await _storage.read(key: 'AI_PROVIDER');
    String? e = await _storage.read(key: 'CUSTOM_ENDPOINT');
    if (p != null) _provider = p;
    if (e != null) _customEndpoint = e;
    _initAI();
  }

  Future<void> _initAI() async {
    String? apiKey = await _storage.read(key: 'AI_API_KEY');
    if (apiKey != null && apiKey.isNotEmpty) {
      _geminiModel = GenerativeModel(model: 'gemini-1.5-flash', apiKey: apiKey);
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

  Future<void> _sendMessage() async {
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
      _controller.clear();
      _selectedImageBytes = null;
    });

   if (_provider == 'Open-Source (Custom Endpoint)' && imageBytes != null) {
      String endpoint = _customEndpoint ?? '';
      if (endpoint.endsWith('/')) {
        endpoint = endpoint.substring(0, endpoint.length - 1);
      }

      try {
        String base64Image = imageBytes != null ? base64Encode(imageBytes) : '';

        final response = await http.post(
          Uri.parse('$endpoint/animate_base64'),
          headers: {'Content-Type': 'application/json'},
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
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    // Gemini Default Logic
    try {
      List<Part> parts = [];
      if (text.isNotEmpty) parts.add(TextPart(text));
      if (imageBytes != null) parts.add(DataPart('image/jpeg', imageBytes));

      if (_geminiModel == null) {
        throw Exception("API Key set nahi hai! Settings (⚙️) mein jakar Gemini API Key ya Colab URL dalein.");
      }

      final response = await _geminiModel!.generateContent([Content.multi(parts)]);
      setState(() {
        _messages.add({
          'sender': 'saarthi',
          'text': response.text ?? 'Koi uttar nahi mila.',
        });
      });
    } catch (e) {
      setState(() {
        _messages.add({
          'sender': 'saarthi',
          'text': 'Error: ${e.toString()}',
        });
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _openSettings() {
    final keyController = TextEditingController();
    final urlController = TextEditingController(text: _customEndpoint ?? '');

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Settings ⚙️'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButton<String>(
                  isExpanded: true,
                  value: _provider,
                  items: const [
                    DropdownMenuItem(value: 'Gemini Pro', child: Text('Gemini Flash / Pro')),
                    DropdownMenuItem(value: 'Open-Source (Custom Endpoint)', child: Text('Colab / Local Server')),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() => _provider = val);
                      setState(() => _provider = val);
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (_provider == 'Open-Source (Custom Endpoint)') ...[
                  TextField(
                    controller: urlController,
                    decoration: const InputDecoration(
                      labelText: 'Colab Cloudflare URL',
                      hintText: 'https://xxxx.trycloudflare.com',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ] else ...[
                  TextField(
                    controller: keyController,
                    decoration: const InputDecoration(
                      labelText: 'Gemini API Key',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                await _storage.write(key: 'AI_PROVIDER', value: _provider);
                if (_provider == 'Open-Source (Custom Endpoint)') {
                  await _storage.write(key: 'CUSTOM_ENDPOINT', value: urlController.text.trim());
                  _customEndpoint = urlController.text.trim();
                } else {
                  await _storage.write(key: 'AI_API_KEY', value: keyController.text.trim());
                  await _initAI();
                }
                if (mounted) Navigator.pop(context);
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
            onPressed: _openSettings,
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(child: Text('Saarthi AI mein aapka swagat hai! Prompt likhein ya photo chunein.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final msg = _messages[i];
                      final isUser = msg['sender'] == 'user';
                      return Align(
                        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          padding: const EdgeInsets.all(12),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                          decoration: BoxDecoration(
                            color: isUser ? const Color(0xFF673AB7) : const Color(0xFF1F2C34),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (msg['image'] != null) ...[
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.memory(msg['image'], fit: BoxFit.cover),
                                ),
                                const SizedBox(height: 8),
                              ],
                              if (msg['text'] != null && msg['text'].toString().isNotEmpty)
                                Text(msg['text'], style: const TextStyle(color: Colors.white, fontSize: 14)),
                              if (msg['video_base64'] != null) ...[
                                const SizedBox(height: 10),
                                Container(
                                  height: 160,
                                  decoration: BoxDecoration(
                                    color: Colors.black26,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Center(
                                    child: Icon(Icons.check_circle_outline_rounded, color: Color(0xFF25D366), size: 48),
                                  ),
                                ),
                              ]
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TypingIndicator(),
              ),
            ),
          if (_selectedImageBytes != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.centerLeft,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(_selectedImageBytes!, height: 60, width: 60, fit: BoxFit.cover),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedImageBytes = null),
                      child: const CircleAvatar(radius: 10, backgroundColor: Colors.black, child: Icon(Icons.close, size: 12, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.image, color: Colors.purpleAccent),
                  onPressed: _pickImage,
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: const InputDecoration(
                      hintText: 'Prompt likhiye ya command dijiye...',
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.purpleAccent),
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

// Typing Indicator Widget
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key});
  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2C34),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (index) {
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              double value = ((_controller.value * 3) - index).clamp(0.0, 1.0);
              return Container(
                margin: const EdgeInsets.symmetric(horizontal: 2.5),
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withOpacity(0.3 + (0.7 * value)),
                ),
              );
            },
          );
        }),
      ),
    );
  }
}
