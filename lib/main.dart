import 'package:flutter/material.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() => runApp(const SaarthiApp());

class SaarthiApp extends StatelessWidget {
  const SaarthiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Saarthi AI',
      themeMode: ThemeMode.system,
      theme: ThemeData.light(useMaterial3: true),
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
  final List<Map<String, String>> _messages = [];
  final _storage = const FlutterSecureStorage();
  GenerativeModel? _model;

  @override
  void initState() {
    super.initState();
    _initAI();
  }

  Future<void> _initAI() async {
    // API key device me safely store hogi
    String? apiKey = await _storage.read(key: 'GEMINI_API_KEY');
    if (apiKey != null) {
      _model = GenerativeModel(
        model: 'gemini-1.5-flash',
        apiKey: apiKey,
        systemInstruction: Content.system(
          'Aap Saarthi AI hain. Hindi, Hinglish aur English me natural tarike se baat karte hain.',
        ),
      );
    }
  }

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _model == null) return;

    setState(() {
      _messages.add({'sender': 'user', 'text': text});
    });
    _controller.clear();

    try {
      final response = await _model!.generateContent([Content.text(text)]);
      setState(() {
        _messages.add({'sender': 'saarthi', 'text': response.text ?? 'No reply'});
      });
    } catch (e) {
      setState(() {
        _messages.add({'sender': 'saarthi', 'text': 'Error: $e'});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saarthi AI 🇮🇳')),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                final msg = _messages[i];
                final isUser = msg['sender'] == 'user';
                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.deepPurple : Colors.grey.shade800,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(msg['text'] ?? ''),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Puchiye Saarthi se...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send), onPressed: _sendMessage),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
