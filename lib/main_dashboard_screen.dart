import 'dart:convert';
import 'dart:html' as html;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

// ============================================================
// MAIN DASHBOARD
// ============================================================
class MainDashboardScreen extends StatefulWidget {
  const MainDashboardScreen({super.key});

  @override
  State<MainDashboardScreen> createState() => _MainDashboardScreenState();
}

class _MainDashboardScreenState extends State<MainDashboardScreen> {
  int _selectedTabIndex = 0;

  final List<Widget> _pages = const [
    AiChatScreen(),
    SchoolAdminLoginScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_selectedTabIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTabIndex,
        onTap: (index) {
          setState(() {
            _selectedTabIndex = index;
          });
        },
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

// ============================================================
// CHAT SESSION MODEL
// ============================================================
class ChatSession {
  final String id;
  String title;
  final int createdAt;
  int updatedAt;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  factory ChatSession.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return ChatSession(
      id: doc.id,
      title: (data['title'] ?? 'New Chat').toString(),
      createdAt: _readInt(data['createdAt']),
      updatedAt: _readInt(data['updatedAt']),
    );
  }

  static int _readInt(dynamic value) {
    if (value is int) return value;
    if (value is Timestamp) return value.millisecondsSinceEpoch;
    if (value is num) return value.toInt();
    return 0;
  }
}

// ============================================================
// AI CHAT SCREEN
// ============================================================
class AiChatScreen extends StatefulWidget {
  const AiChatScreen({super.key});

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  bool _isLoading = false;
  bool _isSessionsLoading = true;
  String _currentSessionId = '';
  static const String _groqApiKey = String.fromEnvironment('GROQ_API_KEY');
  List<ChatSession> chatSessions = [];

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  CollectionReference<Map<String, dynamic>> _sessionsRef(String uid) {
    return FirebaseFirestore.instance.collection('users').doc(uid).collection('sessions');
  }

  CollectionReference<Map<String, dynamic>> _messagesRef(String uid, String sessionId) {
    return _sessionsRef(uid).doc(sessionId).collection('messages');
  }

