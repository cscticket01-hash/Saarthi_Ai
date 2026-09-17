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
    const SchoolAdminLoginScreen(),
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
            icon: Icon(Icons.school_outlined),
            activeIcon: Icon(Icons.school),
            label: 'School Login',
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

  ChatSession({required this.id, required this.title});
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
  String _currentSessionId = DateTime.now().millisecondsSinceEpoch.toString();
  static const String _groqApiKey = String.fromEnvironment('GEMINI_API_KEY');

  List<ChatSession> chatSessions = [
    ChatSession(
      id: 'default_chat',
      title: 'First Conversation',
    ),
  ];

  int currentSessionIndex = 0;

  @override
  void initState() {
    super.initState();
    _currentSessionId = chatSessions[0].id;
  }

  void _startNewChat() {
    final newId = DateTime.now().millisecondsSinceEpoch.toString();
    setState(() {
      final newChat = ChatSession(
        id: newId,
        title: 'New Chat',
      );
      chatSessions.insert(0, newChat);
      currentSessionIndex = 0;
      _currentSessionId = newId;
    });
    Navigator.pop(context);
  }

  void _deleteChat(int index) {
    setState(() {
      chatSessions.removeAt(index);
      if (chatSessions.isEmpty) {
        _startNewChat();
      } else {
        currentSessionIndex = 0;
        _currentSessionId = chatSessions[0].id;
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    final currentUser = FirebaseAuth.instance.currentUser;
    if (text.isEmpty || _isLoading || currentUser == null) return;

    setState(() {
      if (chatSessions[currentSessionIndex].title == 'First Conversation' ||
          chatSessions[currentSessionIndex].title == 'New Chat') {
        String cleanTitle = text;
        if (cleanTitle.length > 20) {
          cleanTitle = '${cleanTitle.substring(0, 20)}...';
        }
        chatSessions[currentSessionIndex].title = cleanTitle;
      }
      _messageController.clear();
      _isLoading = true;
    });

    // 1. Save User message under current session
    await FirebaseFirestore.instance
        .collection('users')
        .doc(currentUser.uid)
        .collection('sessions')
        .doc(_currentSessionId)
        .collection('messages')
        .add({
      'sender': 'user',
      'text': text,
      'timestamp': FieldValue.serverTimestamp(),
    });

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

    if (mounted) {
      setState(() {
        _isLoading = false;
      });

      // 2. Save AI reply under current session
      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .collection('sessions')
          .doc(_currentSessionId)
          .collection('messages')
          .add({
        'sender': 'ai',
        'text': reply,
        'timestamp': FieldValue.serverTimestamp(),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
                child: TextField(
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Search chats...',
                    hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                    prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 18),
                    filled: true,
                    fillColor: const Color(0xFF2A3942),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const Divider(color: Colors.white24, height: 1),
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
              Expanded(
                child: ListView.builder(
                  itemCount: chatSessions.length,
                  itemBuilder: (context, index) {
                    final session = chatSessions[index];
                    final isSelected = index == currentSessionIndex;

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
                      trailing: chatSessions.length > 1
                          ? IconButton(
                              icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                              onPressed: () => _deleteChat(index),
                            )
                          : null,
                      onTap: () {
                        setState(() {
                          currentSessionIndex = index;
                          _currentSessionId = session.id;
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
            child: StreamBuilder<User?>(
              stream: FirebaseAuth.instance.authStateChanges(),
              builder: (context, authSnap) {
                final user = authSnap.data;
                if (user == null) {
                  return const Center(
                    child: Text('Kripya Login karein', style: TextStyle(color: Colors.grey)),
                  );
                }

                return StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('users')
                      .doc(user.uid)
                      .collection('sessions')
                      .doc(_currentSessionId)
                      .collection('messages')
                      .snapshots(),
                  builder: (context, chatSnap) {
                    if (chatSnap.connectionState == ConnectionState.waiting) {
                      return const Center(
                        child: CircularProgressIndicator(color: Color(0xFF00A884)),
                      );
                    }
                    if (!chatSnap.hasData || chatSnap.data!.docs.isEmpty) {
                      return const Center(
                        child: Text(
                          'Nayi chat shuru karein!',
                          style: TextStyle(color: Colors.grey),
                        ),
                      );
                    }

                    // Client side sort taaki index ki jarurat na pade
                    final docs = chatSnap.data!.docs.toList();
                    docs.sort((a, b) {
                      final tA = (a.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
                      final tB = (b.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
                      if (tA == null) return 1;
                      if (tB == null) return -1;
                      return tB.compareTo(tA);
                    });

                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      reverse: true,
                      itemCount: docs.length + (_isLoading ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (_isLoading && index == docs.length) {
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

                        final m = docs[index].data() as Map<String, dynamic>;
                        final isUser = m['sender'] == 'user';

                        return Align(
                          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: isUser ? const Color(0xFF005C4B) : const Color(0xFF202C33),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.of(context).size.width * 0.8,
                            ),
                            child: Text(
                              m['text'] ?? '',
                              style: const TextStyle(color: Colors.white, fontSize: 15),
                            ),
                          ),
                        );
                      },
                    );
                  },
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

// ----------------- SCHOOL PORTAL (ADMIN & STUDENT LOGIN) -----------------
class SchoolAdminLoginScreen extends StatefulWidget {
  const SchoolAdminLoginScreen({super.key});

  @override
  State<SchoolAdminLoginScreen> createState() => _SchoolAdminLoginScreenState();
}

class _SchoolAdminLoginScreenState extends State<SchoolAdminLoginScreen> {
  bool _isAdminMode = true; // true = Admin, false = Student
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoggingIn = false;
  String _selectedClass = 'Class 1'; // Default class

  final List<String> _classList = List.generate(10, (index) => 'Class ${index + 1}');

  void _switchRole(bool isAdmin) {
    setState(() {
      _isAdminMode = isAdmin;
      _usernameController.clear();
      _passwordController.clear();
    });
  }

  Future<void> _handleLogin() async {
    final idText = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (idText.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isAdminMode
              ? 'Kripya Username aur Password bharein'
              : 'Kripya Roll No / Student ID aur Password bharein'),
        ),
      );
      return;
    }

    setState(() => _isLoggingIn = true);

    try {
Future<void> _handleLogin() async {
    final idText = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (idText.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_isAdminMode
              ? 'Kripya Admin Email aur Password bharein'
              : 'Kripya Roll No / Student ID aur Password bharein'),
        ),
      );
      return;
    }

    setState(() => _isLoggingIn = true);

    try {
      if (_isAdminMode) {
        // Secret & Secure: Firebase Authentication login (Inspect panel me password nahi dikhega)
        try {
          await FirebaseAuth.instance.signInWithEmailAndPassword(
            email: idText,
            password: password,
          );

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                backgroundColor: Color(0xFF00A884),
                content: Text('Admin Login Safal hua!'),
              ),
            );
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const AdminDashboardScreen()),
            );
          }
        } on FirebaseAuthException catch (e) {
          if (mounted) {
            String errorMsg = 'Galat Admin Email ya Password!';
            if (e.code == 'user-not-found') {
              errorMsg = 'Yeh Admin account registered nahi hai.';
            } else if (e.code == 'wrong-password') {
              errorMsg = 'Galat password dala hai.';
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Colors.redAccent,
                content: Text(errorMsg),
              ),
            );
          }
        }
      } else {
        // Student credentials verification
        if (idText == 'student' && password == '123456') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Color(0xFF00A884),
              content: Text('Student Login Safal hua!'),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.redAccent,
              content: Text('Galat Student ID ya Password!'),
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
  }
      } else {
        // Student credentials verification (Testing ke liye)
        if (idText == 'student' && password == '123456') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Color(0xFF00A884),
              content: Text('Student Login Safal hua!'),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.redAccent,
              content: Text('Galat Student ID ya Password!'),
            ),
          );
        }
      }
    } finally {
      if (mounted) setState(() => _isLoggingIn = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121B22),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('School Portal'),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _isAdminMode ? Icons.admin_panel_settings_rounded : Icons.school_rounded,
                size: 65,
                color: const Color(0xFF00A884),
              ),
              const SizedBox(height: 12),
              Text(
                _isAdminMode ? 'ADMIN LOGIN' : 'STUDENT LOGIN',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 24),

              // Role Selector Tabs (Admin vs Student)
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2C34),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _switchRole(true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: _isAdminMode ? const Color(0xFF00A884) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.security, size: 16, color: Colors.white),
                              SizedBox(width: 6),
                              Text(
                                'Admin',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _switchRole(false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          decoration: BoxDecoration(
                            color: !_isAdminMode ? const Color(0xFF00A884) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.person, size: 16, color: Colors.white),
                              SizedBox(width: 6),
                              Text(
                                'Student',
                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              if (!_isAdminMode) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F2C34),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.class_outlined, color: Color(0xFF00A884)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: _selectedClass,
                            dropdownColor: const Color(0xFF1F2C34),
                            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.grey),
                            style: const TextStyle(color: Colors.white, fontSize: 16),
                            isExpanded: true,
                            items: _classList.map((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              );
                            }).toList(),
                            onChanged: (newValue) {
                              if (newValue != null) {
                                setState(() {
                                  _selectedClass = newValue;
                                });
                              }
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              
              // Username / Roll No Field
              TextField(
                controller: _usernameController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: _isAdminMode ? 'Admin Email' : 'Student ID / Roll No',
                  hintStyle: const TextStyle(color: Colors.grey),
                  prefixIcon: Icon(
                    _isAdminMode ? Icons.person_outline : Icons.badge_outlined,
                    color: const Color(0xFF00A884),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1F2C34),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Password Field
              TextField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Password',
                  hintStyle: const TextStyle(color: Colors.grey),
                  prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFF00A884)),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword ? Icons.visibility_off : Icons.visibility,
                      color: Colors.grey,
                    ),
                    onPressed: () {
                      setState(() => _obscurePassword = !_obscurePassword);
                    },
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1F2C34),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Login Button
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _isLoggingIn ? null : _handleLogin,
                  child: _isLoggingIn
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : Text(
                          _isAdminMode ? 'LOGIN AS ADMIN' : 'LOGIN AS STUDENT',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
// ==================== ADMIN DASHBOARD SCREEN ====================
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  // Notice controllers & state
  final TextEditingController _noticeTitleController = TextEditingController();
  final TextEditingController _noticeDescController = TextEditingController();
  String _noticeCategory = 'Holiday';
  final List<String> _noticeCategories = ['Holiday', 'Exam', 'Event', 'General'];
  String? _editingNoticeId; // null = new notice, non-null = editing mode
  
  // Google Drive state
  String? _connectedDriveFolder;
  final TextEditingController _driveFolderController = TextEditingController();
 
  // Student Directory controllers
  String _directoryClass = 'Class 1';
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _rollController = TextEditingController();
  final TextEditingController _parentContactController = TextEditingController();
  String? _studentPhotoUrl;
  
  bool _isSavingNotice = false;
  bool _isSearchingStudent = false;
  final List<String> _classList = List.generate(10, (index) => 'Class ${index + 1}');

  // Teacher List Data (Placeholder)
  final List<Map<String, String>> _teachersList = [
    {'name': 'Ramesh Sharma', 'subject': 'Mathematics', 'phone': '+91 9876543210'},
    {'name': 'Priya Sen', 'subject': 'Bengali & English', 'phone': '+91 9876543211'},
    {'name': 'Amit Paul', 'subject': 'Science', 'phone': '+91 9876543212'},
  ];
  // Add Student Popup Dialog
  void _openAddStudentDialog() {
    final nameCtrl = TextEditingController();
    final parentCtrl = TextEditingController();
    final rollCtrl = TextEditingController();
    final contactCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    final stateCtrl = TextEditingController();
    final districtCtrl = TextEditingController();
    final joiningDateCtrl = TextEditingController(
      text: "${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}",
    );
    final photoUrlCtrl = TextEditingController(); // Drive Direct Image Link
    String selectedClass = _directoryClass;
    bool isSaving = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          backgroundColor: const Color(0xFF1F2C34),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Row(
            children: [
              Icon(Icons.person_add_alt_1, color: Color(0xFF00A884), size: 22),
              SizedBox(width: 10),
              Text('Add New Student', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: selectedClass,
                          dropdownColor: const Color(0xFF1F2C34),
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Class'),
                          items: _classList.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                          onChanged: (val) => setDlgState(() => selectedClass = val!),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: rollCtrl,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Roll No *'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Student Full Name *'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: parentCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration("Parent's / Guardian Name *"),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: contactCtrl,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Contact No *'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: photoUrlCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Google Drive Photo URL / Link'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: addressCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Address'),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: districtCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('District'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: stateCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('State'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: pinCtrl,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('PIN Code'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: joiningDateCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Joining Date'),
                        ),
                      ),
                    ],
                  ),
                ],
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
              onPressed: isSaving ? null : () async {
                final name = nameCtrl.text.trim();
                final roll = rollCtrl.text.trim();
                final contact = contactCtrl.text.trim();
                final parent = parentCtrl.text.trim();

                if (name.isEmpty || roll.isEmpty || contact.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(backgroundColor: Colors.redAccent, content: Text('Name, Roll No aur Contact bharna zaroori hai!')),
                  );
                  return;
                }

                setDlgState(() => isSaving = true);
                final docId = '${selectedClass}_Roll_$roll';

                try {
                  await FirebaseFirestore.instance.collection('students_directory').doc(docId).set({
                    'name': name,
                    'parentName': parent,
                    'class': selectedClass,
                    'rollNo': roll,
                    'parentContact': contact,
                    'photoUrl': photoUrlCtrl.text.trim(),
                    'address': addressCtrl.text.trim(),
                    'pinCode': pinCtrl.text.trim(),
                    'district': districtCtrl.text.trim(),
                    'state': stateCtrl.text.trim(),
                    'joiningDate': joiningDateCtrl.text.trim(),
                    'createdAt': DateTime.now().millisecondsSinceEpoch,
                  });

                  if (mounted) {
                    Navigator.pop(ctx);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Student successfully add ho gaya!')),
                    );
                  }
                } catch (e) {
                  setDlgState(() => isSaving = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(backgroundColor: Colors.redAccent, content: Text('Error: ${e.toString()}')),
                  );
                }
              },
              child: Text(isSaving ? 'Saving...' : 'Save Student', style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
  
  // 1. Notice Publish or Update Function
  Future<void> _saveNotice() async {
    final title = _noticeTitleController.text.trim();
    final desc = _noticeDescController.text.trim();
    if (title.isEmpty || desc.isEmpty) return;

    setState(() => _isSavingNotice = true);

    if (_editingNoticeId == null) {
      await FirebaseFirestore.instance.collection('school_notices').add({
        'title': title,
        'description': desc,
        'category': _noticeCategory,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
    } else {
      await FirebaseFirestore.instance.collection('school_notices').doc(_editingNoticeId).update({
        'title': title,
        'description': desc,
        'category': _noticeCategory,
        'lastEdited': DateTime.now().millisecondsSinceEpoch,
      });
    }

    _cancelNoticeEdit();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF00A884),
          content: Text('Notice successfully updated!'),
        ),
      );
    }
  }

  void _startEditNotice(String id, Map<String, dynamic> data) {
    setState(() {
      _editingNoticeId = id;
      _noticeTitleController.text = data['title'] ?? '';
      _noticeDescController.text = data['description'] ?? '';
      _noticeCategory = _noticeCategories.contains(data['category']) ? data['category'] : 'General';
    });
  }

  void _cancelNoticeEdit() {
    setState(() {
      _editingNoticeId = null;
      _noticeTitleController.clear();
      _noticeDescController.clear();
      _isSavingNotice = false;
    });
  }

  Future<void> _deleteNotice(String id) async {
    await FirebaseFirestore.instance.collection('school_notices').doc(id).delete();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Notice delete ho gaya!'),
        ),
      );
    }
  }
  // Settings Popup (Google Drive Connect / Remove)
  void _openSettingsDialog() {
    _driveFolderController.text = _connectedDriveFolder ?? '';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1F2C34),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: const Row(
            children: [
              Icon(Icons.settings, color: Color(0xFF00A884), size: 22),
              SizedBox(width: 10),
              Text('Settings', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Google Drive Integration',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Student ID Card aur photos fetch karne ke liye Drive link karein.',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
                const SizedBox(height: 14),

                // Status Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _connectedDriveFolder != null
                        ? const Color(0xFF00A884).withOpacity(0.15)
                        : Colors.orangeAccent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _connectedDriveFolder != null ? Icons.check_circle : Icons.cloud_off,
                        color: _connectedDriveFolder != null ? const Color(0xFF00A884) : Colors.orangeAccent,
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _connectedDriveFolder != null ? 'Connected' : 'Not Connected',
                        style: TextStyle(
                          color: _connectedDriveFolder != null ? const Color(0xFF00A884) : Colors.orangeAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),

                // Input Field
                TextField(
                  controller: _driveFolderController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: _inputDecoration('Drive Folder URL / Folder ID'),
                ),
                const SizedBox(height: 14),

                // Action Buttons: Connect/Update & Remove
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
                        onPressed: () {
                          final text = _driveFolderController.text.trim();
                          if (text.isNotEmpty) {
                            setState(() => _connectedDriveFolder = text);
                            Navigator.pop(ctx);
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                backgroundColor: Color(0xFF00A884),
                                content: Text('Google Drive successfully connected!'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.add_link, color: Colors.white, size: 16),
                        label: Text(
                          _connectedDriveFolder != null ? 'Update Link' : 'Connect Drive',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                    if (_connectedDriveFolder != null) ...[
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent)),
                        onPressed: () {
                          setState(() {
                            _connectedDriveFolder = null;
                            _driveFolderController.clear();
                          });
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              backgroundColor: Colors.redAccent,
                              content: Text('Google Drive folder removed.'),
                            ),
                          );
                        },
                        icon: const Icon(Icons.link_off, color: Colors.redAccent, size: 16),
                        label: const Text('Remove', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close', style: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }
  void _showNoticeDetailDialog(Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.2),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                data['category'] ?? 'General',
                style: const TextStyle(color: Color(0xFF00A884), fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                data['title'] ?? '',
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Text(
            data['description'] ?? '',
            style: const TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFF00A884))),
          ),
        ],
      ),
    );
  }

  // 2. Student Search Function
  Future<void> _searchStudent() async {
    final roll = _rollController.text.trim();
    if (roll.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kripya Roll Number bharein')),
      );
      return;
    }

    setState(() => _isSearchingStudent = true);
    final docId = '${_directoryClass}_Roll_$roll';

    final doc = await FirebaseFirestore.instance.collection('students_directory').doc(docId).get();

    if (doc.exists) {
      final data = doc.data()!;
      _nameController.text = data['name'] ?? '';
      _parentContactController.text = data['parentContact'] ?? '';
      _studentPhotoUrl = data['photoUrl']; // Photo link fetch
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF00A884),
            content: Text('Student mil gaya!'),
          ),
        );
      }
    } else {
      _nameController.clear();
      _parentContactController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Is Roll No ka koi student nahi mila!'),
          ),
        );
      }
    }

    setState(() => _isSearchingStudent = false);
  }

  // 3. Teacher Add Placeholder Dialog
  void _openAddTeacherDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Add Teacher', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: const Text(
          'Fields baad mein jode jayenge. Option abhi ready hai.',
          style: TextStyle(color: Colors.grey, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFF00A884))),
          ),
        ],
      ),
    );
  }

  // 4. Digital ID Card Popup
  void _showIdCardPreview() {
    final name = _nameController.text.trim().isEmpty ? 'Student Name' : _nameController.text.trim();
    final roll = _rollController.text.trim().isEmpty ? '01' : _rollController.text.trim();
    final contact = _parentContactController.text.trim().isEmpty ? 'Not Available' : _parentContactController.text.trim();

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 320,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1F2C34),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF00A884), width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.school, color: Color(0xFF00A884), size: 22),
                  SizedBox(width: 8),
                  Text(
                    'SARASWATI VIDYANIKETAN',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.8),
                  ),
                ],
              ),
              const Divider(color: Colors.white24, height: 24),
              CircleAvatar(
                radius: 36,
                backgroundColor: const Color(0xFF121B22),
                backgroundImage: (_studentPhotoUrl != null && _studentPhotoUrl!.isNotEmpty)
                    ? NetworkImage(_studentPhotoUrl!)
                    : null,
                child: (_studentPhotoUrl == null || _studentPhotoUrl!.isEmpty)
                    ? const Icon(Icons.person, size: 45, color: Color(0xFF00A884))
                    : null,
              ),
              const SizedBox(height: 12),
              Text(
                name.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                '$_directoryClass  |  Roll No: $roll',
                style: const TextStyle(color: Color(0xFF00A884), fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF121B22),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Parent Contact:', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    Text(contact, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close Preview', style: TextStyle(color: Colors.grey)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121B22),
appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Admin Command Center'),
        actions: [
          PopupMenuButton<String>(
            color: const Color(0xFF1F2C34),
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) {
              if (value == 'settings') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsScreen()),
                );
              }
            },
            itemBuilder: (BuildContext context) => [
              const PopupMenuItem<String>(
                value: 'profile',
                child: Row(
                  children: [
                    Icon(Icons.person_outline, color: Color(0xFF00A884), size: 20),
                    SizedBox(width: 12),
                    Text('Profile', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, color: Color(0xFF00A884), size: 20),
                    SizedBox(width: 12),
                    Text('Settings', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ================= LEFT COLUMN =================
            Expanded(
              flex: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- DIGITAL NOTICE BOARD ---
                  _buildSectionHeader('Digital Notice Board', Icons.campaign),
                  _buildCardWrapper(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: _noticeCategory,
                                dropdownColor: const Color(0xFF1F2C34),
                                style: const TextStyle(color: Colors.white),
                                decoration: _inputDecoration('Notice Type'),
                                items: _noticeCategories.map((cat) => DropdownMenuItem(value: cat, child: Text(cat))).toList(),
                                onChanged: (val) => setState(() => _noticeCategory = val!),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _noticeTitleController,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Title (e.g. Summer Vacation / Unit Test)'),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _noticeDescController,
                          maxLines: 2,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Details / Instructions...'),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
                                onPressed: _isSavingNotice ? null : _saveNotice,
                                icon: Icon(_editingNoticeId == null ? Icons.campaign : Icons.check, color: Colors.white, size: 18),
                                label: Text(
                                  _editingNoticeId == null ? 'Publish Notice' : 'Update Notice',
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                            if (_editingNoticeId != null) ...[
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: _cancelNoticeEdit,
                                icon: const Icon(Icons.close, color: Colors.redAccent),
                                tooltip: 'Cancel Edit',
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // --- STUDENT DIRECTORY HEADER WITH ADD BUTTON ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSectionHeader('Student Directory & ID Cards', Icons.badge_outlined),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A884),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onPressed: _openAddStudentDialog,
                        icon: const Icon(Icons.add, color: Colors.white, size: 16),
                        label: const Text('Add Student', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  _buildCardWrapper(
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: _directoryClass,
                                dropdownColor: const Color(0xFF1F2C34),
                                style: const TextStyle(color: Colors.white),
                                decoration: _inputDecoration('Class'),
                                items: _classList.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                                onChanged: (val) => setState(() => _directoryClass = val!),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextField(
                                controller: _rollController,
                                keyboardType: TextInputType.number,
                                style: const TextStyle(color: Colors.white),
                                decoration: _inputDecoration('Roll No'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _nameController,
                          readOnly: true,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Student Full Name (Auto Fetched)'),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _parentContactController,
                          readOnly: true,
                          keyboardType: TextInputType.phone,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Parent Contact No (Auto Fetched)'),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
                                onPressed: _isSearchingStudent ? null : _searchStudent,
                                icon: const Icon(Icons.search, color: Colors.white, size: 18),
                                label: Text(_isSearchingStudent ? 'Searching...' : 'Search Record', style: const TextStyle(color: Colors.white)),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Color(0xFF00A884)),
                                ),
                                onPressed: _showIdCardPreview,
                                icon: const Icon(Icons.visibility, color: Color(0xFF00A884), size: 18),
                                label: const Text('View ID Card', style: TextStyle(color: Color(0xFF00A884))),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2A3942),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(color: Color(0xFF00A884), width: 1),
                              ),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (context) => const AllStudentsListScreen()),
                              );
                            },
                            icon: const Icon(Icons.people_alt_outlined, color: Color(0xFF00A884), size: 18),
                            label: const Text(
                              'View All Students (Class 1-10)',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(width: 20),

            // ================= RIGHT COLUMN =================
            Expanded(
              flex: 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- RIGHT TOP: TEACHERS DIRECTORY ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildSectionHeader('Teachers Directory', Icons.person_add_alt_1),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A884),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                        onPressed: _openAddTeacherDialog,
                        icon: const Icon(Icons.add, color: Colors.white, size: 16),
                        label: const Text('Add Teacher', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ),
                    ],
                  ),
                  _buildCardWrapper(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Registered Teachers List:', style: TextStyle(color: Colors.grey, fontSize: 13, fontWeight: FontWeight.bold)),
                        const SizedBox(height: 10),
                        ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: _teachersList.length,
                          separatorBuilder: (ctx, i) => const Divider(color: Colors.white12, height: 12),
                          itemBuilder: (context, index) {
                            final teacher = _teachersList[index];
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              leading: const CircleAvatar(
                                radius: 18,
                                backgroundColor: Color(0xFF121B22),
                                child: Icon(Icons.school, color: Color(0xFF00A884), size: 18),
                              ),
                              title: Text(teacher['name']!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                              subtitle: Text('${teacher['subject']} • ${teacher['phone']}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                              trailing: const Icon(Icons.more_vert, color: Colors.grey, size: 18),
                            );
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // --- RIGHT BOTTOM: PUBLISHED NOTICES (SCROLLABLE + PREVIEW/EDIT/DELETE) ---
                  _buildSectionHeader('Published Notices', Icons.article_outlined),
                  _buildCardWrapper(
                    child: SizedBox(
                      height: 280, // 4 notices ke baad scroll hoga
                      child: StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance.collection('school_notices').orderBy('timestamp', descending: true).snapshots(),
                        builder: (context, snapshot) {
                          if (snapshot.connectionState == ConnectionState.waiting) {
                            return const Center(child: CircularProgressIndicator(color: Color(0xFF00A884)));
                          }
                          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                            return const Center(
                              child: Text('Koi notice published nahi hai.', style: TextStyle(color: Colors.grey, fontSize: 13)),
                            );
                          }
                          return ListView.builder(
                            itemCount: snapshot.data!.docs.length,
                            itemBuilder: (context, index) {
                              final doc = snapshot.data!.docs[index];
                              final data = doc.data() as Map<String, dynamic>;
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF121B22),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: Colors.white10),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF00A884).withOpacity(0.2),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  data['category'] ?? 'General',
                                                  style: const TextStyle(color: Color(0xFF00A884), fontSize: 10, fontWeight: FontWeight.bold),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  data['title'] ?? '',
                                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            data['description'] ?? '',
                                            style: const TextStyle(color: Colors.grey, fontSize: 11),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    // 1. Preview
                                    IconButton(
                                      icon: const Icon(Icons.visibility, color: Colors.tealAccent, size: 18),
                                      tooltip: 'Preview Notice',
                                      onPressed: () => _showNoticeDetailDialog(data),
                                    ),
                                    // 2. Edit
                                    IconButton(
                                      icon: const Icon(Icons.edit, color: Colors.blueAccent, size: 18),
                                      tooltip: 'Edit Notice',
                                      onPressed: () => _startEditNotice(doc.id, data),
                                    ),
                                    // 3. Delete
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                      tooltip: 'Delete Notice',
                                    onPressed: () => _deleteNotice(doc.id),
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF00A884), size: 20),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildCardWrapper({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2C34),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
      filled: true,
      fillColor: const Color(0xFF121B22),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
    );
  }
}

// ==================== SETTINGS SCREEN (FULL WINDOW) ====================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _gmailController = TextEditingController();
  String? _linkedGmail;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _fetchLinkedAccount();
  }

  Future<void> _fetchLinkedAccount() async {
    final doc = await FirebaseFirestore.instance
        .collection('school_config')
        .doc('google_drive_account')
        .get();

    if (doc.exists && mounted) {
      setState(() {
        _linkedGmail = doc.data()?['email'];
      });
    }
  }

Future<void> _linkGmail() async {
    final email = _gmailController.text.trim();
    if (email.isEmpty || !email.contains('@gmail.com')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Kripya valid Gmail ID daalein (jaise example@gmail.com)'),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      await FirebaseFirestore.instance
          .collection('school_config')
          .doc('google_drive_account')
          .set({
        'email': email,
        'status': 'connected',
        'linkedAt': DateTime.now().millisecondsSinceEpoch,
      });

      if (mounted) {
        setState(() {
          _linkedGmail = email;
          _isLoading = false;
          _gmailController.clear();
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF00A884),
            content: Text('Google Drive account successfully link ho gaya!'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text('Error: ${e.toString()}'),
          ),
        );
      }
    }
  }

  Future<void> _unlinkGmail() async {
    setState(() => _isLoading = true);

    await FirebaseFirestore.instance
        .collection('school_config')
        .doc('google_drive_account')
        .delete();

    if (mounted) {
      setState(() {
        _linkedGmail = null;
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Google Drive account unlink kar diya gaya.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121B22),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Settings'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cloud Storage & Database',
              style: TextStyle(
                color: Color(0xFF00A884),
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Student records, ID card photos aur data store/receive karne ke liye official Gmail ID link karein.',
              style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1F2C34),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const CircleAvatar(
                        radius: 22,
                        backgroundColor: Color(0xFF121B22),
                        child: Icon(Icons.add_to_drive, color: Color(0xFF00A884), size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Google Drive Integration',
                              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _linkedGmail != null ? 'Active Connection' : 'No Account Linked',
                              style: TextStyle(
                                color: _linkedGmail != null ? const Color(0xFF00A884) : Colors.orangeAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 28),
                  if (_linkedGmail != null) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121B22),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF00A884).withOpacity(0.4)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.verified_user, color: Color(0xFF00A884), size: 20),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Linked Gmail ID', style: TextStyle(color: Colors.grey, fontSize: 11)),
                                Text(
                                  _linkedGmail!,
                                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _isLoading ? null : _unlinkGmail,
                        icon: const Icon(Icons.link_off, color: Colors.redAccent, size: 18),
                        label: const Text('Unlink / Change Account', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ] else ...[
                    TextField(
                      controller: _gmailController,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: InputDecoration(
                        hintText: 'school.admin@gmail.com',
                        hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                        prefixIcon: const Icon(Icons.mail_outline, color: Color(0xFF00A884), size: 20),
                        filled: true,
                        fillColor: const Color(0xFF121B22),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A884),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: _isLoading ? null : _linkGmail,
                        icon: const Icon(Icons.link, color: Colors.white, size: 18),
                        label: Text(
                          _isLoading ? 'Linking...' : 'Link Google Account',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== ALL STUDENTS LIST SCREEN (FULL WINDOW) ====================
class AllStudentsListScreen extends StatefulWidget {
  const AllStudentsListScreen({super.key});

  @override
  State<AllStudentsListScreen> createState() => _AllStudentsListScreenState();
}

class _AllStudentsListScreenState extends State<AllStudentsListScreen> {
  String _selectedClassFilter = 'Class 1';
  final List<String> _classes = List.generate(10, (index) => 'Class ${index + 1}');

  Future<void> _deleteStudent(String docId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Delete Student', style: TextStyle(color: Colors.white)),
        content: const Text('Kya aap is student ka record delete karna chahte hain?', style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );

    if (confirm == true) {
      await FirebaseFirestore.instance.collection('students_directory').doc(docId).delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(backgroundColor: Colors.redAccent, content: Text('Student record delete ho gaya!')),
        );
      }
    }
  }

  void _editStudent(String docId, Map<String, dynamic> data) {
    final nameCtrl = TextEditingController(text: data['name']);
    final parentCtrl = TextEditingController(text: data['parentName']);
    final contactCtrl = TextEditingController(text: data['parentContact']);
    final photoCtrl = TextEditingController(text: data['photoUrl']);
    final addressCtrl = TextEditingController(text: data['address']);
    final pinCtrl = TextEditingController(text: data['pinCode']);
    final districtCtrl = TextEditingController(text: data['district']);
    final stateCtrl = TextEditingController(text: data['state']);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('Edit Student (${data['class']} - Roll ${data['rollNo']})', style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: 450,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput('Full Name')),
                const SizedBox(height: 8),
                TextField(controller: parentCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput("Parent's Name")),
                const SizedBox(height: 8),
                TextField(controller: contactCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput('Contact No')),
                const SizedBox(height: 8),
                TextField(controller: photoCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput('Photo URL')),
                const SizedBox(height: 8),
                TextField(controller: addressCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput('Address')),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: TextField(controller: districtCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput('District'))),
                    const SizedBox(width: 8),
                    Expanded(child: TextField(controller: stateCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput('State'))),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(controller: pinCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput('PIN Code')),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
            onPressed: () async {
              await FirebaseFirestore.instance.collection('students_directory').doc(docId).update({
                'name': nameCtrl.text.trim(),
                'parentName': parentCtrl.text.trim(),
                'parentContact': contactCtrl.text.trim(),
                'photoUrl': photoCtrl.text.trim(),
                'address': addressCtrl.text.trim(),
                'district': districtCtrl.text.trim(),
                'state': stateCtrl.text.trim(),
                'pinCode': pinCtrl.text.trim(),
              });
              if (mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Student update ho gaya!')),
                );
              }
            },
            child: const Text('Save Changes', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  InputDecoration _dialogInput(String hint) {
    return InputDecoration(
      labelText: hint,
      labelStyle: const TextStyle(color: Colors.grey, fontSize: 13),
      filled: true,
      fillColor: const Color(0xFF121B22),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121B22),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Student Directory Records'),
      ),
      body: Column(
        children: [
          // Class Tabs Selector
          Container(
            color: const Color(0xFF1F2C34),
            height: 50,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemCount: _classes.length,
              itemBuilder: (context, index) {
                final c = _classes[index];
                final isSelected = c == _selectedClassFilter;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4.0),
                  child: ChoiceChip(
                    label: Text(c, style: TextStyle(color: isSelected ? Colors.white : Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)),
                    selected: isSelected,
                    selectedColor: const Color(0xFF00A884),
                    backgroundColor: const Color(0xFF121B22),
                    onSelected: (val) => setState(() => _selectedClassFilter = c),
                  ),
                );
              },
            ),
          ),

          // Students List Stream
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('students_directory')
                  .where('class', isEqualTo: _selectedClassFilter)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator(color: Color(0xFF00A884)));
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(
                    child: Text('$_selectedClassFilter me koi student registered nahi hai.', style: const TextStyle(color: Colors.grey, fontSize: 14)),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: snapshot.data!.docs.length,
                  itemBuilder: (context, index) {
                    final doc = snapshot.data!.docs[index];
                    final student = doc.data() as Map<String, dynamic>;
                    final photoUrl = student['photoUrl'] as String?;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2C34),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundColor: const Color(0xFF121B22),
                            backgroundImage: (photoUrl != null && photoUrl.isNotEmpty) ? NetworkImage(photoUrl) : null,
                            child: (photoUrl == null || photoUrl.isEmpty) ? const Icon(Icons.person, size: 30, color: Color(0xFF00A884)) : null,
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      student['name'] ?? '',
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                                    ),
                                    const SizedBox(width: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: const Color(0xFF00A884).withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
                                      child: Text('Roll: ${student['rollNo']}', style: const TextStyle(color: Color(0xFF00A884), fontSize: 11, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text('Parent: ${student['parentName'] ?? 'N/A'}  •  Contact: ${student['parentContact'] ?? 'N/A'}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                const SizedBox(height: 2),
                                Text('Address: ${student['address'] ?? ''}, ${student['district'] ?? ''}, ${student['state'] ?? ''} - ${student['pinCode'] ?? ''}', style: const TextStyle(color: Colors.white60, fontSize: 11)),
                                const SizedBox(height: 2),
                                Text('Joining Date: ${student['joiningDate'] ?? 'N/A'}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                              ],
                            ),
                          ),
                          Column(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit, color: Colors.blueAccent, size: 20),
                                tooltip: 'Edit Student',
                                onPressed: () => _editStudent(doc.id, student),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                                tooltip: 'Delete Student',
                                onPressed: () => _deleteStudent(doc.id),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
