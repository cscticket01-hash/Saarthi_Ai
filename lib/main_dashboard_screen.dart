import 'package:flutter/material.dart';

class MainDashboardScreen extends StatefulWidget {
  const MainDashboardScreen({super.key});

  @override
  State<MainDashboardScreen> createState() => _MainDashboardScreenState();
}

class _MainDashboardScreenState extends State<MainDashboardScreen> {
  int _selectedTabIndex = 0;

  final List<Widget> _pages = [
    const AiChatScreen(),
    const PhonebookScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_selectedTabIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTabIndex,
        onTap: (index) => setState(() => _selectedTabIndex = index),
        backgroundColor: const Color(0xFF1F2C34),
        selectedItemColor: const Color(0xFF00A884),
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            activeIcon: Icon(Icons.chat),
            label: 'AI Chat',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.contacts_outlined),
            activeIcon: Icon(Icons.contacts),
            label: 'Phonebook',
          ),
        ],
      ),
    );
  }
}

// ----------------- AI CHAT SCREEN (WITH MENU & HISTORY) -----------------
class ChatSession {
  String id;
  String title;
  List<Map<String, String>> messages;

  ChatSession({required this.id, required this.title, required this.messages});
}

class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  String _preferredLanguage = 'en';

  List<ChatSession> chatSessions = [
    ChatSession(
      id: '1',
      title: 'First Conversation',
      messages: [
        {'sender': 'ai', 'text': 'Hello! How can I assist you today?'},
      ],
    ),
  ];

  int currentSessionIndex = 0;

  void _startNewChat() {
    setState(() {
      final newChat = ChatSession(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: 'New Chat ${chatSessions.length + 1}',
        messages: [
          {'sender': 'ai', 'text': 'Hello! New conversation started. How can I help?'},
        ],
      );
      chatSessions.insert(0, newChat);
      currentSessionIndex = 0;
    });
    Navigator.pop(context); // Menu band karein
  }

  void _deleteChat(int index) {
    setState(() {
      chatSessions.removeAt(index);
      if (chatSessions.isEmpty) {
        _startNewChat();
      } else if (currentSessionIndex >= chatSessions.length) {
        currentSessionIndex = 0;
      }
    });
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isLoading) return;

    setState(() {
      chatSessions[currentSessionIndex].messages.add({'sender': 'user', 'text': text});
      _messageController.clear();
      _isLoading = true;
    });

    _scrollToBottom();

    // 2 second anti-spam delay + dynamic language response
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted) return;

      final lower = text.toLowerCase();

      // Language switch commands
      if (lower.contains('hindi me') || lower.contains('speak hindi') || lower.contains('talk in hindi') || lower.contains('in hindi')) {
        _preferredLanguage = 'hi';
      } else if (lower.contains('english me') || lower.contains('speak english') || lower.contains('talk in english') || lower.contains('in english')) {
        _preferredLanguage = 'en';
      }

      bool isHindi = _preferredLanguage == 'hi';
      
      final hindiKeywords = ['kon', 'kya', 'kaise', 'naam', 'tum', 'aap', 'mera', 'bhai', 'namaste', 'batao', 'kaha', 'kar', 'rahe'];
      if (RegExp(r'[\u0900-\u097F]').hasMatch(text) || hindiKeywords.any((k) => lower.contains(k))) {
        isHindi = true;
      } else if (RegExp(r'^[a-zA-Z0-9\s\?!.,]+$').hasMatch(text) && _preferredLanguage != 'hi') {
        isHindi = false;
      }

      String replyText = '';
      if (isHindi) {
        if (lower.contains('kon') || lower.contains('who')) {
          replyText = 'मैं सारथी AI हूँ—आपका व्यक्तिगत डिजिटल सहायक। बताइए, आज मैं आपकी क्या मदद कर सकता हूँ?';
        } else if (lower.contains('naam') || lower.contains('name')) {
          replyText = 'मेरा नाम सारथी AI है। मैं आपकी सहायता के लिए हमेशा तैयार हूँ।';
        } else {
          replyText = 'नमस्ते! मुझे आपका संदेश मिला। मैं सारथी AI हूँ, बताइए मैं आपके इस कार्य में कैसे सहायता करूँ?';
        }
      } else {
        if (lower.contains('who') || lower.contains('kon')) {
          replyText = "I am Saarthi AI—your personal AI assistant. How can I help you today?";
        } else if (lower.contains('name') || lower.contains('naam')) {
          replyText = "My name is Saarthi AI. I'm always here to assist you.";
        } else {
          replyText = "Hello! I received your message. I am Saarthi AI, how can I assist you with this?";
        }
      }

      setState(() {
        _isLoading = false;
        chatSessions[currentSessionIndex].messages.add({
          'sender': 'ai',
          'text': replyText,
        });
      });
      _scrollToBottom();
    });
  }
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final currentChat = chatSessions[currentSessionIndex];

    return Scaffold(
      backgroundColor: const Color(0xFF121B22),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: Text(currentChat.title, style: const TextStyle(fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.call),
            onPressed: () {},
          ),
        ],
      ),
      drawer: Drawer(
        backgroundColor: const Color(0xFF1F2C34),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    minimumSize: const Size(double.infinity, 45),
                  ),
                  onPressed: _startNewChat,
                  icon: const Icon(Icons.add, color: Colors.white),
                  label: const Text('+ New Chat', style: TextStyle(color: Colors.white, fontSize: 16)),
                ),
              ),
              const Divider(color: Colors.white24),
              Expanded(
                child: ListView.builder(
                  itemCount: chatSessions.length,
                  itemBuilder: (context, index) {
                    final session = chatSessions[index];
                    final isSelected = index == currentSessionIndex;

                    return ListTile(
                      tileColor: isSelected ? const Color(0xFF2A3942) : Colors.transparent,
                      leading: const Icon(Icons.chat_bubble_outline, color: Colors.white70),
                      title: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                        onPressed: () => _deleteChat(index),
                      ),
                      onTap: () {
                        setState(() => currentSessionIndex = index);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: currentChat.messages.length + (_isLoading ? 1 : 0),
              itemBuilder: (context, index) {
                if (_isLoading && index == currentChat.messages.length) {
  return Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF202C33),
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Text('AI typing...', style: TextStyle(color: Colors.white70, fontSize: 14)),
    ),
  );
}
                final msg = currentChat.messages[index];
                final isUser = msg['sender'] == 'user';

                return Align(
                  alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isUser ? const Color(0xFF005C4B) : const Color(0xFF202C33),
                      borderRadius: BorderRadius.circular(10),
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            color: const Color(0xFF1F2C34),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Message...',
                      hintStyle: const TextStyle(color: Colors.grey),
                      filled: true,
                      fillColor: const Color(0xFF2A3942),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: const Color(0xFF00A884),
                  child: _isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : IconButton(
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

// ----------------- PHONEBOOK / CONTACT LIST SCREEN -----------------
// ----------------- PHONEBOOK / CONTACT LIST SCREEN -----------------
class PhonebookScreen extends StatelessWidget {
  const PhonebookScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Yahan real contacts API ya flutter_contacts connect ho sakta hai
    final List<Map<String, String>> dummyContacts = [
      {'name': 'Aakash Sharma', 'phone': '+91 9876543210'},
      {'name': 'Pooja Verma', 'phone': '+91 9811122233'},
      {'name': 'Ramesh Kumar', 'phone': '+91 9900011223'},
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF121B22),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Phonebook / Contacts'),
      ),
      body: ListView.separated(
        itemCount: dummyContacts.length,
        separatorBuilder: (_, __) => const Divider(color: Colors.white10),
        itemBuilder: (context, index) {
          final contact = dummyContacts[index];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: const Color(0xFF00A884),
              child: Text(contact['name']![0], style: const TextStyle(color: Colors.white)),
            ),
            title: Text(contact['name']!, style: const TextStyle(color: Colors.white)),
            subtitle: Text(contact['phone']!, style: const TextStyle(color: Colors.grey)),
            trailing: IconButton(
              icon: const Icon(Icons.call, color: Color(0xFF00A884)),
              onPressed: () {},
            ),
          );
        },
      ),
    );
  }
}
