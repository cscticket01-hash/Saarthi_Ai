import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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
  static const String _groqApiKey = String.fromEnvironment('GEMINI_API_KEY');

  List<ChatSession> chatSessions = [
    ChatSession(
      id: '1',
      title: 'First Conversation',
      messages: [],
    ),
  ];

  int currentSessionIndex = 0;

  void _startNewChat() {
    setState(() {
      final newChat = ChatSession(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: 'Saarthi AI',
        messages: [],
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

Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isLoading) return;

    setState(() {
      // Pehle message par title snippet update hoga
      if (chatSessions[currentSessionIndex].messages.isEmpty) {
        String cleanTitle = text.trim();
        if (cleanTitle.length > 25) {
          cleanTitle = '${cleanTitle.substring(0, 25)}...';
        }
        chatSessions[currentSessionIndex].title = cleanTitle;
      }

      chatSessions[currentSessionIndex].messages.add({'sender': 'user', 'text': text});
      _messageController.clear();
      _isLoading = true;
    });

    _scrollToBottom();

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .collection('chats')
          .add({
        'sender': 'user',
        'text': text,
        'timestamp': FieldValue.serverTimestamp(),
      });
    }

    final delayFuture = Future.delayed(const Duration(seconds: 2));
    String reply = '';

    try {
      final response = await http.post(
        Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          'Authorization': 'Bearer $_groqApiKey',
        },
        body: jsonEncode({
          'model': 'openai/gpt-oss-120b',
          'messages': [
            {
              'role': 'system',
              'content':
                  'Aap Saarthi AI hain. User se bilkul natural Hinglish ya Hindi me seedhi aur to-the-point baatcheet karein jaise ek dost karta hai. Formal faltu dialogues jaise "Aapka message mila" ya "Main process kar raha hoon" bilkul nahi bolna. Seedha sawal ka direct jawab dena.'
            },
            {
              'role': 'user',
              'content': text,
            }
          ],
          'temperature': 0.7,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        reply = data['choices'][0]['message']['content'].toString().trim();
      } else {
        reply = 'Status ${response.statusCode}: ${response.body}';
      }
    } catch (e) {
      reply = 'Network error: Internet check karein.';
    }

    await delayFuture;

    if (mounted) {
      setState(() {
        _isLoading = false;
        chatSessions[currentSessionIndex].messages.add({
          'sender': 'ai',
          'text': reply,
        });
      });
      _scrollToBottom();

      if (currentUser != null) {
        FirebaseFirestore.instance
            .collection('users')
            .doc(currentUser.uid)
            .collection('chats')
            .add({
          'sender': 'saarthi',
          'text': reply,
          'timestamp': FieldValue.serverTimestamp(),
        });
      }
    }
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
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.smart_toy_rounded, color: Color(0xFF00E676)),
            SizedBox(width: 10),
            Text(
              'Saarthi AI',
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 0.5),
            ),
          ],
        ),
      ),
drawer: Drawer(
        backgroundColor: const Color(0xFF1F2C34),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. Logged-in User Email Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 14.0),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: Colors.white12, width: 1.0),
                  ),
                ),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 16,
                      backgroundColor: Color(0xFF00A884),
                      child: Icon(Icons.person, color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        FirebaseAuth.instance.currentUser?.email ?? 'user@gmail.com',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),

              // 2. + New Chat Button
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    minimumSize: const Size(double.infinity, 45),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _startNewChat,
                  icon: const Icon(Icons.add, color: Colors.white),
                  label: const Text(
                    ' New Chat',
                    style: TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ),

             const Divider(color: Colors.white24, height: 1),

              // Recents Heading
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  'Recents',
                  style: TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ),

              // Gemini Style Chat List with Message Snippet
              Expanded(
                child: ListView.builder(
                  itemCount: chatSessions.length,
                  itemBuilder: (context, index) {
                    final session = chatSessions[index];
                    final isSelected = index == currentSessionIndex;

                    // Message snippet preview
                    final previewSnippet = session.messages.isNotEmpty
                        ? session.messages.first['text'] ?? ''
                        : 'No messages yet';

                    return ListTile(
                      selected: isSelected,
                      selectedTileColor: Colors.white.withOpacity(0.08),
                      leading: const Icon(Icons.chat_bubble_outline, color: Colors.white70, size: 18),
                      title: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      subtitle: Text(
                        previewSnippet,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.grey, fontSize: 12),
                      ),
                      trailing: chatSessions.length > 1
                          ? IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                              onPressed: () => _deleteChat(index),
                            )
                          : null,
                      onTap: () {
                        setState(() {
                          currentSessionIndex = index;
                        });
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
              const Divider(color: Colors.white24, height: 1),
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  tileColor: Colors.redAccent.withOpacity(0.1),
                  leading: const Icon(Icons.logout, color: Colors.redAccent),
                  title: const Text(
                    'Logout',
                    style: TextStyle(
                      color: Colors.redAccent,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onTap: () {
                    FirebaseAuth.instance.signOut();
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
