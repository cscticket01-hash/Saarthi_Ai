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
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B141A), // WhatsApp Chat Background
        appBarTheme: const AppBarTheme(
          backgroundColor: const Color(0xFF1F2C34), // WhatsApp Header
          elevation: 1,
        ),
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
  // Hardcoded API Key (Settings popup se Key input hata diya gaya hai)
  static const String _fixedApiKey = String.fromEnvironment('GEMINI_API_KEY');
  
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final ImagePicker _picker = ImagePicker();
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  bool _isLoading = false;
  Uint8List? _selectedImageBytes;
  String _customEndpoint = '';

  @override
  void initState() {
    super.initState();
    _loadEndpoint();
  }

  Future<void> _loadEndpoint() async {
    final ep = await _storage.read(key: 'CUSTOM_ENDPOINT');
    if (ep != null) {
      setState(() {
        _customEndpoint = ep;
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

    // 1. Photo attach hone par Colab Video Trigger
    if (imageBytes != null) {
      try {
        String endpoint = _customEndpoint.trim();
        if (endpoint.endsWith('/')) {
          endpoint = endpoint.substring(0, endpoint.length - 1);
        }

        if (endpoint.isEmpty) {
          throw Exception('Settings me Colab Cloudflare URL set karein.');
        }

        final base64Image = base64Encode(imageBytes);

        final response = await http.post(
          Uri.parse('$endpoint/animate_base64'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_base64': base64Image,
            'prompt': text.isNotEmpty ? text : 'animate motion',
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

   // 2. Direct Gemini REST API Call
    try {
      final response = await http.post(
        Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_fixedApiKey',
        },
        body: jsonEncode({
          'model': 'llama-3.1-8b-instant',
          'messages': [
            {
              'role': 'system',
              'content': 'Aapka naam Saarthi AI hai. Hamesha Saarthi AI ban kar madad karein.'
            },
            {
              'role': 'user',
              'content': text
            }
          ]
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final reply = data['choices'][0]['message']['content'];
        setState(() {
          _messages.add({
            'sender': 'saarthi',
            'text': reply,
          });
        });
      } else {
        setState(() {
          _messages.add({
            'sender': 'saarthi',
            'text': 'Error: ${response.statusCode} - ${response.body}',
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
  } 

  void _openSettings() {
    final epController = TextEditingController(text: _customEndpoint);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Server Settings', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: epController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            labelText: 'Colab Cloudflare URL',
            labelStyle: TextStyle(color: Color(0xFF00A884)),
            hintText: 'https://xxxx.trycloudflare.com',
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF00A884)),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
            onPressed: () async {
              final newEndpoint = epController.text.trim();
              await _storage.write(key: 'CUSTOM_ENDPOINT', value: newEndpoint);
              setState(() {
                _customEndpoint = newEndpoint;
              });
              Navigator.pop(ctx);
            },
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const CircleAvatar(
              backgroundColor: Color(0xFF00A884),
              child: Icon(Icons.psychology, color: Colors.white),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text('Saarthi AI 🇮🇳', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                Text('online', style: TextStyle(fontSize: 12, color: Color(0xFF00A884))),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.grey),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (ctx, i) {
                final m = _messages[i];
                final isUser = m['sender'] == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isUser ? const Color(0xFF005C4B) : const Color(0xFF1F2C34), // WhatsApp Bubble Colors
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(10),
                        topRight: const Radius.circular(10),
                        bottomLeft: Radius.circular(isUser ? 10 : 0),
                        bottomRight: Radius.circular(isUser ? 0 : 10),
                      ),
                    ),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (m['image'] != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.memory(m['image'], height: 200, fit: BoxFit.cover),
                            ),
                          ),
                        if (m['text'] != null && m['text'].toString().isNotEmpty)
                          Text(
                            m['text'],
                            style: const TextStyle(color: Colors.white, fontSize: 15),
                          ),
                        if (m['video_base64'] != null)
                          const Padding(
                            padding: EdgeInsets.only(top: 6),
                            child: Text('🎬 Video ready!', style: TextStyle(color: Color(0xFF25D366), fontWeight: FontWeight.bold)),
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
              color: const Color(0xFF1F2C34),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(_selectedImageBytes!, width: 45, height: 45, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 10),
                  const Text('Photo attached', style: TextStyle(color: Colors.white70)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.grey),
                    onPressed: () => setState(() => _selectedImageBytes = null),
                  ),
                ],
              ),
            ),
          if (_isLoading)
            const LinearProgressIndicator(
              backgroundColor: Color(0xFF1F2C34),
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00A884)),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            color: const Color(0xFF1F2C34),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file, color: Colors.grey),
                  onPressed: _pickImage,
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A3942),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        hintStyle: TextStyle(color: Colors.grey),
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                CircleAvatar(
                  backgroundColor: const Color(0xFF00A884),
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white, size: 20),
                    onPressed: _sendMessage,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