  Future<void> _loadSessions() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) setState(() => _isSessionsLoading = false);
      return;
    }

    try {
      final snapshot = await _sessionsRef(user.uid).orderBy('updatedAt', descending: true).get();
      if (snapshot.docs.isEmpty) {
        await _createInitialSession(user.uid);
      } else {
        final sessions = snapshot.docs.map(ChatSession.fromDoc).toList();
        if (mounted) {
          setState(() {
            chatSessions = sessions;
            _currentSessionId = sessions.first.id;
            _isSessionsLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Load sessions error: $e');
      if (mounted) {
        setState(() => _isSessionsLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.redAccent, content: Text('Chat history load error: $e')),
        );
      }
    }
  }

  Future<void> _createInitialSession(String uid) async {
    final ref = _sessionsRef(uid).doc();
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.set({
      'title': 'First Conversation',
      'createdAt': now,
      'updatedAt': now,
    });
    final newSession = ChatSession(id: ref.id, title: 'First Conversation', createdAt: now, updatedAt: now);
    if (mounted) {
      setState(() {
        chatSessions = [newSession];
        _currentSessionId = ref.id;
        _isSessionsLoading = false;
      });
    }
  }

  Future<void> _startNewChat() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final ref = _sessionsRef(user.uid).doc();
    final now = DateTime.now().millisecondsSinceEpoch;
    await ref.set({
      'title': 'New Chat',
      'createdAt': now,
      'updatedAt': now,
    });
    final newSession = ChatSession(id: ref.id, title: 'New Chat', createdAt: now, updatedAt: now);
    if (!mounted) return;
    setState(() {
      chatSessions.insert(0, newSession);
      _currentSessionId = ref.id;
    });
    Navigator.pop(context);
  }

  Future<void> _deleteChat(int index) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || index < 0 || index >= chatSessions.length) return;
    final session = chatSessions[index];

    try {
      final messageSnapshot = await _messagesRef(user.uid, session.id).get();
      final docs = messageSnapshot.docs;
      for (int i = 0; i < docs.length; i += 400) {
        final batch = FirebaseFirestore.instance.batch();
        final end = (i + 400 < docs.length) ? i + 400 : docs.length;
        for (int j = i; j < end; j++) batch.delete(docs[j].reference);
        await batch.commit();
      }
      await _sessionsRef(user.uid).doc(session.id).delete();
      if (mounted) {
        setState(() {
          chatSessions.removeAt(index);
          if (chatSessions.isEmpty) {
            _currentSessionId = '';
          } else if (_currentSessionId == session.id) {
            _currentSessionId = chatSessions.first.id;
          }
        });
      }
      if (chatSessions.isEmpty) await _createInitialSession(user.uid);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: Colors.redAccent, content: Text('Chat delete error: $e')),
        );
      }
    }
  }

  Future<void> _updateSessionTitle(String title) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _currentSessionId.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _sessionsRef(user.uid).doc(_currentSessionId).set({'title': title, 'updatedAt': now}, SetOptions(merge: true));
    if (!mounted) return;
    final index = chatSessions.indexWhere((s) => s.id == _currentSessionId);
    if (index >= 0) {
      setState(() {
        chatSessions[index].title = title;
        chatSessions[index].updatedAt = now;
      });
    }
  }

  Future<void> _touchCurrentSession() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || _currentSessionId.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _sessionsRef(user.uid).doc(_currentSessionId).set({'updatedAt': now}, SetOptions(merge: true));
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    final user = FirebaseAuth.instance.currentUser;
    if (text.isEmpty || _isLoading || user == null || _currentSessionId.isEmpty) return;

    ChatSession currentSession = chatSessions.firstWhere(
      (session) => session.id == _currentSessionId,
      orElse: () => ChatSession(id: _currentSessionId, title: 'New Chat', createdAt: DateTime.now().millisecondsSinceEpoch, updatedAt: DateTime.now().millisecondsSinceEpoch),
    );

    String? newTitle;
    if (currentSession.title == 'First Conversation' || currentSession.title == 'New Chat') {
      newTitle = text.length > 30 ? '${text.substring(0, 30)}...' : text;
    }

    setState(() {
      _isLoading = true;
      _messageController.clear();
    });

    try {
      if (newTitle != null) await _updateSessionTitle(newTitle);
      await _messagesRef(user.uid, _currentSessionId).add({
        'sender': 'user',
        'text': text,
        'timestamp': FieldValue.serverTimestamp(),
      });
      await _touchCurrentSession();

      List<Map<String, String>> history = [];
      try {
        final historySnapshot = await _messagesRef(user.uid, _currentSessionId).orderBy('timestamp', descending: true).limit(30).get();
        final historyDocs = historySnapshot.docs.reversed.toList();
        for (final doc in historyDocs) {
          final data = doc.data();
          final sender = data['sender']?.toString();
          final messageText = data['text']?.toString();
          if (messageText == null || messageText.isEmpty) continue;
          if (sender == 'user') {
            history.add({'role': 'user', 'content': messageText});
          } else if (sender == 'ai') {
            history.add({'role': 'assistant', 'content': messageText});
          }
        }
      } catch (e) {
        debugPrint('History load for AI failed: $e');
      }

      String reply;
      if (_groqApiKey.isEmpty) {
        reply = 'Groq API key set nahi hai. Flutter run/build me GROQ_API_KEY define karein.';
      } else {
        final messages = <Map<String, dynamic>>[
          {
            'role': 'system',
            'content': 'Aap Saarthi AI hain. User se natural Hindi/Hinglish me seedhi aur useful baat karein. Formal faltu dialogue mat bolna. User ke sawal ka direct jawab dena.',
          },
          ...history,
        ];
        try {
          final response = await http.post(
            Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
            headers: {'Content-Type': 'application/json; charset=UTF-8', 'Authorization': 'Bearer $_groqApiKey'},
            body: jsonEncode({'model': 'openai/gpt-oss-120b', 'messages': messages, 'temperature': 0.7}),
          );
          if (response.statusCode == 200) {
            final data = jsonDecode(utf8.decode(response.bodyBytes));
            reply = data['choices']?[0]?['message']?['content']?.toString().trim() ?? 'AI se valid reply nahi mila.';
          } else {
            String errorText = 'Groq API error: ${response.statusCode}';
            try {
              final errorJson = jsonDecode(response.body);
              final apiMessage = errorJson['error']?['message'];
              if (apiMessage != null) errorText = 'Groq API error: ${apiMessage.toString()}';
            } catch (_) {}
            reply = errorText;
          }
        } catch (e) {
          debugPrint('Groq error: $e');
          reply = 'Network/API error. Internet check karein.';
        }
      }

      await _messagesRef(user.uid, _currentSessionId).add({
        'sender': 'ai',
        'text': reply,
        'timestamp': FieldValue.serverTimestamp(),
      });
      await _touchCurrentSession();
    } catch (e) {
      debugPrint('Send message error: $e');
      try {
        await _messagesRef(user.uid, _currentSessionId).add({
          'sender': 'ai',
          'text': 'Error aagaya hai. Dobara try karein.',
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (_) {}
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<ChatSession> get _filteredSessions {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return chatSessions;
    return chatSessions.where((session) => session.title.toLowerCase().contains(query)).toList();
  }

  void _showProfileDialog() {
    final user = FirebaseAuth.instance.currentUser;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Profile', style: TextStyle(color: Colors.white)),
        content: Text(user?.email ?? 'User', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFF00A884))),
          ),
        ],
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF1F2C34),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white12))),
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
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00A884),
                  minimumSize: const Size(double.infinity, 45),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: _isSessionsLoading ? null : _startNewChat,
                icon: const Icon(Icons.add, color: Colors.white),
                label: const Text('New Chat', style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search chats...',
                  hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                  prefixIcon: const Icon(Icons.search, color: Colors.grey, size: 18),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.grey, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {});
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFF2A3942),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                ),
              ),
            ),
            const Divider(color: Colors.white24, height: 1),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text('Recents', style: TextStyle(color: Colors.grey, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: _isSessionsLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF00A884)))
                  : ListView.builder(
                      itemCount: _filteredSessions.length,
                      itemBuilder: (context, index) {
                        final session = _filteredSessions[index];
                        final realIndex = chatSessions.indexWhere((s) => s.id == session.id);
                        final isSelected = session.id == _currentSessionId;
                        return ListTile(
                          selected: isSelected,
                          selectedTileColor: Colors.white.withOpacity(0.08),
                          leading: const Icon(Icons.chat_bubble_outline, color: Colors.white70, size: 18),
                          title: Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                            onPressed: realIndex >= 0 ? () => _deleteChat(realIndex) : null,
                          ),
                          onTap: () {
                            setState(() { _currentSessionId = session.id; });
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
            ),
            const Divider(color: Colors.white24, height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    tileColor: Colors.white.withOpacity(0.04),
                    leading: const Icon(Icons.person_outline, color: Colors.white70),
                    title: const Text('Profile', style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(context);
                      _showProfileDialog();
                    },
                  ),
                  const SizedBox(height: 4),
                  ListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    tileColor: Colors.redAccent.withOpacity(0.1),
                    leading: const Icon(Icons.logout, color: Colors.redAccent),
                    title: const Text('Logout', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                    onTap: () async {
                      await FirebaseAuth.instance.signOut();
                      if (mounted) Navigator.pop(context);
                    },
                  ),
                ],
              ),
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
        backgroundColor: const Color(0xFF1F2C34),
        title: const Row(
          children: [
            Icon(Icons.smart_toy_rounded, color: Color(0xFF00E676)),
            SizedBox(width: 10),
            Text('Saarthi AI', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<User?>(
              stream: FirebaseAuth.instance.authStateChanges(),
              builder: (context, authSnapshot) {
                final user = authSnapshot.data;
                if (user == null) {
                  return const Center(child: Text('Kripya Login karein', style: TextStyle(color: Colors.grey)));
                }
                if (_currentSessionId.isEmpty) {
                  return const Center(child: Text('Nayi chat shuru karein!', style: TextStyle(color: Colors.grey)));
                }
                return StreamBuilder<QuerySnapshot>(
                  stream: _messagesRef(user.uid, _currentSessionId).snapshots(),
                  builder: (context, chatSnapshot) {
                    if (chatSnapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator(color: Color(0xFF00A884)));
                    }
                    if (!chatSnapshot.hasData || chatSnapshot.data!.docs.isEmpty) {
                      return const Center(child: Text('Nayi chat shuru karein!', style: TextStyle(color: Colors.grey)));
                    }
                    final docs = chatSnapshot.data!.docs.toList();
                    docs.sort((a, b) {
                      final aData = a.data() as Map<String, dynamic>;
                      final bData = b.data() as Map<String, dynamic>;
                      final aTime = aData['timestamp'];
                      final bTime = bData['timestamp'];
                      if (aTime is Timestamp && bTime is Timestamp) return aTime.compareTo(bTime);
                      if (aTime is Timestamp) return -1;
                      if (bTime is Timestamp) return 1;
                      return 0;
                    });
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (_scrollController.hasClients) {
                        _scrollController.animateTo(
                          _scrollController.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOut,
                        );
                      }
                    });
                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: docs.length + (_isLoading ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (_isLoading && index == docs.length) {
                          return Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(color: const Color(0xFF202C33), borderRadius: BorderRadius.circular(10)),
                              child: const Text('AI typing...', style: TextStyle(color: Colors.white70)),
                            ),
                          );
                        }
                        final message = docs[index].data() as Map<String, dynamic>;
                        final isUser = message['sender'] == 'user';
                        return Align(
                          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: isUser ? const Color(0xFF005C4B) : const Color(0xFF202C33),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                            child: SelectableText(
                              message['text']?.toString() ?? '',
                              style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
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
                    minLines: 1,
                    maxLines: 5,
                    onSubmitted: (_) { if (!_isLoading) _sendMessage(); },
                    decoration: InputDecoration(
                      hintText: 'Message...',
                      hintStyle: const TextStyle(color: Colors.grey),
                      filled: true,
                      fillColor: const Color(0xFF2A3942),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: const Color(0xFF00A884),
                  child: _isLoading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : IconButton(icon: const Icon(Icons.send, color: Colors.white, size: 20), onPressed: _sendMessage),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// SCHOOL ADMIN / STUDENT LOGIN
// ============================================================
class SchoolAdminLoginScreen extends StatefulWidget {
  const SchoolAdminLoginScreen({super.key});

  @override
  State<SchoolAdminLoginScreen> createState() => _SchoolAdminLoginScreenState();
}

class _SchoolAdminLoginScreenState extends State<SchoolAdminLoginScreen> {
  bool _isAdminMode = true;
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoggingIn = false;
  String _selectedClass = 'Class 1';

  final List<String> _classList = List.generate(10, (index) => 'Class ${index + 1}');

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _switchRole(bool isAdmin) {
    setState(() {
      _isAdminMode = isAdmin;
      _usernameController.clear();
      _passwordController.clear();
    });
  }

  String _normalizeDob(String value) {
    final cleaned = value.trim().replaceAll('-', '/').replaceAll('.', '/').replaceAll(RegExp(r'\s+'), '');
    final parts = cleaned.split('/');
    if (parts.length != 3) return '';
    final day = parts[0].padLeft(2, '0');
    final month = parts[1].padLeft(2, '0');
    final year = parts[2];
    if (year.length != 4) return '';
    return '$day/$month/$year';
  }

  Future<void> _handleLogin() async {
    final idText = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (idText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text(_isAdminMode ? 'Admin Email bharein.' : 'Student Roll No bharein.')));
      return;
    }

    if (password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Password / Date of Birth bharein.')));
      return;
    }

    setState(() => _isLoggingIn = true);

    try {
      if (_isAdminMode) {
        await FirebaseAuth.instance.signInWithEmailAndPassword(email: idText, password: password);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Admin Login Safal hua!')));
        Navigator.push(context, MaterialPageRoute(builder: (context) => const AdminDashboardScreen()));
        return;
      }

      final studentRoll = idText;
      final docId = '${_selectedClass}_Roll_$studentRoll';
      final studentDoc = await FirebaseFirestore.instance.collection('students_directory').doc(docId).get();

      if (!studentDoc.exists) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Student record nahi mila! Class aur Roll No check karein.')));
        return;
      }

      final studentData = studentDoc.data() as Map<String, dynamic>;
      final storedDob = studentData['dateOfBirth']?.toString().trim() ?? '';

      if (storedDob.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.orangeAccent, content: Text('Is student ka Date of Birth database mein set nahi hai.')));
        return;
      }

      final enteredPassword = password.replaceAll(RegExp(r'[\s-]'), '/');
      final normalizedStoredDob = _normalizeDob(storedDob);
      final normalizedEnteredDob = _normalizeDob(enteredPassword);

      final passwordMatched = normalizedStoredDob.isNotEmpty && normalizedEnteredDob.isNotEmpty && normalizedStoredDob == normalizedEnteredDob;

      if (!passwordMatched && password != '123456') { // Fallback password just in case
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Galat Password! Apna Date of Birth sahi format mein enter karein.')));
        return;
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Student Login Safal hua!')));
      Navigator.push(context, MaterialPageRoute(builder: (context) => StudentPortalScreen(studentId: studentRoll, studentClass: _selectedClass)));

    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      String errorMessage = 'Login details galat hain.';
      switch (e.code) {
        case 'user-not-found': errorMessage = 'Yeh Admin account registered nahi hai.'; break;
        case 'wrong-password':
        case 'invalid-credential': errorMessage = 'Galat Admin Email ya Password.'; break;
        case 'invalid-email': errorMessage = 'Invalid Admin Email.'; break;
        case 'user-disabled': errorMessage = 'Admin account disabled hai.'; break;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text(errorMessage)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Login error: $e')));
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
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              children: [
                Icon(
                  _isAdminMode ? Icons.admin_panel_settings_rounded : Icons.school_rounded,
                  size: 65,
                  color: const Color(0xFF00A884),
                ),
                const SizedBox(height: 12),
                Text(
                  _isAdminMode ? 'ADMIN LOGIN' : 'STUDENT LOGIN',
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: const Color(0xFF1F2C34), borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () => _switchRole(true),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(color: _isAdminMode ? const Color(0xFF00A884) : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.security, size: 16, color: Colors.white),
                                SizedBox(width: 6),
                                Text('Admin', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                            decoration: BoxDecoration(color: !_isAdminMode ? const Color(0xFF00A884) : Colors.transparent, borderRadius: BorderRadius.circular(10)),
                            child: const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.person, size: 16, color: Colors.white),
                                SizedBox(width: 6),
                                Text('Student', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                  DropdownButtonFormField<String>(
                    value: _selectedClass,
                    dropdownColor: const Color(0xFF1F2C34),
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Class'),
                    items: _classList.map((value) => DropdownMenuItem<String>(value: value, child: Text(value))).toList(),
                    onChanged: (value) {
                      if (value != null) setState(() => _selectedClass = value);
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _usernameController,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration(
                    _isAdminMode ? 'Admin Email' : 'Student ID / Roll No',
                    icon: _isAdminMode ? Icons.person_outline : Icons.badge_outlined,
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration(
                    _isAdminMode ? 'Password' : 'Date of Birth (DD/MM/YYYY)',
                    icon: Icons.lock_outline,
                    suffixIcon: IconButton(
                      icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: Colors.grey),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00A884),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _isLoggingIn ? null : _handleLogin,
                    child: _isLoggingIn
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : Text(
                            _isAdminMode ? 'LOGIN AS ADMIN' : 'LOGIN AS STUDENT',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint, {IconData? icon, Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
      prefixIcon: icon == null ? null : Icon(icon, color: const Color(0xFF00A884)),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: const Color(0xFF1F2C34),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    );
  }
}

// ============================================================
// STUDENT PORTAL SCREEN
// ============================================================
class StudentPortalScreen extends StatefulWidget {
  final String studentId;
  final String studentClass;

  const StudentPortalScreen({
    super.key,
    required this.studentId,
    required this.studentClass,
  });

  @override
  State<StudentPortalScreen> createState() => _StudentPortalScreenState();
}

class _StudentPortalScreenState extends State<StudentPortalScreen> {
  Map<String, dynamic>? studentData;
  bool isLoadingProfile = true;
  String? profileError;

  @override
  void initState() {
    super.initState();
    _fetchStudentProfile();
  }

  Future<void> _fetchStudentProfile() async {
    try {
      final docId = '${widget.studentClass}_Roll_${widget.studentId}';
      final doc = await FirebaseFirestore.instance.collection('students_directory').doc(docId).get();
      if (!mounted) return;
      if (doc.exists) {
        setState(() {
          studentData = doc.data();
          isLoadingProfile = false;
          profileError = null;
        });
      } else {
        setState(() {
          studentData = null;
          isLoadingProfile = false;
          profileError = 'Student profile nahi mila.';
        });
      }
    } catch (e) {
      debugPrint('Profile load error: $e');
      if (!mounted) return;
      setState(() {
        isLoadingProfile = false;
        profileError = 'Profile load nahi ho paya.';
      });
    }
  }

  Color _categoryColor(String category) {
    switch (category.toLowerCase()) {
      case 'holiday': return Colors.orangeAccent;
      case 'exam': return Colors.redAccent;
      case 'event': return Colors.blueAccent;
      case 'general':
      default: return const Color(0xFF00A884);
    }
  }

  IconData _categoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'holiday': return Icons.beach_access_rounded;
      case 'exam': return Icons.menu_book_rounded;
      case 'event': return Icons.event_rounded;
      case 'general':
      default: return Icons.campaign_rounded;
    }
  }

  String _formatTimestamp(dynamic timestamp) {
    if (timestamp is Timestamp) {
      final date = timestamp.toDate();
      final day = date.day.toString().padLeft(2, '0');
      final month = date.month.toString().padLeft(2, '0');
      final year = date.year.toString();
      return '$day/$month/$year';
    }
    return '';
  }

  String _studentInitial(String? value) {
    if (value == null || value.trim().isEmpty) return 'S';
    return value.trim().substring(0, 1).toUpperCase();
  }

  Future<void> _updateMobileNumber(String newMobile) async {
    final mobile = newMobile.trim();
    if (mobile.isEmpty) throw Exception('Mobile number bharna zaroori hai.');
    if (!RegExp(r'^[0-9]{10}$').hasMatch(mobile)) throw Exception('10 digit mobile number daalein.');

    final docId = '${widget.studentClass}_Roll_${widget.studentId}';
    await FirebaseFirestore.instance.collection('students_directory').doc(docId).update({
      'parentContact': mobile,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  void _showMobileUpdateDialog() {
    final mobileController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        bool isSaving = false;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F2C34),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.phone_android_rounded, color: Color(0xFF00A884)),
                  SizedBox(width: 10),
                  Text('Update Mobile Number', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                ],
              ),
              content: TextField(
                controller: mobileController,
                keyboardType: TextInputType.phone,
                maxLength: 10,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Enter 10 digit mobile number',
                  hintStyle: const TextStyle(color: Colors.grey),
                  prefixIcon: const Icon(Icons.phone_outlined, color: Color(0xFF00A884)),
                  filled: true,
                  fillColor: const Color(0xFF121B22),
                  counterStyle: const TextStyle(color: Colors.grey),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(ctx),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
                  onPressed: isSaving
                      ? null
                      : () async {
                          setDialogState(() => isSaving = true);
                          try {
                            await _updateMobileNumber(mobileController.text);
                            if (!mounted) return;
                            Navigator.pop(ctx);
                            _fetchStudentProfile();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Mobile number successfully update ho gaya!')),
                            );
                          } catch (e) {
                            setDialogState(() => isSaving = false);
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Update error: $e')));
                          }
                        },
                  child: isSaving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildProfileTop() {
    final photoUrl = studentData?['photoUrl']?.toString().trim() ?? '';
    final studentName = studentData?['name']?.toString().trim().isNotEmpty == true ? studentData!['name'].toString().trim() : 'Student Profile';
    final studentInitial = _studentInitial(studentName);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 24, 18, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF193A38), Color(0xFF172229)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.only(topLeft: Radius.circular(20), topRight: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              Container(
                width: 108,
                height: 108,
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF00A884), width: 2),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF00A884).withOpacity(0.18), blurRadius: 22, spreadRadius: 2),
                  ],
                ),
                child: ClipOval(
                  child: isLoadingProfile
                      ? const ColoredBox(
                          color: Color(0xFF0F171D),
                          child: Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF00A884)))),
                        )
                      : photoUrl.isNotEmpty
                          ? Image.network(
                              photoUrl,
                              fit: BoxFit.cover,
                              webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                              errorBuilder: (context, error, stackTrace) {
                                return ColoredBox(
                                  color: const Color(0xFF0F171D),
                                  child: Center(child: Text(studentInitial, style: const TextStyle(color: Color(0xFF00A884), fontSize: 38, fontWeight: FontWeight.bold))),
                                );
                              },
                            )
                          : ColoredBox(
                              color: const Color(0xFF0F171D),
                              child: Center(child: Text(studentInitial, style: const TextStyle(color: Color(0xFF00A884), fontSize: 38, fontWeight: FontWeight.bold))),
                            ),
                ),
              ),
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(color: const Color(0xFF00A884), shape: BoxShape.circle, border: Border.all(color: const Color(0xFF172229), width: 3)),
                child: const Icon(Icons.check_rounded, size: 15, color: Colors.white),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(studentName, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          const Text('Saraswati Vidya Niketan', style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 13),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: const Color(0xFF00A884).withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFF00A884).withOpacity(0.28)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.verified_rounded, color: Color(0xFF00A884), size: 15),
                SizedBox(width: 6),
                Text('Active / Enrolled', style: TextStyle(color: Color(0xFF00A884), fontSize: 11, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileDetails() {
    if (isLoadingProfile) {
      return const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator(color: Color(0xFF00A884))));
    }
    if (studentData == null) {
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Icon(Icons.person_off_outlined, color: Colors.white38, size: 38),
            const SizedBox(height: 10),
            Text(profileError ?? 'Profile unavailable', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _fetchStudentProfile,
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF00A884), side: const BorderSide(color: Color(0xFF00A884))),
              icon: const Icon(Icons.refresh_rounded, size: 17),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final parentName = studentData?['parentName']?.toString().trim() ?? 'N/A';
    final dob = studentData?['dateOfBirth']?.toString().trim() ?? 'N/A';
    final contact = studentData?['parentContact']?.toString().trim() ?? 'N/A';
    final address = studentData?['address']?.toString().trim() ?? '';
    final district = studentData?['district']?.toString().trim() ?? '';
    final state = studentData?['state']?.toString().trim() ?? '';
    final pinCode = studentData?['pinCode']?.toString().trim() ?? '';
    final hostel = studentData?['hostelFacility']?.toString().trim() ?? 'No';

    String fullAddress = [address, district, state].where((e) => e.isNotEmpty).join(', ');
    if (pinCode.isNotEmpty) fullAddress = fullAddress.isEmpty ? pinCode : '$fullAddress - $pinCode';
    if (fullAddress.isEmpty) fullAddress = 'Not Available';

    return Column(
      children: [
        _profileInfoTile(icon: Icons.badge_outlined, label: 'Student ID / Roll', value: widget.studentId),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.school_outlined, label: 'Assigned Class', value: widget.studentClass),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.person_outline_rounded, label: "Father's / Guardian Name", value: parentName.isEmpty ? 'N/A' : parentName),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.cake_outlined, label: 'Date of Birth', value: dob.isEmpty ? 'N/A' : dob),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.phone_outlined, label: 'Contact Number', value: contact.isEmpty ? 'N/A' : contact),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.home_outlined, label: 'Address', value: fullAddress),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.hotel_outlined, label: 'Hostel Facility', value: hostel.isEmpty ? 'No' : hostel),
        const SizedBox(height: 9),
        _profileInfoTile(icon: Icons.verified_user_outlined, label: 'Status', value: 'Active', valueColor: const Color(0xFF00A884)),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _showMobileUpdateDialog,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFF00A884)),
              foregroundColor: const Color(0xFF00A884),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            icon: const Icon(Icons.phone_android_rounded, size: 18),
            label: const Text('Update Mobile Number', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(color: const Color(0xFF0F171D), borderRadius: BorderRadius.circular(13), border: Border.all(color: Colors.white.withOpacity(0.05))),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline_rounded, color: Colors.white38, size: 17),
              SizedBox(width: 9),
              Expanded(
                child: Text(
                  'Profile details school database se linked hain. Student sirf apna mobile number update kar sakta hai.',
                  style: TextStyle(color: Colors.white54, fontSize: 11.5, height: 1.45),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _profileInfoTile({required IconData icon, required String label, required String value, Color valueColor = Colors.white}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1D2A31),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.035)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 35,
            height: 35,
            decoration: BoxDecoration(color: const Color(0xFF0F171D), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, color: const Color(0xFF00A884), size: 18),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: Colors.white38, fontSize: 9.5)),
                const SizedBox(height: 3),
                Text(value, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: valueColor, fontSize: 12.5, fontWeight: FontWeight.w700, height: 1.25)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeBoard(BuildContext context, {double? height}) {
    return Container(
      width: double.infinity,
      height: height,
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 25, offset: const Offset(0, 10))],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('school_notices').snapshots(),
              builder: (context, snapshot) {
                final count = snapshot.hasData ? snapshot.data!.docs.length : 0;
                return Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(color: const Color(0xFF00A884).withOpacity(0.13), borderRadius: BorderRadius.circular(12)),
                      child: const Icon(Icons.campaign_rounded, color: Color(0xFF00A884), size: 21),
                    ),
                    const SizedBox(width: 11),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('School Notice Board', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                          SizedBox(height: 2),
                          Text('Latest announcements & updates', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F171D),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white.withOpacity(0.05)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.notifications_none_rounded, color: Colors.white54, size: 15),
                          const SizedBox(width: 5),
                          Text('$count', style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 15),
            Container(height: 1, color: Colors.white.withOpacity(0.06)),
            const SizedBox(height: 14),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('school_notices').orderBy('timestamp', descending: true).snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: Color(0xFF00A884), strokeWidth: 2.5));
                  if (snapshot.hasError) return Center(child: _emptyNoticeState(icon: Icons.error_outline_rounded, title: 'Notice load nahi ho paya', subtitle: 'Internet ya Firebase check karein.'));
                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return Center(child: _emptyNoticeState(icon: Icons.notifications_none_rounded, title: 'Abhi koi notice nahi hai', subtitle: 'School jab notice publish karega, yahan dikhega.'));
                  final docs = snapshot.data!.docs;
                  return ListView.builder(
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: docs.length,
                    itemBuilder: (context, index) {
                      final notice = docs[index].data() as Map<String, dynamic>;
                      return _buildNoticeCard(
                        title: notice['title']?.toString() ?? 'Notice',
                        description: notice['description']?.toString() ?? '',
                        category: notice['category']?.toString() ?? 'General',
                        date: _formatTimestamp(notice['timestamp']),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoticeCard({required String title, required String description, required String category, required String date}) {
    final accent = _categoryColor(category);
    final categoryIcon = _categoryIcon(category);
    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF10181E), borderRadius: BorderRadius.circular(15), border: Border.all(color: Colors.white.withOpacity(0.055))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: accent.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
            child: Icon(categoryIcon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 7,
                  runSpacing: 5,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: accent.withOpacity(0.11), borderRadius: BorderRadius.circular(20)),
                      child: Text(category, style: TextStyle(color: accent, fontSize: 9.5, fontWeight: FontWeight.w800)),
                    ),
                    if (date.isNotEmpty)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.calendar_today_rounded, size: 11, color: Colors.white30),
                          const SizedBox(width: 4),
                          Text(date, style: const TextStyle(color: Colors.white30, fontSize: 9.5)),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700, height: 1.25)),
                if (description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(description, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60, fontSize: 11.5, height: 1.45)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyNoticeState({required IconData icon, required String title, required String subtitle}) {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(color: const Color(0xFF00A884).withOpacity(0.08), shape: BoxShape.circle),
            child: Icon(icon, color: const Color(0xFF00A884), size: 30),
          ),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white30, fontSize: 11, height: 1.4)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F171D),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF172229),
        titleSpacing: 18,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.15),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: const Color(0xFF00A884).withOpacity(0.35)),
              ),
              child: const Icon(Icons.school_rounded, color: Color(0xFF00A884), size: 21),
            ),
            const SizedBox(width: 11),
            const Expanded(
              child: Text('Student Portal', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700, letterSpacing: 0.2)),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Logout',
            icon: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: Colors.redAccent.withOpacity(0.10), borderRadius: BorderRadius.circular(11)),
              child: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 19),
            ),
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isMobile = constraints.maxWidth < 800;
          if (isMobile) {
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
              child: Column(
                children: [
                  _buildMobileProfileCard(),
                  const SizedBox(height: 14),
                  _buildNoticeBoard(context, height: null),
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 330, child: SingleChildScrollView(child: _buildDesktopProfileCard())),
                const SizedBox(width: 18),
                Expanded(child: _buildNoticeBoard(context, height: constraints.maxHeight - 36)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildDesktopProfileCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.20), blurRadius: 25, offset: const Offset(0, 10))],
      ),
      child: Column(
        children: [
          _buildProfileTop(),
          Padding(padding: const EdgeInsets.all(18), child: _buildProfileDetails()),
        ],
      ),
    );
  }

  Widget _buildMobileProfileCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF172229),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.07)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 22, offset: const Offset(0, 9))],
      ),
      child: Column(
        children: [
          _buildProfileTop(),
          Padding(padding: const EdgeInsets.all(16), child: _buildProfileDetails()),
        ],
      ),
    );
  }
}

