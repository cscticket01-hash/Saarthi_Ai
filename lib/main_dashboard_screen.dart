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
      if (_isAdminMode) {
        // Admin credentials verification
        if (idText == 'admin' && password == '123456') {
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
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Colors.redAccent,
              content: Text('Galat Admin Username ya Password!'),
            ),
          );
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
                  hintText: _isAdminMode ? 'Username' : 'Student ID / Roll No',
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

  // Student Directory controllers
  String _directoryClass = 'Class 1';
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _rollController = TextEditingController();
  final TextEditingController _parentContactController = TextEditingController();

  bool _isSavingNotice = false;
  bool _isSearchingStudent = false;
  final List<String> _classList = List.generate(10, (index) => 'Class ${index + 1}');

  // Teacher List Data (Placeholder)
  final List<Map<String, String>> _teachersList = [
    {'name': 'Ramesh Sharma', 'subject': 'Mathematics', 'phone': '+91 9876543210'},
    {'name': 'Priya Sen', 'subject': 'Bengali & English', 'phone': '+91 9876543211'},
    {'name': 'Amit Paul', 'subject': 'Science', 'phone': '+91 9876543212'},
  ];

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
        'timestamp': FieldValue.serverTimestamp(),
      });
    } else {
      await FirebaseFirestore.instance.collection('school_notices').doc(_editingNoticeId).update({
        'title': title,
        'description': desc,
        'category': _noticeCategory,
        'lastEdited': FieldValue.serverTimestamp(),
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
              const CircleAvatar(
                radius: 36,
                backgroundColor: Color(0xFF121B22),
                child: Icon(Icons.person, size: 45, color: Color(0xFF00A884)),
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
                        const SizedBox(height: 16),
                        const Divider(color: Colors.white24, height: 1),
                        const SizedBox(height: 12),
                        StreamBuilder<QuerySnapshot>(
                          stream: FirebaseFirestore.instance.collection('school_notices').orderBy('timestamp', descending: true).snapshots(),
                          builder: (context, snapshot) {
                            if (snapshot.connectionState == ConnectionState.waiting) {
                              return const Center(child: CircularProgressIndicator(color: Color(0xFF00A884)));
                            }
                            if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                              return const Text('Koi notice published nahi hai.', style: TextStyle(color: Colors.grey, fontSize: 13));
                            }
                            return ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: snapshot.data!.docs.length,
                              itemBuilder: (context, index) {
                                final doc = snapshot.data!.docs[index];
                                final data = doc.data() as Map<String, dynamic>;
                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF121B22),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '[${data['category'] ?? 'General'}] ${data['title'] ?? ''}',
                                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                            ),
                                            Text(
                                              data['description'] ?? '',
                                              style: const TextStyle(color: Colors.grey, fontSize: 12),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.edit, color: Colors.blueAccent, size: 18),
                                        onPressed: () => _startEditNotice(doc.id, data),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                                        onPressed: () => _deleteNotice(doc.id),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // --- STUDENT DIRECTORY ---
                  _buildSectionHeader('Student Directory & ID Cards', Icons.badge_outlined),
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

                  // --- RIGHT BOTTOM: STUDENT ID CARD VIEW AREA ---
                  _buildSectionHeader('Student ID Card View Area', Icons.contact_mail),
                  _buildCardWrapper(
                    child: Container(
                      height: 185,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.white12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.badge, color: Color(0xFF00A884), size: 42),
                          SizedBox(height: 8),
                          Text('Search a student on left to preview card here', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        ],
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
