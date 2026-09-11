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
  final List<Map<String, String>> _messages = [];
  final _storage = const FlutterSecureStorage();
  GenerativeModel? _model;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initAI();
  }

  Future<void> _initAI() async {
    String? apiKey = await _storage.read(key: 'GEMINI_API_KEY');
    if (apiKey != null && apiKey.trim().isNotEmpty) {
      setState(() {
        _model = GenerativeModel(
          model:'gemini-3.6-flash',
          apiKey: apiKey.trim(),
        );
      });
    }
  }

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add({'sender': 'user', 'text': text});
      _isLoading = true;
    });
    _controller.clear();

    if (_model == null) {
      setState(() {
        _isLoading = false;
        _messages.add({
          'sender': 'saarthi',
          'text': '⚠️ Pehle upar Bane Chabhi (Key) Icon Par Click Karke Gemini API Key Save Karein!'
        });
      });
      _showApiKeyDialog();
      return;
    }

    try {
      final response = await _model!.generateContent([Content.text(text)]);
      setState(() {
        _messages.add({
          'sender': 'saarthi',
          'text': response.text ?? 'Koi response nahi mila.'
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

  void _showApiKeyDialog() {
    final keyController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gemini API Key Set Karein'),
        content: TextField(
          controller: keyController,
          decoration: const InputDecoration(
            hintText: 'Paste Gemini API Key',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final key = keyController.text.trim();
              if (key.isNotEmpty) {
                await _storage.write(key: 'GEMINI_API_KEY', value: key);
                await _initAI();
                if (mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('API Key Save Ho Gayi!')),
                  );
                }
              }
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
          IconButton(
            icon: const Icon(Icons.vpn_key),
            tooltip: 'Enter API Key',
            onPressed: _showApiKeyDialog,
          )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const Center(
                    child: Text(
                      'Saarthi AI me aapka swagat hai!\nKuch bhi type karke send karein.',
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
                          child: Text(
                            msg['text'] ?? '',
                            style: const TextStyle(color: Colors.white, fontSize: 15),
                          ),
                        ),
                      );
                    },
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
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Puchiye Saarthi se...',
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