// ============================================================
// ADMIN DASHBOARD
// ============================================================
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final TextEditingController _noticeTitleController = TextEditingController();
  final TextEditingController _noticeDescController = TextEditingController();
  String _noticeCategory = 'Holiday';
  final List<String> _noticeCategories = ['Holiday', 'Exam', 'Event', 'General'];
  String? _editingNoticeId;
  bool _isSavingNotice = false;

  String _directoryClass = 'Class 1';
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _rollController = TextEditingController();
  final TextEditingController _parentContactController = TextEditingController();
  String? _studentPhotoUrl;
  bool _isSearchingStudent = false;

  final List<String> _classList = List.generate(10, (index) => 'Class ${index + 1}');

  final List<Map<String, String>> _teachersList = [
    {'name': 'Ramesh Sharma', 'subject': 'Mathematics', 'phone': '+91 9876543210'},
    {'name': 'Priya Sen', 'subject': 'Bengali & English', 'phone': '+91 9876543211'},
    {'name': 'Amit Paul', 'subject': 'Science', 'phone': '+91 9876543212'},
  ];

  @override
  void dispose() {
    _noticeTitleController.dispose();
    _noticeDescController.dispose();
    _nameController.dispose();
    _rollController.dispose();
    _parentContactController.dispose();
    super.dispose();
  }

  void _openAddStudentDialog() {
    final nameCtrl = TextEditingController();
    final parentCtrl = TextEditingController();
    final rollCtrl = TextEditingController();
    final contactCtrl = TextEditingController();
    final addressCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    final stateCtrl = TextEditingController();
    final districtCtrl = TextEditingController();
    final admissionDateCtrl = TextEditingController(text: '${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}');
    final dobCtrl = TextEditingController();
    String selectedClass = _directoryClass;
    String hostelFacility = 'No';
    List<int>? selectedPhotoBytes;
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: !isSaving,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDlgState) {
            return AlertDialog(
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
                width: 520,
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
                              items: _classList.map((value) => DropdownMenuItem<String>(value: value, child: Text(value))).toList(),
                              onChanged: (value) {
                                if (value != null) setDlgState(() => selectedClass = value);
                              },
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
                      TextField(controller: nameCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Student Full Name *')),
                      const SizedBox(height: 10),
                      TextField(controller: parentCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration("Parent's / Guardian Name *")),
                      const SizedBox(height: 10),
                      TextField(controller: contactCtrl, keyboardType: TextInputType.phone, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Contact No *')),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: hostelFacility,
                        dropdownColor: const Color(0xFF1F2C34),
                        style: const TextStyle(color: Colors.white),
                        decoration: _inputDecoration('Hostel Facility'),
                        items: const [
                          DropdownMenuItem(value: 'No', child: Text('Hostel Facility: No')),
                          DropdownMenuItem(value: 'Yes', child: Text('Hostel Facility: Yes')),
                        ],
                        onChanged: (value) {
                          if (value != null) setDlgState(() => hostelFacility = value);
                        },
                      ),
                      const SizedBox(height: 10),
                      TextField(controller: addressCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Address')),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: TextField(controller: districtCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('District'))),
                          const SizedBox(width: 10),
                          Expanded(child: TextField(controller: stateCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('State'))),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: TextField(controller: pinCtrl, keyboardType: TextInputType.number, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('PIN Code'))),
                          const SizedBox(width: 10),
                          Expanded(child: TextField(controller: admissionDateCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Admission Date'))),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(controller: dobCtrl, style: const TextStyle(color: Colors.white), decoration: _inputDecoration('Date of Birth (DD/MM/YYYY)')),
                    ],
                  ),
                ),
              ),
              actions: [
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(side: BorderSide(color: selectedPhotoBytes != null ? const Color(0xFF00A884) : Colors.grey)),
                  onPressed: isSaving ? null : () async {
                    final picker = ImagePicker();
                    final image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
                    if (image == null) return;
                    final bytes = await image.readAsBytes();
                    setDlgState(() => selectedPhotoBytes = bytes);
                  },
                  icon: Icon(selectedPhotoBytes != null ? Icons.check_circle : Icons.add_a_photo_outlined, color: selectedPhotoBytes != null ? const Color(0xFF00A884) : Colors.white70),
                  label: Text(selectedPhotoBytes != null ? 'Photo Ready' : 'Upload Photo', style: TextStyle(color: selectedPhotoBytes != null ? const Color(0xFF00A884) : Colors.white70)),
                ),
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(dialogContext),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
                  onPressed: isSaving ? null : () async {
                    final name = nameCtrl.text.trim();
                    final parent = parentCtrl.text.trim();
                    final roll = rollCtrl.text.trim();
                    final contact = contactCtrl.text.trim();
                    if (name.isEmpty || roll.isEmpty || contact.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Name, Roll No aur Contact bharna zaroori hai!')));
                      return;
                    }

                    setDlgState(() => isSaving = true);
                    final docId = '${selectedClass}_Roll_$roll';
                    String finalPhotoUrl = '';
                    bool driveSaved = false;

                    try {
                      final configDoc = await FirebaseFirestore.instance.collection('school_config').doc('google_drive_account').get();
                      final scriptUrl = configDoc.data()?['scriptUrl']?.toString().trim();

                      if (scriptUrl != null && scriptUrl.isNotEmpty) {
                        try {
                          final base64Image = selectedPhotoBytes != null ? base64Encode(selectedPhotoBytes!) : '';
                          final response = await http.post(
                            Uri.parse(scriptUrl),
                            headers: {'Content-Type': 'text/plain;charset=utf-8'},
                            body: jsonEncode({
                              'action': 'add_student',
                              'name': name,
                              'parentName': parent,
                              'studentClass': selectedClass,
                              'roll': roll,
                              'contact': contact,
                              'photoBase64': base64Image,
                              'hostelFacility': hostelFacility,
                              'address': addressCtrl.text.trim(),
                              'district': districtCtrl.text.trim(),
                              'state': stateCtrl.text.trim(),
                              'pinCode': pinCtrl.text.trim(),
                              'joiningDate': admissionDateCtrl.text.trim(),
                              'dateOfBirth': dobCtrl.text.trim(),
                            }),
                          );
                          if (response.statusCode == 200) {
                            final responseJson = jsonDecode(response.body);
                            driveSaved = responseJson['success'] != false;
                            if (responseJson['photoUrl'] != null) finalPhotoUrl = responseJson['photoUrl'].toString();
                          }
                        } catch (e) {
                          debugPrint('Drive error: $e');
                        }
                      }

                      await FirebaseFirestore.instance.collection('students_directory').doc(docId).set({
                        'name': name,
                        'parentName': parent,
                        'class': selectedClass,
                        'rollNo': roll,
                        'parentContact': contact,
                        'photoUrl': finalPhotoUrl,
                        'hostelFacility': hostelFacility,
                        'address': addressCtrl.text.trim(),
                        'pinCode': pinCtrl.text.trim(),
                        'district': districtCtrl.text.trim(),
                        'state': stateCtrl.text.trim(),
                        'joiningDate': admissionDateCtrl.text.trim(),
                        'dateOfBirth': dobCtrl.text.trim(),
                        'createdAt': FieldValue.serverTimestamp(),
                        'updatedAt': FieldValue.serverTimestamp(),
                      });

                      if (!mounted) return;
                      Navigator.pop(dialogContext);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: driveSaved ? const Color(0xFF00A884) : Colors.orangeAccent,
                          content: Text(driveSaved ? 'Student aur Photo Google Drive par save ho gaye.' : 'Student Firestore me save hua, Google Drive nahi.'),
                        ),
                      );
                    } catch (e) {
                      setDlgState(() => isSaving = false);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Student save error: $e')));
                    }
                  },
                  child: Text(isSaving ? 'Saving...' : 'Save Student', style: const TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _saveNotice() async {
    final title = _noticeTitleController.text.trim();
    final description = _noticeDescController.text.trim();
    if (title.isEmpty || description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Title aur details bharna zaroori hai.')));
      return;
    }
    setState(() => _isSavingNotice = true);
    try {
      if (_editingNoticeId == null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        await FirebaseFirestore.instance.collection('school_notices').add({
          'title': title, 'description': description, 'category': _noticeCategory, 'timestamp': now, 'lastEdited': now,
        });
      } else {
        await FirebaseFirestore.instance.collection('school_notices').doc(_editingNoticeId).update({
          'title': title, 'description': description, 'category': _noticeCategory, 'lastEdited': DateTime.now().millisecondsSinceEpoch,
        });
      }
      if (!mounted) return;
      _cancelNoticeEdit();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Notice successfully saved!')));
    } catch (e) {
      if (mounted) {
        setState(() => _isSavingNotice = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Notice save error: $e')));
      }
    }
  }

  void _startEditNotice(String id, Map<String, dynamic> data) {
    setState(() {
      _editingNoticeId = id;
      _noticeTitleController.text = data['title']?.toString() ?? '';
      _noticeDescController.text = data['description']?.toString() ?? '';
      final category = data['category']?.toString();
      _noticeCategory = _noticeCategories.contains(category) ? category! : 'General';
    });
  }

  void _cancelNoticeEdit() {
    setState(() {
      _editingNoticeId = null;
      _noticeTitleController.clear();
      _noticeDescController.clear();
      _noticeCategory = 'Holiday';
      _isSavingNotice = false;
    });
  }

  Future<void> _deleteNotice(String id) async {
    try {
      await FirebaseFirestore.instance.collection('school_notices').doc(id).delete();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Notice delete ho gaya!')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Delete error: $e')));
    }
  }

  Future<void> _searchStudent() async {
    final roll = _rollController.text.trim();
    if (roll.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kripya Roll Number bharein')));
      return;
    }
    setState(() => _isSearchingStudent = true);
    try {
      final docId = '${_directoryClass}_Roll_$roll';
      final doc = await FirebaseFirestore.instance.collection('students_directory').doc(docId).get();
      if (doc.exists) {
        final data = doc.data()!;
        _nameController.text = data['name']?.toString() ?? '';
        _parentContactController.text = data['parentContact']?.toString() ?? '';
        _studentPhotoUrl = data['photoUrl']?.toString();
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Student mil gaya!')));
      } else {
        _nameController.clear();
        _parentContactController.clear();
        _studentPhotoUrl = null;
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Is Roll No ka koi student nahi mila!')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Search error: $e')));
    } finally {
      if (mounted) setState(() => _isSearchingStudent = false);
    }
  }

  void _openAddTeacherDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Add Teacher', style: TextStyle(color: Colors.white)),
        content: const Text('Teacher database fields baad mein connect kiye ja sakte hain.', style: TextStyle(color: Colors.grey)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close', style: TextStyle(color: Color(0xFF00A884)))),
        ],
      ),
    );
  }

  void _showProfileDialog() {
    final user = FirebaseAuth.instance.currentUser;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: const Text('Admin Profile', style: TextStyle(color: Colors.white)),
        content: Text(user?.email ?? 'Admin', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close', style: TextStyle(color: Color(0xFF00A884)))),
        ],
      ),
    );
  }

  Future<void> _showIdCardPreview() async {
    final name = _nameController.text.trim().isEmpty ? 'Student Name' : _nameController.text.trim();
    final roll = _rollController.text.trim().isEmpty ? '01' : _rollController.text.trim();
    final contact = _parentContactController.text.trim().isEmpty ? 'Not Available' : _parentContactController.text.trim();

    String parentName = 'N/A';
    String address = 'N/A';
    String district = '';
    String state = '';
    String pinCode = '';
    String admissionDate = 'N/A';
    String dob = 'N/A';
    String? fetchedPhotoUrl = _studentPhotoUrl;

    try {
      final docId = '${_directoryClass}_Roll_$roll';
      final doc = await FirebaseFirestore.instance.collection('students_directory').doc(docId).get();
      if (doc.exists) {
        final data = doc.data()!;
        parentName = data['parentName']?.toString() ?? 'N/A';
        address = data['address']?.toString() ?? 'N/A';
        district = data['district']?.toString() ?? '';
        state = data['state']?.toString() ?? '';
        pinCode = data['pinCode']?.toString() ?? '';
        admissionDate = data['joiningDate']?.toString() ?? 'N/A';
        dob = data['dateOfBirth']?.toString() ?? 'N/A';
        final dbPhoto = data['photoUrl']?.toString();
        if (dbPhoto != null && dbPhoto.isNotEmpty) fetchedPhotoUrl = dbPhoto;
      }
    } catch (e) {
      debugPrint('ID card fetch error: $e');
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 370,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: const BoxDecoration(
                  color: Color(0xFFC85A17),
                  borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
                ),
                child: const Row(
                  children: [
                    CircleAvatar(radius: 18, backgroundColor: Colors.white, child: Icon(Icons.school, color: Color(0xFFC85A17), size: 20)),
                    SizedBox(width: 8),
                    Expanded(child: Text('SARASWATI VIDYA NIKETAN, MADHABDHAM', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold))),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: 85,
                height: 100,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFC85A17), width: 2),
                  color: const Color(0xFFECEFF1),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: fetchedPhotoUrl != null && fetchedPhotoUrl!.isNotEmpty
                      ? Image.network(
                          fetchedPhotoUrl!,
                          fit: BoxFit.cover,
                          webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                          errorBuilder: (context, error, stackTrace) => const Icon(Icons.person, size: 45, color: Colors.grey),
                        )
                      : const Icon(Icons.person, size: 45, color: Colors.grey),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                decoration: BoxDecoration(color: const Color(0xFFC85A17), borderRadius: BorderRadius.circular(6)),
                child: const Text('STUDENT ID CARD', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  children: [
                    _idCardField('Name', name),
                    _idCardField('Father Name', parentName),
                    _idCardField('Class', _directoryClass),
                    _idCardField('Roll No', roll),
                    _idCardField('Contact', contact),
                    _idCardField('DOB', dob),
                    _idCardField('Admission', admissionDate),
                    _idCardField('Address', '$address, $district, $state - $pinCode'),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(width: 70, child: Divider(color: Colors.black45)),
                        Text('Principal Sign', style: TextStyle(fontSize: 8, color: Colors.black87)),
                      ],
                    ),
                    Row(
                      children: [
                        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close', style: TextStyle(color: Colors.grey))),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _downloadIdCard();
                          },
                          icon: const Icon(Icons.download, color: Colors.white, size: 14),
                          label: const Text('Download', style: TextStyle(color: Colors.white, fontSize: 11)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _downloadIdCard() async {
    final name = _nameController.text.trim().isEmpty ? 'Student' : _nameController.text.trim();
    final roll = _rollController.text.trim().isEmpty ? '01' : _rollController.text.trim();
    final contact = _parentContactController.text.trim().isEmpty ? 'Not Available' : _parentContactController.text.trim();

    String parentName = 'N/A';
    String address = 'N/A';
    String district = 'N/A';
    String state = 'N/A';
    String pinCode = 'N/A';
    String admissionDate = 'N/A';
    String dob = 'N/A';
    String? photoUrl = _studentPhotoUrl;

    try {
      final docId = '${_directoryClass}_Roll_$roll';
      final doc = await FirebaseFirestore.instance.collection('students_directory').doc(docId).get();
      if (doc.exists) {
        final data = doc.data()!;
        parentName = data['parentName']?.toString() ?? 'N/A';
        address = data['address']?.toString() ?? 'N/A';
        district = data['district']?.toString() ?? 'N/A';
        state = data['state']?.toString() ?? 'N/A';
        pinCode = data['pinCode']?.toString() ?? 'N/A';
        admissionDate = data['joiningDate']?.toString() ?? 'N/A';
        dob = data['dateOfBirth']?.toString() ?? 'N/A';
        final dbPhoto = data['photoUrl']?.toString();
        if (dbPhoto != null && dbPhoto.isNotEmpty) photoUrl = dbPhoto;
      }
    } catch (e) {
      debugPrint('ID Card data fetch error: $e');
    }

    pw.MemoryImage? studentPhoto;
    if (photoUrl != null && photoUrl!.isNotEmpty) {
      try {
        final corsUrl = 'https://corsproxy.io/?${Uri.encodeComponent(photoUrl!)}';
        final imageResponse = await http.get(Uri.parse(photoUrl!));
        if (imageResponse.statusCode == 200 && imageResponse.bodyBytes.isNotEmpty) {
          studentPhoto = pw.MemoryImage(imageResponse.bodyBytes);
        }
      } catch (e) {
        debugPrint('ID Card photo load error: $e');
      }
    }

    final pdf = pw.Document();
    pdf.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(243, 153, marginAll: 0),
        build: (pw.Context context) {
          return pw.Container(
            width: 243,
            height: 153,
            decoration: pw.BoxDecoration(
              color: PdfColors.white,
              border: pw.Border.all(color: PdfColors.orange800, width: 1.5),
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Column(
              children: [
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.orange800,
                    borderRadius: const pw.BorderRadius.only(topLeft: pw.Radius.circular(6), topRight: pw.Radius.circular(6)),
                  ),
                  child: pw.Row(
                    children: [
                      pw.Container(
                        width: 25,
                        height: 25,
                        decoration: const pw.BoxDecoration(color: PdfColors.white, shape: pw.BoxShape.circle),
                        child: pw.Center(child: pw.Text('S', style: pw.TextStyle(color: PdfColors.orange800, fontSize: 15, fontWeight: pw.FontWeight.bold))),
                      ),
                      pw.SizedBox(width: 6),
                      pw.Expanded(
                        child: pw.Text('SARASWATI VIDYA NIKETAN, MADHABDHAM', style: pw.TextStyle(color: PdfColors.white, fontSize: 8, fontWeight: pw.FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: pw.BoxDecoration(color: PdfColors.orange800, borderRadius: pw.BorderRadius.circular(4)),
                  child: pw.Text('STUDENT ID CARD', style: pw.TextStyle(color: PdfColors.white, fontSize: 7, fontWeight: pw.FontWeight.bold)),
                ),
                pw.SizedBox(height: 5),
                pw.Expanded(
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 8),
                    child: pw.Row(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Container(
                          width: 50,
                          height: 62,
                          decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.orange800, width: 1)),
                          child: studentPhoto != null
                              ? pw.Image(studentPhoto, fit: pw.BoxFit.cover)
                              : pw.Center(child: pw.Text('PHOTO', style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700))),
                        ),
                        pw.SizedBox(width: 7),
                        pw.Expanded(
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              _pdfField('Name', name),
                              _pdfField('Father', parentName),
                              _pdfField('Class', _directoryClass),
                              _pdfField('Roll', roll),
                              _pdfField('Contact', contact),
                              _pdfField('DOB', dob),
                              _pdfField('Admission', admissionDate),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                pw.Container(
                  width: double.infinity,
                  padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: const pw.BoxDecoration(color: PdfColors.grey100),
                  child: pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text('$district, $state - $pinCode', style: const pw.TextStyle(fontSize: 6, color: PdfColors.grey700)),
                      pw.Text('Principal Sign', style: pw.TextStyle(fontSize: 6, fontWeight: pw.FontWeight.bold, color: PdfColors.black)),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    try {
      final pdfBytes = await pdf.save();
      final blob = html.Blob([pdfBytes], 'application/pdf');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final safeName = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), '_');
      
      final anchor = html.AnchorElement(href: url)
        ..setAttribute('download', 'Student_ID_Card_${safeName}_Roll_$roll.pdf')
        ..style.display = 'none';

      html.document.body?.children.add(anchor);
      anchor.click();
      anchor.remove();
      html.Url.revokeObjectUrl(url);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Actual Student ID Card PDF download ho gaya.')));
      }
    } catch (e) {
      debugPrint('PDF generation error: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('ID Card PDF banane mein error: $e')));
    }
  }

  pw.Widget _pdfField(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(width: 42, child: pw.Text(label, style: pw.TextStyle(fontSize: 6.5, fontWeight: pw.FontWeight.bold, color: PdfColors.orange800))),
          pw.Text(': ', style: const pw.TextStyle(fontSize: 6.5)),
          pw.Expanded(child: pw.Text(value, maxLines: 2, style: const pw.TextStyle(fontSize: 6.5))),
        ],
      ),
    );
  }

  Widget _idCardField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 80, child: Text(label, style: const TextStyle(color: Color(0xFFC85A17), fontWeight: FontWeight.bold, fontSize: 10))),
          const Text(': ', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold, fontSize: 10)),
          Expanded(child: Text(value, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600, fontSize: 10))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final adminEmail = FirebaseAuth.instance.currentUser?.email ?? 'School Administrator';

    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      appBar: AppBar(
        toolbarHeight: 72,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: const Color(0xFF111B21),
        surfaceTintColor: Colors.transparent,
        titleSpacing: 18,
        title: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF00A884), Color(0xFF00C896)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(13),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF00A884).withOpacity(0.22),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Icon(
                Icons.admin_panel_settings_rounded,
                color: Colors.white,
                size: 23,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'School Admin Console',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.1,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Saarthi AI • School Management',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Builder(
            builder: (context) {
              final compact = MediaQuery.of(context).size.width < 760;
              if (compact) return const SizedBox.shrink();

              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    backgroundColor: const Color(0xFF00A884).withOpacity(0.12),
                    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(11),
                      side: BorderSide(
                        color: const Color(0xFF00A884).withOpacity(0.26),
                      ),
                    ),
                  ),
                  onPressed: _openAddStudentDialog,
                  icon: const Icon(
                    Icons.person_add_alt_1_rounded,
                    color: Color(0xFF00D9A5),
                    size: 18,
                  ),
                  label: const Text(
                    'Add Student',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              );
            },
          ),
          PopupMenuButton<String>(
            tooltip: 'Admin Menu',
            color: const Color(0xFF1B2A32),
            surfaceTintColor: Colors.transparent,
            icon: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: const Icon(
                Icons.more_horiz_rounded,
                color: Colors.white70,
                size: 21,
              ),
            ),
            onSelected: (value) async {
              if (value == 'profile') {
                _showProfileDialog();
              } else if (value == 'settings') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const SettingsScreen()),
                );
              } else if (value == 'logout') {
                await FirebaseAuth.instance.signOut();
                if (!mounted) return;
                Navigator.popUntil(context, (route) => route.isFirst);
              }
            },
            itemBuilder: (BuildContext context) => const [
              PopupMenuItem<String>(
                value: 'profile',
                child: Row(
                  children: [
                    Icon(Icons.person_outline_rounded, color: Color(0xFF00A884), size: 20),
                    SizedBox(width: 12),
                    Text('Admin Profile', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              PopupMenuItem<String>(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, color: Color(0xFF00A884), size: 20),
                    SizedBox(width: 12),
                    Text('Settings', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout_rounded, color: Colors.redAccent, size: 20),
                    SizedBox(width: 12),
                    Text('Logout', style: TextStyle(color: Colors.redAccent)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 1080;

          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              constraints.maxWidth < 600 ? 12 : 18,
              18,
              constraints.maxWidth < 600 ? 12 : 18,
              28,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1450),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildAdminHero(adminEmail),
                    const SizedBox(height: 16),
                    _buildOverviewCards(),
                    const SizedBox(height: 22),
                    if (isWide)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 11,
                            child: _buildLeftColumn(),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            flex: 9,
                            child: _buildRightColumn(),
                          ),
                        ],
                      )
                    else
                      Column(
                        children: [
                          _buildLeftColumn(),
                          const SizedBox(height: 20),
                          _buildRightColumn(),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildAdminHero(String adminEmail) {
    final now = DateTime.now();
    final months = const [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final dateText = '${now.day} ${months[now.month - 1]} ${now.year}';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF173A36),
            Color(0xFF13262A),
            Color(0xFF111B21),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFF00A884).withOpacity(0.16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.22),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;

          final info = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF00A884).withOpacity(0.13),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFF00A884).withOpacity(0.20),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.verified_user_rounded,
                      color: Color(0xFF00D9A5),
                      size: 14,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'ADMIN ACCESS',
                      style: TextStyle(
                        color: Color(0xFF00D9A5),
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 13),
              const Text(
                'Welcome to your School Command Center',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                adminEmail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                dateText,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          );

          final actions = Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              _heroActionButton(
                icon: Icons.person_add_alt_1_rounded,
                label: 'Add Student',
                onTap: _openAddStudentDialog,
              ),
              _heroActionButton(
                icon: Icons.people_alt_outlined,
                label: 'All Students',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const AllStudentsListScreen(),
                    ),
                  );
                },
                outlined: true,
              ),
              _heroActionButton(
                icon: Icons.settings_outlined,
                label: 'Settings',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const SettingsScreen()),
                  );
                },
                outlined: true,
              ),
            ],
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                info,
                const SizedBox(height: 18),
                actions,
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: info),
              const SizedBox(width: 20),
              actions,
            ],
          );
        },
      ),
    );
  }

  Widget _heroActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool outlined = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
          decoration: BoxDecoration(
            color: outlined
                ? Colors.white.withOpacity(0.045)
                : const Color(0xFF00A884),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: outlined
                  ? Colors.white.withOpacity(0.10)
                  : const Color(0xFF00C896).withOpacity(0.55),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: outlined ? const Color(0xFF00D9A5) : Colors.white,
                size: 17,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverviewCards() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final columns = maxWidth >= 1000 ? 4 : (maxWidth >= 620 ? 2 : 1);
        final spacing = 12.0;
        final itemWidth = columns == 1
            ? maxWidth
            : (maxWidth - (spacing * (columns - 1))) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            _overviewCard(
              width: itemWidth,
              icon: Icons.people_alt_rounded,
              title: 'Student Records',
              subtitle: 'Class 1 to 10 directory',
              accent: const Color(0xFF00A884),
            ),
            _overviewCard(
              width: itemWidth,
              icon: Icons.badge_rounded,
              title: 'ID Card Center',
              subtitle: 'Search, preview & download',
              accent: Colors.blueAccent,
            ),
            _overviewCard(
              width: itemWidth,
              icon: Icons.campaign_rounded,
              title: 'Notice Center',
              subtitle: 'Publish & manage updates',
              accent: Colors.orangeAccent,
            ),
            _overviewCard(
              width: itemWidth,
              icon: Icons.school_rounded,
              title: 'Teachers',
              subtitle: '${_teachersList.length} directory entries',
              accent: Colors.purpleAccent,
            ),
          ],
        );
      },
    );
  }

  Widget _overviewCard({
    required double width,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF111B21),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: Colors.white.withOpacity(0.055)),
      ),
      child: Row(
        children: [
          Container(
            width: 43,
            height: 43,
            decoration: BoxDecoration(
              color: accent.withOpacity(0.11),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: accent.withOpacity(0.18)),
            ),
            child: Icon(icon, color: accent, size: 21),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 9.8,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _adminPanel(
          icon: Icons.campaign_rounded,
          title: 'Digital Notice Board',
          subtitle: _editingNoticeId == null
              ? 'Create and publish a new school announcement'
              : 'Editing an existing school announcement',
          accent: Colors.orangeAccent,
          trailing: _editingNoticeId == null
              ? null
              : TextButton.icon(
                  onPressed: _cancelNoticeEdit,
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Cancel Edit'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.redAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
          child: Column(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 560;

                  final category = DropdownButtonFormField<String>(
                    value: _noticeCategory,
                    dropdownColor: const Color(0xFF1B2A32),
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Notice Type').copyWith(
                      prefixIcon: const Icon(
                        Icons.category_outlined,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ),
                    items: _noticeCategories
                        .map(
                          (value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _noticeCategory = value);
                      }
                    },
                  );

                  final title = TextField(
                    controller: _noticeTitleController,
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Notice Title').copyWith(
                      prefixIcon: const Icon(
                        Icons.title_rounded,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ),
                  );

                  if (compact) {
                    return Column(
                      children: [
                        category,
                        const SizedBox(height: 10),
                        title,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      SizedBox(width: 180, child: category),
                      const SizedBox(width: 10),
                      Expanded(child: title),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _noticeDescController,
                minLines: 3,
                maxLines: 5,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Details / Instructions').copyWith(
                  alignLabelWithHint: true,
                  prefixIcon: const Padding(
                    padding: EdgeInsets.only(bottom: 54),
                    child: Icon(
                      Icons.notes_rounded,
                      color: Color(0xFF00A884),
                      size: 19,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 13),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A884),
                    disabledBackgroundColor: const Color(0xFF00A884).withOpacity(0.35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _isSavingNotice ? null : _saveNotice,
                  icon: _isSavingNotice
                      ? const SizedBox(
                          width: 17,
                          height: 17,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          _editingNoticeId == null
                              ? Icons.send_rounded
                              : Icons.check_circle_outline_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                  label: Text(
                    _isSavingNotice
                        ? 'Saving...'
                        : (_editingNoticeId == null
                            ? 'Publish Notice'
                            : 'Update Notice'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _adminPanel(
          icon: Icons.badge_rounded,
          title: 'Student Directory & ID Cards',
          subtitle: 'Search student records and manage digital ID cards',
          accent: const Color(0xFF00A884),
          trailing: TextButton.icon(
            onPressed: _openAddStudentDialog,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF00D9A5),
              backgroundColor: const Color(0xFF00A884).withOpacity(0.09),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
            label: const Text(
              'Add Student',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
          child: Column(
            children: [
              if (_studentPhotoUrl != null && _studentPhotoUrl!.trim().isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D171C),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF00A884).withOpacity(0.12),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFF00A884),
                            width: 1.5,
                          ),
                        ),
                        child: ClipOval(
                          child: Image.network(
                            _studentPhotoUrl!,
                            fit: BoxFit.cover,
                            webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                            errorBuilder: (_, __, ___) => const ColoredBox(
                              color: Color(0xFF162229),
                              child: Icon(
                                Icons.person_rounded,
                                color: Color(0xFF00A884),
                                size: 27,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _nameController.text.trim().isEmpty
                                  ? 'Student Found'
                                  : _nameController.text.trim(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$_directoryClass • Roll ${_rollController.text.trim()}',
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.verified_rounded,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ],
                  ),
                ),
              ],
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 520;

                  final classField = DropdownButtonFormField<String>(
                    value: _directoryClass,
                    dropdownColor: const Color(0xFF1B2A32),
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Class').copyWith(
                      prefixIcon: const Icon(
                        Icons.school_outlined,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ),
                    items: _classList
                        .map(
                          (value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _directoryClass = value;
                          _nameController.clear();
                          _parentContactController.clear();
                          _studentPhotoUrl = null;
                        });
                      }
                    },
                  );

                  final rollField = TextField(
                    controller: _rollController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(color: Colors.white),
                    onChanged: (_) {
                      if (_studentPhotoUrl != null ||
                          _nameController.text.isNotEmpty ||
                          _parentContactController.text.isNotEmpty) {
                        setState(() {
                          _studentPhotoUrl = null;
                          _nameController.clear();
                          _parentContactController.clear();
                        });
                      }
                    },
                    decoration: _inputDecoration('Roll No').copyWith(
                      prefixIcon: const Icon(
                        Icons.numbers_rounded,
                        color: Color(0xFF00A884),
                        size: 19,
                      ),
                    ),
                  );

                  if (compact) {
                    return Column(
                      children: [
                        classField,
                        const SizedBox(height: 10),
                        rollField,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: classField),
                      const SizedBox(width: 10),
                      Expanded(child: rollField),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _nameController,
                readOnly: true,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Student Full Name').copyWith(
                  prefixIcon: const Icon(
                    Icons.person_outline_rounded,
                    color: Colors.white38,
                    size: 19,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _parentContactController,
                readOnly: true,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Parent Contact No').copyWith(
                  prefixIcon: const Icon(
                    Icons.phone_outlined,
                    color: Colors.white38,
                    size: 19,
                  ),
                ),
              ),
              const SizedBox(height: 13),
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 520;

                  final searchButton = _dashboardActionButton(
                    icon: Icons.search_rounded,
                    label: _isSearchingStudent ? 'Searching...' : 'Search Record',
                    onPressed: _isSearchingStudent ? null : _searchStudent,
                    primary: true,
                  );

                  final idButton = _dashboardActionButton(
                    icon: Icons.badge_outlined,
                    label: 'View ID Card',
                    onPressed: _showIdCardPreview,
                  );

                  if (compact) {
                    return Column(
                      children: [
                        SizedBox(width: double.infinity, child: searchButton),
                        const SizedBox(height: 9),
                        SizedBox(width: double.infinity, child: idButton),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: searchButton),
                      const SizedBox(width: 9),
                      Expanded(child: idButton),
                    ],
                  );
                },
              ),
              const SizedBox(height: 9),
              SizedBox(
                width: double.infinity,
                child: _dashboardActionButton(
                  icon: Icons.groups_2_outlined,
                  label: 'Open Complete Student Directory',
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const AllStudentsListScreen(),
                      ),
                    );
                  },
                  soft: true,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRightColumn() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _adminPanel(
          icon: Icons.school_rounded,
          title: 'Teachers Directory',
          subtitle: 'Quick view of teaching staff',
          accent: Colors.purpleAccent,
          trailing: TextButton.icon(
            onPressed: _openAddTeacherDialog,
            style: TextButton.styleFrom(
              foregroundColor: Colors.purpleAccent,
              backgroundColor: Colors.purpleAccent.withOpacity(0.08),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text(
              'Add Teacher',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
          child: _teachersList.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Center(
                    child: Text(
                      'Teacher directory empty hai.',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _teachersList.length,
                  separatorBuilder: (_, __) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Container(
                      height: 1,
                      color: Colors.white.withOpacity(0.045),
                    ),
                  ),
                  itemBuilder: (context, index) {
                    final teacher = _teachersList[index];
                    final teacherName = teacher['name'] ?? '';
                    final initial = teacherName.trim().isEmpty
                        ? 'T'
                        : teacherName.trim()[0].toUpperCase();

                    return Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.purpleAccent.withOpacity(0.20),
                                const Color(0xFF00A884).withOpacity(0.10),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(
                              color: Colors.purpleAccent.withOpacity(0.14),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            initial,
                            style: const TextStyle(
                              color: Colors.purpleAccent,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const SizedBox(width: 11),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                teacherName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                teacher['subject'] ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 10.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D171C),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Text(
                            teacher['phone'] ?? '',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        const SizedBox(height: 18),
        _adminPanel(
          icon: Icons.notifications_active_outlined,
          title: 'Published Notices',
          subtitle: 'Preview, edit or remove live announcements',
          accent: Colors.blueAccent,
          child: SizedBox(
            height: 430,
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('school_notices')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF00A884),
                      strokeWidth: 2.4,
                    ),
                  );
                }

                if (snapshot.hasError) {
                  return _adminEmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: 'Notice load nahi ho paya',
                    subtitle: 'Internet ya Firebase connection check karein.',
                  );
                }

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return _adminEmptyState(
                    icon: Icons.notifications_none_rounded,
                    title: 'Abhi koi notice published nahi hai',
                    subtitle: 'Left panel se pehla notice publish karein.',
                  );
                }

                final docs = snapshot.data!.docs;

                return ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 9),
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final category = data['category']?.toString() ?? 'General';
                    final accent = _adminCategoryColor(category);

                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => _showNoticeDetailDialog(data),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D171C),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.045),
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: accent.withOpacity(0.11),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Icon(
                                  _adminCategoryIcon(category),
                                  color: accent,
                                  size: 19,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: 7,
                                      runSpacing: 5,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 7,
                                            vertical: 3,
                                          ),
                                          decoration: BoxDecoration(
                                            color: accent.withOpacity(0.10),
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          child: Text(
                                            category,
                                            style: TextStyle(
                                              color: accent,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ),
                                        Text(
                                          'Notice ${index + 1}',
                                          style: const TextStyle(
                                            color: Colors.white24,
                                            fontSize: 8.8,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      data['title']?.toString() ?? 'Untitled Notice',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w800,
                                        height: 1.25,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      data['description']?.toString() ?? '',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white38,
                                        fontSize: 10.2,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              PopupMenuButton<String>(
                                tooltip: 'Notice Actions',
                                color: const Color(0xFF1B2A32),
                                icon: const Icon(
                                  Icons.more_vert_rounded,
                                  color: Colors.white38,
                                  size: 20,
                                ),
                                onSelected: (value) {
                                  if (value == 'preview') {
                                    _showNoticeDetailDialog(data);
                                  } else if (value == 'edit') {
                                    _startEditNotice(doc.id, data);
                                  } else if (value == 'delete') {
                                    _deleteNotice(doc.id);
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                    value: 'preview',
                                    child: Row(
                                      children: [
                                        Icon(Icons.visibility_outlined, color: Color(0xFF00A884), size: 18),
                                        SizedBox(width: 9),
                                        Text('Preview', style: TextStyle(color: Colors.white)),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Row(
                                      children: [
                                        Icon(Icons.edit_outlined, color: Colors.blueAccent, size: 18),
                                        SizedBox(width: 9),
                                        Text('Edit', style: TextStyle(color: Colors.white)),
                                      ],
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 18),
                                        SizedBox(width: 9),
                                        Text('Delete', style: TextStyle(color: Colors.redAccent)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _adminPanel({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color accent,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111B21),
        borderRadius: BorderRadius.circular(19),
        border: Border.all(color: Colors.white.withOpacity(0.055)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.14),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.11),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: accent.withOpacity(0.15)),
                ),
                child: Icon(icon, color: accent, size: 20),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 9.8,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing,
              ],
            ],
          ),
          const SizedBox(height: 15),
          Container(
            height: 1,
            color: Colors.white.withOpacity(0.045),
          ),
          const SizedBox(height: 15),
          child,
        ],
      ),
    );
  }

  Widget _dashboardActionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool primary = false,
    bool soft = false,
  }) {
    if (primary) {
      return ElevatedButton.icon(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00A884),
          disabledBackgroundColor: const Color(0xFF00A884).withOpacity(0.30),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
        ),
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    if (soft) {
      return TextButton.icon(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF00D9A5),
          backgroundColor: const Color(0xFF00A884).withOpacity(0.075),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
            side: BorderSide(
              color: const Color(0xFF00A884).withOpacity(0.14),
            ),
          ),
        ),
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF00D9A5),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
        side: BorderSide(
          color: const Color(0xFF00A884).withOpacity(0.38),
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(11),
        ),
      ),
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _adminEmptyState({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: const Color(0xFF00A884).withOpacity(0.08),
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                color: const Color(0xFF00A884),
                size: 27,
              ),
            ),
            const SizedBox(height: 13),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white30,
                fontSize: 10,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _adminCategoryColor(String category) {
    switch (category.toLowerCase()) {
      case 'holiday':
        return Colors.orangeAccent;
      case 'exam':
        return Colors.redAccent;
      case 'event':
        return Colors.blueAccent;
      case 'general':
      default:
        return const Color(0xFF00A884);
    }
  }

  IconData _adminCategoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'holiday':
        return Icons.beach_access_rounded;
      case 'exam':
        return Icons.menu_book_rounded;
      case 'event':
        return Icons.event_rounded;
      case 'general':
      default:
        return Icons.campaign_rounded;
    }
  }

  void _showNoticeDetailDialog(Map<String, dynamic> data) {
    final category = data['category']?.toString() ?? 'General';
    final accent = _adminCategoryColor(category);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111B21),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        title: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: accent.withOpacity(0.11),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _adminCategoryIcon(category),
                color: accent,
                size: 20,
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      category,
                      style: TextStyle(
                        color: accent,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    data['title']?.toString() ?? 'Notice',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Text(
            data['description']?.toString() ?? '',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              height: 1.6,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Close',
              style: TextStyle(
                color: Color(0xFF00A884),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: Colors.white30,
        fontSize: 11.5,
      ),
      filled: true,
      fillColor: const Color(0xFF0D171C),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 13,
        vertical: 13,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: BorderSide(
          color: Colors.white.withOpacity(0.055),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(
          color: Color(0xFF00A884),
          width: 1.15,
        ),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: BorderSide.none,
      ),
    );
  }

}

// ============================================================
// SETTINGS SCREEN
// ============================================================
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _gmailController = TextEditingController();
  final TextEditingController _scriptUrlController = TextEditingController();

  String? _linkedGmail;
  String? _linkedScriptUrl;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _fetchLinkedAccount();
  }

  @override
  void dispose() {
    _gmailController.dispose();
    _scriptUrlController.dispose();
    super.dispose();
  }

  Future<void> _fetchLinkedAccount() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('school_config').doc('google_drive_account').get();
      if (!mounted) return;

      if (doc.exists) {
        final data = doc.data() ?? {};
        setState(() {
          _linkedGmail = data['email']?.toString();
          _linkedScriptUrl = data['scriptUrl']?.toString();
          _gmailController.text = _linkedGmail ?? '';
          _scriptUrlController.text = _linkedScriptUrl ?? '';
        });
      }
    } catch (e) {
      debugPrint('Settings load error: $e');
    }
  }

  Future<void> _linkGmail() async {
    final email = _gmailController.text.trim();
    final scriptUrl = _scriptUrlController.text.trim();

    if (email.isEmpty || !email.contains('@gmail.com')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Kripya valid Gmail ID daalein.')));
      return;
    }

    if (scriptUrl.isEmpty || !scriptUrl.startsWith('https://script.google.com/')) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Kripya valid Google Apps Script Web App URL daalein.')));
      return;
    }

    setState(() { _isLoading = true; });

    try {
      await FirebaseFirestore.instance.collection('school_config').doc('google_drive_account').set({
        'email': email,
        'scriptUrl': scriptUrl,
        'status': 'connected',
        'linkedAt': DateTime.now().millisecondsSinceEpoch,
      });

      if (!mounted) return;

      setState(() {
        _linkedGmail = email;
        _linkedScriptUrl = scriptUrl;
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Google Drive configuration save ho gayi!')));
    } catch (e) {
      if (!mounted) return;
      setState(() { _isLoading = false; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Error: $e')));
    }
  }

  Future<void> _unlinkGmail() async {
    setState(() { _isLoading = true; });

    try {
      await FirebaseFirestore.instance.collection('school_config').doc('google_drive_account').delete();
      if (!mounted) return;

      setState(() {
        _linkedGmail = null;
        _linkedScriptUrl = null;
        _gmailController.clear();
        _scriptUrlController.clear();
        _isLoading = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Google Drive configuration unlink kar di gayi.')));
    } catch (e) {
      if (mounted) {
        setState(() { _isLoading = false; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Error: $e')));
      }
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
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Cloud Storage & Database',
                  style: TextStyle(color: Color(0xFF00A884), fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Student records Google Sheet me aur photos Google Drive par bhejne ke liye Google Apps Script Web App URL save karein.',
                  style: TextStyle(color: Colors.grey, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 20),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F2C34),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const CircleAvatar(
                            radius: 22,
                            backgroundColor: Color(0xFF121B22),
                            child: Icon(Icons.add_to_drive, color: Color(0xFF00A884)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Google Drive Integration', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                                Text(
                                  _linkedGmail != null ? 'Configuration Saved' : 'No configuration',
                                  style: TextStyle(
                                    color: _linkedGmail != null ? const Color(0xFF00A884) : Colors.orangeAccent,
                                    fontSize: 12,
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
                          decoration: BoxDecoration(color: const Color(0xFF121B22), borderRadius: BorderRadius.circular(10)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Linked Gmail ID', style: TextStyle(color: Colors.grey, fontSize: 11)),
                              const SizedBox(height: 4),
                              Text(_linkedGmail!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 12),
                              const Text('Apps Script URL', style: TextStyle(color: Colors.grey, fontSize: 11)),
                              const SizedBox(height: 4),
                              SelectableText(_linkedScriptUrl ?? '', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.redAccent)),
                            onPressed: _isLoading ? null : _unlinkGmail,
                            icon: const Icon(Icons.link_off, color: Colors.redAccent),
                            label: const Text('Unlink / Change Configuration', style: TextStyle(color: Colors.redAccent)),
                          ),
                        ),
                      ] else ...[
                        TextField(
                          controller: _gmailController,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('School Gmail ID'),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _scriptUrlController,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Google Apps Script /exec URL'),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00A884),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: _isLoading ? null : _linkGmail,
                            icon: const Icon(Icons.cloud_done, color: Colors.white),
                            label: Text(
                              _isLoading ? 'Saving...' : 'Save Google Drive Configuration',
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
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.grey),
      filled: true,
      fillColor: const Color(0xFF121B22),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
    );
  }
}

// ============================================================
// ALL STUDENTS LIST
// ============================================================
class AllStudentsListScreen extends StatefulWidget {
  const AllStudentsListScreen({super.key});

  @override
  State<AllStudentsListScreen> createState() => _AllStudentsListScreenState();
}

class _AllStudentsListScreenState extends State<AllStudentsListScreen> {
  String _selectedClassFilter = 'Class 1';

  final List<String> _classes = List.generate(10, (index) => 'Class ${index + 1}');

  Future<void> _deleteStudent(String docId) async {
    final passwordController = TextEditingController();
    bool obscureText = true;
    bool isLoading = false;
    String? errorMessage;

    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F2C34),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
                  SizedBox(width: 10),
                  Text('Delete Student?', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Kya aap sach mein is student ka record hamesha ke liye delete karna chahte hain? Yeh wapas nahi aayega.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 18),
                  const Text('Admin Password daalein:', style: TextStyle(color: Colors.white, fontSize: 12)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: passwordController,
                    obscureText: obscureText,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Enter Admin Password',
                      hintStyle: const TextStyle(color: Colors.grey, fontSize: 13),
                      filled: true,
                      fillColor: const Color(0xFF121B22),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                      suffixIcon: IconButton(
                        icon: Icon(obscureText ? Icons.visibility_off : Icons.visibility, color: Colors.grey, size: 18),
                        onPressed: () => setDialogState(() => obscureText = !obscureText),
                      ),
                    ),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(errorMessage!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
                  ]
                ],
              ),
              actions: [
                TextButton(
                  onPressed: isLoading ? null : () => Navigator.pop(ctx, false),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                  onPressed: isLoading
                      ? null
                      : () async {
                          final pass = passwordController.text.trim();
                          if (pass.isEmpty) {
                            setDialogState(() => errorMessage = 'Password daalna zaroori hai.');
                            return;
                          }
                          setDialogState(() {
                            isLoading = true;
                            errorMessage = null;
                          });

                          try {
                            final user = FirebaseAuth.instance.currentUser;
                            if (user != null && user.email != null) {
                              final credential = EmailAuthProvider.credential(email: user.email!, password: pass);
                              await user.reauthenticateWithCredential(credential);
                              Navigator.pop(ctx, true);
                            } else {
                              setDialogState(() { isLoading = false; errorMessage = 'Admin user nahi mila.'; });
                            }
                          } catch (e) {
                            setDialogState(() { isLoading = false; errorMessage = 'Galat Password!'; });
                          }
                        },
                  child: isLoading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Delete Now', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          }
        );
      },
    );

    if (confirm != true) return;

    try {
      final studentDoc = await FirebaseFirestore.instance.collection('students_directory').doc(docId).get();

      if (!studentDoc.exists) throw Exception('Student Firestore me nahi mila.');

      final data = studentDoc.data()!;
      final studentClass = data['class']?.toString() ?? '';
      final rollNo = data['rollNo']?.toString() ?? '';

      final configDoc = await FirebaseFirestore.instance.collection('school_config').doc('google_drive_account').get();
      final scriptUrl = configDoc.data()?['scriptUrl']?.toString();

      if (scriptUrl == null || scriptUrl.isEmpty) throw Exception('Google Apps Script URL Settings me saved nahi hai.');

      final response = await http.post(
        Uri.parse(scriptUrl),
        headers: {'Content-Type': 'text/plain;charset=utf-8'},
        body: jsonEncode({'action': 'delete_student', 'studentClass': studentClass, 'roll': rollNo}),
      );

      if (response.statusCode != 200) throw Exception('Google delete failed: ${response.statusCode}');

      final result = jsonDecode(response.body);
      if (result['success'] != true) throw Exception(result['message'] ?? 'Google delete failed');

      await FirebaseFirestore.instance.collection('students_directory').doc(docId).delete();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Colors.redAccent, content: Text('Student permanently delete ho gaya!')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Delete error: $e')));
    }
  }

  void _editStudent(String docId, Map<String, dynamic> data) {
    final nameCtrl = TextEditingController(text: data['name']?.toString() ?? '');
    final parentCtrl = TextEditingController(text: data['parentName']?.toString() ?? '');
    final contactCtrl = TextEditingController(text: data['parentContact']?.toString() ?? '');
    final photoCtrl = TextEditingController(text: data['photoUrl']?.toString() ?? '');
    final addressCtrl = TextEditingController(text: data['address']?.toString() ?? '');
    final pinCtrl = TextEditingController(text: data['pinCode']?.toString() ?? '');
    final districtCtrl = TextEditingController(text: data['district']?.toString() ?? '');
    final stateCtrl = TextEditingController(text: data['state']?.toString() ?? '');
    final admissionCtrl = TextEditingController(text: data['joiningDate']?.toString() ?? '');
    final dobCtrl = TextEditingController(text: data['dateOfBirth']?.toString() ?? '');
    String hostelFacility = data['hostelFacility']?.toString() ?? 'No';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2C34),
        title: Text('Edit Student (${data['class'] ?? ''} - Roll ${data['rollNo'] ?? ''})', style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: 500,
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
                DropdownButtonFormField<String>(
                  value: hostelFacility,
                  dropdownColor: const Color(0xFF1F2C34),
                  style: const TextStyle(color: Colors.white),
                  decoration: _dialogInput('Hostel Facility'),
                  items: const [
                    DropdownMenuItem(value: 'No', child: Text('Hostel Facility: No')),
                    DropdownMenuItem(value: 'Yes', child: Text('Hostel Facility: Yes')),
                  ],
                  onChanged: (value) {
                    if (value != null) hostelFacility = value;
                  },
                ),
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
                const SizedBox(height: 8),
                TextField(controller: admissionCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput('Admission Date')),
                const SizedBox(height: 8),
                TextField(controller: dobCtrl, style: const TextStyle(color: Colors.white), decoration: _dialogInput('Date of Birth')),
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteStudent(docId);
            },
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
            label: const Text('Delete Student', style: TextStyle(color: Colors.redAccent)),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A884)),
                onPressed: () async {
                  try {
                    final configDoc = await FirebaseFirestore.instance.collection('school_config').doc('google_drive_account').get();
                    final scriptUrl = configDoc.data()?['scriptUrl']?.toString();

                    if (scriptUrl == null || scriptUrl.isEmpty) throw Exception('Google Apps Script URL Settings me saved nahi hai.');

                    final studentClass = data['class']?.toString() ?? '';
                    final rollNo = data['rollNo']?.toString() ?? '';

                    final response = await http.post(
                      Uri.parse(scriptUrl),
                      headers: {'Content-Type': 'text/plain;charset=utf-8'},
                      body: jsonEncode({
                        'action': 'edit_student',
                        'name': nameCtrl.text.trim(),
                        'parentName': parentCtrl.text.trim(),
                        'studentClass': studentClass,
                        'roll': rollNo,
                        'contact': contactCtrl.text.trim(),
                        'photoUrl': photoCtrl.text.trim(),
                        'hostelFacility': hostelFacility,
                        'address': addressCtrl.text.trim(),
                        'district': districtCtrl.text.trim(),
                        'state': stateCtrl.text.trim(),
                        'pinCode': pinCtrl.text.trim(),
                        'joiningDate': admissionCtrl.text.trim(),
                        'dateOfBirth': dobCtrl.text.trim(),
                      }),
                    );

                    if (response.statusCode != 200) throw Exception('Google update failed: ${response.statusCode}');

                    final result = jsonDecode(response.body);
                    if (result['success'] != true) throw Exception(result['message'] ?? 'Google update failed');

                    await FirebaseFirestore.instance.collection('students_directory').doc(docId).update({
                      'name': nameCtrl.text.trim(),
                      'parentName': parentCtrl.text.trim(),
                      'parentContact': contactCtrl.text.trim(),
                      'photoUrl': photoCtrl.text.trim(),
                      'hostelFacility': hostelFacility,
                      'address': addressCtrl.text.trim(),
                      'district': districtCtrl.text.trim(),
                      'state': stateCtrl.text.trim(),
                      'pinCode': pinCtrl.text.trim(),
                      'joiningDate': admissionCtrl.text.trim(),
                      'dateOfBirth': dobCtrl.text.trim(),
                      'updatedAt': FieldValue.serverTimestamp(),
                    });

                    if (mounted) {
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(backgroundColor: Color(0xFF00A884), content: Text('Student Firestore aur Google Sheet dono me update ho gaya!')));
                    }
                  } catch (e) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: Colors.redAccent, content: Text('Update error: $e')));
                  }
                },
                child: const Text('Save Changes', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
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
          Container(
            color: const Color(0xFF1F2C34),
            height: 52,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              itemCount: _classes.length,
              itemBuilder: (context, index) {
                final currentClass = _classes[index];
                final selected = currentClass == _selectedClassFilter;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(
                      currentClass,
                      style: TextStyle(color: selected ? Colors.white : Colors.grey, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    selected: selected,
                    selectedColor: const Color(0xFF00A884),
                    backgroundColor: const Color(0xFF121B22),
                    onSelected: (_) => setState(() => _selectedClassFilter = currentClass),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('students_directory').where('class', isEqualTo: _selectedClassFilter).snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: Color(0xFF00A884)));

                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(child: Text('$_selectedClassFilter me koi student registered nahi hai.', style: const TextStyle(color: Colors.grey)));
                }

                final docs = snapshot.data!.docs.toList();
                docs.sort((a, b) {
                  final aData = a.data() as Map<String, dynamic>;
                  final bData = b.data() as Map<String, dynamic>;
                  final aRoll = int.tryParse(aData['rollNo']?.toString() ?? '') ?? 999999;
                  final bRoll = int.tryParse(bData['rollNo']?.toString() ?? '') ?? 999999;
                  return aRoll.compareTo(bRoll);
                });

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final student = doc.data() as Map<String, dynamic>;
                    final photoUrl = student['photoUrl']?.toString();

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0xFF1F2C34), borderRadius: BorderRadius.circular(12)),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 56,
                            height: 56,
                            child: ClipOval(
                              child: (photoUrl != null && photoUrl.isNotEmpty)
                                  ? Image.network(
                                      photoUrl,
                                      fit: BoxFit.cover,
                                      webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                                      errorBuilder: (context, error, stackTrace) => const ColoredBox(color: Color(0xFF121B22), child: Icon(Icons.person, size: 30, color: Color(0xFF00A884))),
                                    )
                                  : const ColoredBox(color: Color(0xFF121B22), child: Icon(Icons.person, size: 30, color: Color(0xFF00A884))),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(student['name']?.toString() ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(color: const Color(0xFF00A884).withOpacity(0.18), borderRadius: BorderRadius.circular(4)),
                                      child: Text('Roll: ${student['rollNo'] ?? 'N/A'}', style: const TextStyle(color: Color(0xFF00A884), fontSize: 11, fontWeight: FontWeight.bold)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 5),
                                Text('Parent: ${student['parentName'] ?? 'N/A'} • Contact: ${student['parentContact'] ?? 'N/A'}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                const SizedBox(height: 3),
                                Text('Address: ${student['address'] ?? ''}, ${student['district'] ?? ''}, ${student['state'] ?? ''} - ${student['pinCode'] ?? ''}', style: const TextStyle(color: Colors.white60, fontSize: 11)),
                                const SizedBox(height: 3),
                                Text('Hostel: ${student['hostelFacility'] ?? 'No'} • Admission: ${student['joiningDate'] ?? 'N/A'} • DOB: ${student['dateOfBirth'] ?? 'N/A'}', style: const TextStyle(color: Colors.grey, fontSize: 11)),
                              ],
                            ),
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF25D366).withOpacity(0.12),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: const Color(0xFF25D366).withOpacity(0.30)),
                                ),
                                child: IconButton(
                                  tooltip: 'WhatsApp Parent',
                                  icon: const FaIcon(
                                    FontAwesomeIcons.whatsapp,
                                    color: Color(0xFF25D366),
                                    size: 22,
                                  ),
                                  onPressed: () {
                                    final contact = student['parentContact']?.toString() ?? '';
                                    final cleanNum = contact.replaceAll(RegExp(r'\D'), '');
                                    if (cleanNum.length >= 10) {
                                      final waNum = cleanNum.length == 10 ? '91$cleanNum' : cleanNum;
                                      html.window.open('https://wa.me/$waNum', '_blank');
                                    } else {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(backgroundColor: Colors.redAccent, content: Text('Student ka valid contact number nahi hai!')),
                                      );
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(height: 8),
                              Container(
                                decoration: BoxDecoration(
                                  color: Colors.blueAccent.withOpacity(0.10),
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  tooltip: 'Edit Record',
                                  icon: const Icon(Icons.edit_rounded, color: Colors.blueAccent, size: 18),
                                  onPressed: () => _editStudent(doc.id, student),
                                ),
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
}
