import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

void main() {
  runApp(const SaarthiApp());
}

class SaarthiApp extends StatelessWidget {
  const SaarthiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Saarthi AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: const Color(0xFF6200EE),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final ImagePicker _picker = ImagePicker();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  bool _isLoading = false;
  Uint8List? _selectedImageBytes;
  GenerativeModel? _geminiModel;

  final String _defaultApiKey = 'AQ.Ab8RN6IeHhhjllm56fiyJKcsL6y9glQaZ8TSEpEWxbWVsdA_eA';
  String _customEndpoint = '';
String _selectedModel = 'gemini-1.5-flash';
  
  @override
  void initState() {
    super.initState();
    _loadSettings();
    _initAI();
  }

  Future<void> _loadSettings() async {
    final ep = await _storage.read(key: 'CUSTOM_ENDPOINT');
    if (ep != null) {
      setState(() {
        _customEndpoint = ep;
      });
    }
  }

  Future<void> _initAI() async {
    final savedKey = await _storage.read(key: 'AI_API_KEY');
    final activeKey = (savedKey != null && savedKey.isNotEmpty) ? savedKey : _defaultApiKey;

    _geminiModel = GenerativeModel(
      model: _selectedModel,
      apiKey: activeKey,
    );
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

    // 1. Photo attach hai -> Colab Video Engine chalega
    if (imageBytes != null) {
      try {
        String endpoint = _customEndpoint.trim();
        if (endpoint.endsWith('/')) {
          endpoint = endpoint.substring(0, endpoint.length - 1);
        }

        if (endpoint.isEmpty) {
          throw Exception('Settings me Colab Cloudflare URL set nahi hai.');
        }

        final base64Image = base64Encode(imageBytes);

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
              'text': '🎬 Video safalta-purvak ban gayi!',
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
            'text': 'Connection Error: $e',
          });
        });
      } finally {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    // 2. Sirf Text hai -> Direct Gemini AI Chat
    try {
      if (_geminiModel == null) {
        await _initAI();
      }

      final response = await _geminiModel!.generateContent([Content.text(text)]);
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
          'text': 'Gemini Error: $e',
        });
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _openSettings() {
    final epController = TextEditingController(text: _customEndpoint);
    final keyController = TextEditingController();

    // Pehle se saved key read karein
    _storage.read(key: 'AI_API_KEY').then((val) {
      if (val != null) keyController.text = val;
    });

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Settings'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: keyController,
                decoration: const InputDecoration(
                  labelText: 'Gemini API Key',
                  hintText: 'AIzaSy...',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: epController,
                decoration: const InputDecoration(
                  labelText: 'Colab Cloudflare URL',
                  hintText: 'https://xxxx.trycloudflare.com',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final newKey = keyController.text.trim();
              final newEndpoint = epController.text.trim();

              await _storage.write(key: 'AI_API_KEY', value: newKey);
              await _storage.write(key: 'CUSTOM_ENDPOINT', value: newEndpoint);

              setState(() {
                _customEndpoint = newEndpoint;
              });

              await _initAI();
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saarthi AI 🇮🇳'),
        actions: [
          DropdownButton<String>(
            value: _selectedModel,
            dropdownColor: const Color(0xFF222222),
            underline: const SizedBox(),
            icon: const Icon(Icons.psychology, color: Colors.purpleAccent),
            items: const [
              DropdownMenuItem(
                value: 'gemini-1.5-flash',
                child: Text('⚡ Fast', style: TextStyle(fontSize: 13)),
              ),
              DropdownMenuItem(
                value: 'gemini-2.0-flash',
                child: Text('⚖️ Medium', style: TextStyle(fontSize: 13)),
              ),
              DropdownMenuItem(
                value: 'gemini-2.0-flash-thinking-exp',
                child: Text('🧠 Deep', style: TextStyle(fontSize: 13)),
              ),
            ],
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _selectedModel = val;
                });
                _initAI();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (ctx, i) {
                final m = _messages[i];
                final isUser = m['sender'] == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 6),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isUser ? const Color(0xFF6200EE) : const Color(0xFF2C2C2C),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (m['image'] != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Image.memory(m['image'], height: 200, fit: BoxFit.cover),
                          ),
                        if (m['text'] != null && m['text'].toString().isNotEmpty)
                          Text(m['text'], style: const TextStyle(color: Colors.white, fontSize: 15)),
                        if (m['video_base64'] != null)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('🎥 Video ready on server.', style: TextStyle(color: Colors.greenAccent)),
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
                  Image.memory(_selectedImageBytes!, width: 50, height: 50, fit: BoxFit.cover),
                  const SizedBox(width: 10),
                  const Text('Photo attached'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() => _selectedImageBytes = null),
                  ),
                ],
              ),
            ),
          if (_isLoading) const LinearProgressIndicator(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: const Color(0xFF1E1E1E),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.image, color: Colors.purpleAccent),
                  onPressed: _pickImage,
                ),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Prompt likhiye ya command dijiye...',
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
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
