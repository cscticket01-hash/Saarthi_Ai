import 'developer_windows_theme.dart';
import 'complaint_retention.dart';
import 'developer_notification_panel.dart';
import 'developer_login_shell.dart';
import 'managed_developer_panel.dart';
import 'developer_account_widgets.dart';
import 'firebase_monitor_panel.dart';
import 'platform/monitor_summary.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform/developer_service.dart';

/// Active license holders disappear from the issue picker until the last
/// 30 days of validity. Expired and revoked schools remain eligible.
List<Map<String,dynamic>> eligibleDeveloperLicenseSchools(
    List<Map<String,dynamic>> schools,
    List<Map<String,dynamic>> licenses,
    int nowMillis) {
  return schools.where((school){
    final id=school['id'];
    if(school['deletedAt']!=null||school['blocked']==true||school['loginDisabled']==true) return false;
    // Older replaced keys are historical; only the school's CURRENT licence
    // can block renewal of that existing school-bound key.
    final current=school['licenseId']??school['activeLicenseHash'];
    return !licenses.any((l)=>
      l['schoolId']==id&&(current==null||l['id']==current)&&l['revoked']!=true&&
      l['expiresAt'] is num &&
      (l['expiresAt'] as num)>nowMillis);
  }).toList();
}

const _ink = Color(0xFFEAF3FF),
    _surface = Color(0xFFF9FBFF),
    _mint = Color(0xFF1268F3);

class DeveloperPortal extends StatelessWidget {
  const DeveloperPortal({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: FirebaseAuth.instance.authStateChanges(),
    builder: (context, s) {
      if (s.connectionState == ConnectionState.waiting)
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      return s.data == null
          ? const _DeveloperLogin()
          : _DeveloperAccess(user: s.data!);
    },
  );
}

class _DeveloperAccess extends StatelessWidget {
  const _DeveloperAccess({required this.user});
  final User user;
  @override
  Widget build(BuildContext context) => FutureBuilder<IdTokenResult>(
    future: user.getIdTokenResult(true),
    builder: (context, s) {
      if (s.hasError)
        return Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => FirebaseAuth.instance.signOut(),
              child: const Text('Sign in again to verify developer access'),
            ),
          ),
        );
      if (!s.hasData)
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      if (s.data!.claims?['admin'] != true &&
          s.data!.claims?['developer'] != true)
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 48),
                const SizedBox(height: 16),
                const Text('Developer access required'),
                const Text(
                  'School accounts do not have access to this website.',
                ),
                TextButton(
                  onPressed: () => FirebaseAuth.instance.signOut(),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        );
      return const _DeveloperDashboard();
    },
  );
}

class _DeveloperLogin extends StatefulWidget {
  const _DeveloperLogin();
  @override
  State<_DeveloperLogin> createState() => _DeveloperLoginState();
}

class _DeveloperLoginState extends State<_DeveloperLogin> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _showPassword = false;
  bool _forgot = false;
  String? _error;
  String? _information;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _information = null;
    });
    try {
      await FirebaseAuth.instance.setPersistence(Persistence.SESSION);
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _email.text.trim(),
        password: _password.text,
      );
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(() => _error = e.code == 'invalid-credential'
            ? 'Check your email and password.'
            : 'Login unavailable. Please try again.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Login unavailable. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (!email.contains('@') || email.endsWith('@')) {
      setState(() {
        _error = 'Enter your email address first.';
        _information = null;
      });
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _information = null;
    });
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (mounted) {
        setState(() {
          _forgot = false;
          _information = 'If this account can reset its password, check your email.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Password reset is unavailable. Try again later.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DeveloperLoginShell(
        form: _forgot ? Column(
          mainAxisSize:MainAxisSize.min,
          crossAxisAlignment:CrossAxisAlignment.stretch,
          children:[
            const Text('Forgot Password',textAlign:TextAlign.center,
              style:TextStyle(fontSize:25,fontWeight:FontWeight.w800,color:Color(0xFF162A55))),
            const SizedBox(height:8),
            const Text('Enter your registered developer email.',textAlign:TextAlign.center,
              style:TextStyle(fontSize:12,color:Color(0xFF647593))),
            const SizedBox(height:23),
            TextField(key:const ValueKey('developer-forgot-email'),
              controller:_email,keyboardType:TextInputType.emailAddress,
              decoration:const InputDecoration(hintText:'Email Address',prefixIcon:Icon(Icons.email_outlined))),
            if(_error!=null)Padding(padding:const EdgeInsets.only(top:10),
              child:Text(_error!,style:const TextStyle(color:Color(0xFFB12440)))),
            const SizedBox(height:16),
            FilledButton.icon(key:const ValueKey('developer-forgot-send'),
              onPressed:_busy?null:_resetPassword,
              icon:const Icon(Icons.send_outlined),label:Text(_busy?'Sending…':'Send Link')),
            const SizedBox(height:8),
            TextButton(onPressed:_busy?null:()=>setState((){_forgot=false;_error=null;}),child:const Text('Back to Login')),
          ],
        ) : Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Welcome to',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF233B6A),
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              'Saarthi AI School App',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF1268F3),
                fontSize: 27,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 9),
            const Text(
              'Your Smart School Management Partner',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF647593), fontSize: 13),
            ),
            const SizedBox(height: 32),
            TextField(
              key: const ValueKey('developer-login-email'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(
                hintText: 'Email Address',
                prefixIcon: Icon(Icons.email_outlined),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('developer-login-password'),
              controller: _password,
              obscureText: !_showPassword,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) {
                if (!_busy) _login();
              },
              decoration: InputDecoration(
                hintText: 'Password',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip: _showPassword ? 'Hide password' : 'Show password',
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                  icon: Icon(_showPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _busy ? null : () => setState(() {
                  _forgot = true;
                  _error = null;
                  _information = null;
                }),
                child: const Text('Forgot password?'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFB12440)),
                ),
              ),
            if (_information != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _information!,
                  style: const TextStyle(color: Color(0xFF176D55)),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('developer-login-submit'),
              onPressed: _busy ? null : _login,
              icon: Icon(_busy
                  ? Icons.hourglass_top_rounded
                  : Icons.arrow_forward_rounded),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 13),
                child: Text(_busy ? 'Logging in…' : 'Login'),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1268F3),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFF7898C9),
                textStyle: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                elevation: 8,
                shadowColor: const Color(0x883E9EFA),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Authorized developer accounts only',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFF647593),
                fontSize: 11,
              ),
            ),
          ],
        ),
      );
}

class _DeveloperDashboard extends StatefulWidget {
  const _DeveloperDashboard();
  @override
  State<_DeveloperDashboard> createState() => _DeveloperDashboardState();
}

class _DeveloperDashboardState extends State<_DeveloperDashboard> {
  String _complaintSchool = '';
  List<Map<String, dynamic>> get _visibleComplaints => _complaints
      .where(
        (c) =>
            !complaintExpired(c) &&
            (_complaintSchool == 'all' || c['schoolId'] == _complaintSchool),
      )
      .toList();
  final _service = DeveloperService();
  int _page = 0;
  int _earningsDays = 30;
  String _earningsSchool = 'all';
  String _search = '', _filter = 'all';
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = {};
  final Map<String, String> _issuedSessionKeys = {}; // Volatile; never persisted or returned by dashboard.
  Timer? _timer;
  StreamSubscription? _schoolsWatch, _licencesWatch, _countsWatch;
  bool _refreshing = false;
  List<Map<String, dynamic>> get _schools => _maps(_data['schools']);
  List<Map<String, dynamic>> get _licenses => _maps(_data['licenses']);
  List<Map<String, dynamic>> get _receipts => _maps(_data['receipts']);
  List<Map<String, dynamic>> get _complaints => _maps(_data['complaints']);
  List<Map<String, dynamic>> _maps(dynamic raw) => raw is List
      ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : [];
  Map<String, dynamic> get _stats => Map<String, dynamic>.from(
    monitorSummary(_schools, DateTime.now().millisecondsSinceEpoch),
  );
  int get _now => DateTime.now().millisecondsSinceEpoch;
  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
    _schoolsWatch = FirebaseFirestore.instance
        .collection('platform_schools')
        .snapshots()
        .listen(
          (_) => _load(silent: true),
          onError: (Object e) {
            if (mounted)
              setState(() => _error = 'Live school updates unavailable: $e');
          },
        );
    _countsWatch = FirebaseFirestore.instance
        .collection('platform_school_summaries')
        .snapshots()
        .listen((_) => _load(silent: true), onError: (Object e) {
          if (mounted) setState(() => _error = 'Live student counts unavailable: $e');
        });
    _licencesWatch = FirebaseFirestore.instance
        .collection('platform_licenses')
        .snapshots()
        .listen(
          (_) => _load(silent: true),
          onError: (Object e) {
            if (mounted)
              setState(() => _error = 'Live licence updates unavailable: $e');
          },
        );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _schoolsWatch?.cancel();
    _licencesWatch?.cancel();
    _countsWatch?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
    String action,
    Map<String, dynamic> body,
  ) async {
    return _service.call(action, body);
  }

  Future<void> _load({bool silent = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (!silent) setState(() => _loading = true);
    try {
      final d = await _call('developer/dashboard', {'refresh': true});
      if (mounted)
        setState(() {
          _data = d;
          _error = null;
        });
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      _refreshing = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  String _date(dynamic n) {
    final v = (n as num?)?.toInt() ?? 0;
    if (v <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(v);
    return '${d.day.toString().padLeft(2, '0')} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]} ${d.year}';
  }

  bool _active(Map s) => schoolOnline(s, DateTime.now().millisecondsSinceEpoch);
  bool _expiring(Map s) =>
      (s['licenseExpiresAt'] as num? ?? 0) > _now &&
      (s['licenseExpiresAt'] as num? ?? 0) <= _now + 14 * 86400000;
  Widget _chip(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: color.withOpacity(.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );
  Widget _panel(Widget child) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white),
      boxShadow: const [BoxShadow(color: Color(0x162A72D9), blurRadius: 22, offset: Offset(0, 9))],
    ),
    child: child,
  );
  Future<void> _issue([String? selected, int initialDays=30]) async {
    final eligible = eligibleDeveloperLicenseSchools(
      _schools, _licenses, DateTime.now().millisecondsSinceEpoch);
    if(selected!=null && !eligible.any((s)=>s['id']==selected)) {
      final exact=_schools.where((s)=>s['id']==selected&&s['blocked']!=true&&s['deletedAt']==null).firstOrNull;
      if(exact!=null)eligible.insert(0,exact);
    }
    if (eligible.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content:Text('All schools hold active licences. They return for renewal in their final 30 days.')),
      );
      return;
    }
    String school = selected!=null && eligible.any((s)=>s['id']==selected)
        ? selected : eligible.first['id'].toString();
    bool paid = true, busy = false;
    String? error;
    final random=Random.secure();
    final renewalId=List.generate(16,(_)=>random.nextInt(256).toRadixString(16).padLeft(2,'0')).join();
    Map<String,dynamic>? currentLicence(String schoolId) {
      final matching=_schools.where((s)=>s['id']==schoolId).firstOrNull;
      if(matching==null)return null;
      return _licenses.where((l)=>l['schoolId']==schoolId&&l['revoked']!=true&&
        (l['expiresAt'] as num? ?? 0)>_now&&
        l['id']==(matching['licenseId']??matching['activeLicenseHash'])).firstOrNull;
    }
    int packageDays=initialDays;
    final amount = TextEditingController(text: '0');
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text(currentLicence(school)!=null?'Renew existing licence — same key':'Create a school licence'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: school,
                  decoration: const InputDecoration(labelText: 'School'),
                  items: eligible
                      .map(
                        (s) => DropdownMenuItem(
                          value: s['id'].toString(),
                          child: Text(
                            s['name']?.toString() ?? s['id'].toString(),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: busy ? null : (v) => setDialog(() => school = v!),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: packageDays,
                  decoration: const InputDecoration(labelText: 'Licence package'),
                  items: const [
                    DropdownMenuItem(value:30,child:Text('30 days')),
                    DropdownMenuItem(value:90,child:Text('90 days')),
                    DropdownMenuItem(value:365,child:Text('12 months')),
                  ],
                  onChanged:busy?null:(v)=>setDialog(()=>packageDays=v??30),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Purchase amount (INR)',
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: paid,
                  onChanged: busy ? null : (v) => setDialog(() => paid = v!),
                  title: const Text('Payment received'),
                ),
                Text(
                  currentLicence(school)!=null
                    ? 'Existing school-bound key will remain valid; renewal extends expiry without changing the school, key, Drive or stored data.'
                    : 'New key is shown only once. Share it with this school and activate it in Windows.',
                  style: const TextStyle(color: const Color(0xFF647899), fontSize: 12),
                ),
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDialog(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final existing=currentLicence(school);
                        final r = await _call(existing==null?'license/issue':'license/renew', {
                          'schoolId': school,
                          'days': packageDays,
                          'paid': paid,
                          'amount': double.tryParse(amount.text) ?? 0,
                          if(existing!=null)...{'licenseId':existing['id'],'renewalId':renewalId},
                        });
                        if (ctx.mounted) Navigator.pop(ctx, r);
                      } catch (e) {
                        setDialog(() {
                          busy = false;
                          error = e.toString();
                        });
                      }
                    },
              child: Text(busy ? 'Saving…' : currentLicence(school)!=null ? 'Renew same key' : 'Generate key'),
            ),
          ],
        ),
      ),
    );
    amount.dispose();
    if (result == null || !mounted) return;
    if(result['sameKey']==true){
      await _load(silent:true);
      if(!mounted)return;
      await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
        title:const Text('Existing licence renewed'),
        content:Text('Expiry extended to ${_date(result['expiresAt'])}. Same school account, licence key, Drive files and school records are preserved. If a replacement key was previously issued but not activated, it must be activated once from the school app.'),
        actions:[FilledButton(onPressed:()=>Navigator.pop(ctx),child:const Text('OK'))]));
      return;
    }
    if(result['key'] is String && (result['key'] as String).isNotEmpty)
      _issuedSessionKeys[sha256.convert(utf8.encode((result['key'] as String).trim().toUpperCase())).toString()]=result['key'] as String;
    await _load(silent:true);
    if(!mounted)return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Licence ready'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Copy this key now. It is shown only once.'),
            const SizedBox(height: 18),
            SelectableText(
              result['key'].toString(),
              style: const TextStyle(
                color: _mint,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text('Valid until ${_date(result['expiresAt'])}'),
            if (result['setup'] != null) ...[
              const SizedBox(height: 12),
              const Text(
                'Copy the school setup too. Paste it into this school’s Google Script only.',
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(
              ClipboardData(text: result['key'].toString()),
            ),
            child: const Text('Copy key'),
          ),
          if (result['setup'] != null)
            TextButton(
              onPressed: () => _copySetup(result['setup']),
              child: const Text('Copy school setup'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    _load(silent: true);
  }

  Future<void> _copySetup(dynamic setup) async {
    // All values are generated alphanumeric strings or a validated project ID.
    final s = Map<String, dynamic>.from(setup);
    final fields = s.entries.map((e) => "${e.key}: '${e.value}'").join(',\n  ');
    await Clipboard.setData(
      ClipboardData(
        text:
            "function setupSchoolMonitoring() {\n  return VS_setupPlatform({\n  $fields\n  });\n}",
      ),
    );
  }

  Future<void> _complaint(Map<String, dynamic> c) async {
    String status = c['status']?.toString() ?? 'open';
    final note = TextEditingController(text: '');
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text('Support • ${c['schoolId']}'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(c['message']?.toString() ?? ''),
                if ((c['developerNote']?.toString() ?? '').isNotEmpty &&
                    c['supportHistoryVersion'] != 1)
                  SelectableText('Developer: ${c['developerNote']}'),
                SizedBox(
                  height: 220,
                  child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .collection('platform_complaints')
                        .doc(c['id'].toString())
                        .collection('messages')
                        .orderBy('createdAt')
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError)
                        return const Text('Conversation could not be loaded.');
                      final docs = snapshot.data?.docs ?? [];
                      return ListView(
                        children: [
                          for (final d in docs)
                            ListTile(
                              title: Text(
                                d.data()['role'] == 'developer'
                                    ? 'Developer'
                                    : 'School',
                              ),
                              subtitle: SelectableText(
                                d.data()['message']?.toString() ?? '',
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  items: const [
                    DropdownMenuItem(value: 'open', child: Text('Open')),
                    DropdownMenuItem(
                      value: 'in_progress',
                      child: Text('In progress'),
                    ),
                    DropdownMenuItem(
                      value: 'resolved',
                      child: Text('Resolved'),
                    ),
                  ],
                  onChanged: (v) => setD(() => status = v!),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: note,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Reply to school',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await _call('complaint/update', {
                    'complaintId': c['id'],
                    'status': status,
                    'note': note.text,
                  });
                  if (ctx.mounted) Navigator.pop(ctx);
                  _load(silent: true);
                } catch (e) {
                  if (ctx.mounted)
                    ScaffoldMessenger.of(
                      ctx,
                    ).showSnackBar(SnackBar(content: Text('$e')));
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    note.dispose();
  }


  Widget _overview(){
    final active=_licenses.where((l)=>l['revoked']!=true && (l['expiresAt'] as num? ?? 0)>_now).length;
    final expiring=_licenses.where((l)=>l['revoked']!=true && (l['expiresAt'] as num? ?? 0)>_now
      && (l['expiresAt'] as num? ?? 0)<=_now+30*86400000).length;
    final counts = _schools
        .map((school) => school['studentCount'])
        .whereType<int>()
        .where((count) => count >= 0)
        .toList();
    final totalStudents = counts.fold<int>(0, (total, count) => total + count);
    final missingCounts = _schools.length - counts.length;
    final studentTotal = _loading
        ? '—'
        : missingCounts == 0
        ? '$totalStudents'
        : '$totalStudents reported · $missingCounts missing';
    Widget counter(String label,Object number,IconData icon)=>_panel(
      Row(children:[
        Container(padding:const EdgeInsets.all(9),decoration:BoxDecoration(color:const Color(0xFFE8F2FF),borderRadius:BorderRadius.circular(12)),child:Icon(icon,size:20,color:_mint)),
        const SizedBox(width:10),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(label,style:const TextStyle(color:Color(0xFF637DA4),fontSize:11)),
          Text('$number',style:const TextStyle(fontSize:22,fontWeight:FontWeight.w800)),
        ])),
      ]),
    );
    return Column(children:[
      LayoutBuilder(builder:(context,size){
        final cols=size.maxWidth>=920?4:size.maxWidth>=480?2:1;
        final w=(size.maxWidth-(cols-1)*10)/cols;
        return Wrap(spacing:10,runSpacing:10,children:[
          SizedBox(width:w,child:counter('Total schools',_schools.length,Icons.apartment_outlined)),
          SizedBox(width:w,child:counter('Active licences',active,Icons.verified_outlined)),
          SizedBox(width:w,child:counter('Expiring in 30 days',expiring,Icons.schedule_outlined)),
          SizedBox(width:w,child:counter('Total Students',studentTotal,Icons.groups_outlined)),
        ]);
      }),
      const SizedBox(height:10),
      _panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Row(children:[
            const Expanded(child:Text('School health overview',style:TextStyle(fontSize:16,fontWeight:FontWeight.w800))),
            TextButton(onPressed:()=>setState(()=>_page=1),child:const Text('View all schools')),
          ]),
          if(_schools.isEmpty)const Text('No schools registered.'),
          for(final s in _schools.take(6))...[
            const Divider(height:1,color:Color(0xFFE5ECF8)),
            ListTile(dense:true,contentPadding:EdgeInsets.zero,
              leading:const Icon(Icons.school_outlined,color:_mint,size:19),
              title:Text(s['name']?.toString()??s['id']?.toString()??'School',maxLines:1,overflow:TextOverflow.ellipsis),
              subtitle:Text(s['loginEmail']?.toString()??s['id']?.toString()??''),
              trailing:_chip(s['blocked']==true?'Blocked':_active(s)?'Online':'Offline',
                s['blocked']==true?const Color(0xFFBD3549):_active(s)?const Color(0xFF058D68):const Color(0xFFA46B12)),
            )
          ]
      ])),
    ]);
  }
  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _setSchoolBlocked(Map<String, dynamic> school) async {
    final blocked = school['blocked'] == true;
    final yes = await _confirm(
      blocked ? 'Unblock this school?' : 'Block this school?',
      blocked
          ? 'The school can use a valid new licence or remaining trial after it is unblocked.'
          : 'Windows access will be blocked and existing licences for this school will be revoked. School records are not deleted.',
      blocked ? 'Unblock' : 'Block school',
    );
    if (!yes) return;
    try {
      await _call('school/block', {
        'schoolId': school['id'],
        'blocked': !blocked,
      });
      await _load(silent: true);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _deleteSchool(Map<String, dynamic> school) async {
    final yes = await _confirm(
      'Delete school from platform?',
      'This archives the school from this list and blocks its access. Existing school records and Drive files are preserved.',
      'Delete school',
    );
    if (!yes) return;
    try {
      await _call('school/delete', {'schoolId': school['id']});
      await _load(silent: true);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _schoolTable() => _panel(
    ManagedDeveloperPanel(
      schools: _schools,
      refresh: () => _load(silent: true),
      legacyDelete: _deleteSchool,
    ),
  );

  List<Map<String, dynamic>> _licenceReceipts(Map<String, dynamic> licence) {
    return _receipts
        .where((receipt) =>
            receipt['schoolId'] == licence['schoolId'] &&
            receipt['licenseId'] == licence['id'] &&
            receipt['at'] is num &&
            (receipt['at'] as num) > 0)
        .toList()
      ..sort((a, b) => (b['at'] as num).compareTo(a['at'] as num));
  }

  Future<void> _showLicenceHistory(
    List<Map<String, dynamic>> receipts,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Licence history'),
        content: SizedBox(
          width: 460,
          child: receipts.isEmpty
              ? const Text('No receipts are available for this licence.')
              : SizedBox(
                  height: 320,
                  child: ListView.builder(
                  itemCount: receipts.length,
                  itemBuilder: (_, index) {
                    final receipt = receipts[index];
                    final kind = receipt['type'] == 'renew' ? 'Extension' : 'Issue';
                    final amount = receipt['amount'];
                    final payment = receipt['paid'] == true ? 'Paid' : 'Unpaid';
                    return ListTile(
                      title: Text('$kind · ${_date(receipt['at'])}'),
                      subtitle: Text(
                        '$payment · ${amount is num ? _money(amount) : 'Amount unavailable'}'
                        '\nValid until ${_date(receipt['expiresAt'])}',
                      ),
                    );
                  },
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _licenceExpiry(dynamic value) {
    if (value is! num || value <= 0) return const Text('—');
    final date = DateTime.fromMillisecondsSinceEpoch(value.toInt());
    final time = TimeOfDay.fromDateTime(date).format(context);
    final remaining = date.difference(DateTime.fromMillisecondsSinceEpoch(_now.toInt()));
    final left = remaining.inDays > 0
        ? '${remaining.inDays}d ${remaining.inHours % 24}h left'
        : remaining.inHours > 0
            ? '${remaining.inHours}h ${remaining.inMinutes % 60}m left'
            : '${remaining.inMinutes.clamp(1, 59)}m left';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${_date(value)} · $time'),
        Text(remaining.inMilliseconds > 0 ? left : 'Expired',
            style: const TextStyle(fontSize: 11)),
      ],
    );
  }

  Widget _licenceTable() => _panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'School licences',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
            ),
            FilledButton.icon(
              onPressed: _issue,
              icon: const Icon(Icons.add),
              label: const Text('Generate licence'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (_licenses.isEmpty) const Text('No licences generated yet.'),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('SCHOOL')),
              DataColumn(label: Text('KEY')),
              DataColumn(label: Text('STATUS')),
              DataColumn(label: Text('EXPIRES')),
              DataColumn(label: Text('LAST PAYMENT')),
              DataColumn(label: Text('')),
            ],
            rows: _licenses
                .map(
                  (l) {
                    final receipts = _licenceReceipts(l);
                    final lastPayment = receipts.where((r) => r['paid'] == true).firstOrNull;
                    return DataRow(
                    cells: [
                      DataCell(Text(_schools.where((s)=>s['id']==l['schoolId']).map((s)=>s['name']?.toString()??'').where((s)=>s.isNotEmpty).firstOrNull??l['schoolId'].toString())),
                      DataCell(
                        Row(mainAxisSize:MainAxisSize.min,children:[
                          Text('•••• ${l['keyHint'] ?? l['keySuffix'] ?? '—'}'),
                          IconButton(
                            key:ValueKey('copy-license-${l['id']}'),
                            tooltip:_issuedSessionKeys[l['id']] == null
                               ? 'Full key is only available at issuance; older full keys were never stored.'
                               : 'Copy newly generated full licence key',
                            icon:const Icon(Icons.copy_outlined,size:17),
                            onPressed:_issuedSessionKeys[l['id']] == null
                               ? null : () async {
                                final key=_issuedSessionKeys[l['id']]!;
                                await Clipboard.setData(ClipboardData(text:key));
                               },
                          ),
                        ]),
                      ),
                      DataCell(
                        _chip(
                          l['revoked'] != true && (l['expiresAt'] as num) > _now
                              ? 'Active'
                              : 'Expired / revoked',
                          l['revoked'] != true && (l['expiresAt'] as num) > _now
                              ? _mint
                              : Colors.orangeAccent,
                        ),
                      ),
                      DataCell(_licenceExpiry(l['expiresAt'])),
                      DataCell(
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(lastPayment != null
                                ? (lastPayment['amount'] is num
                                    ? _money(lastPayment['amount'] as num)
                                    : 'Paid · amount unavailable')
                                : l['paid'] == true
                                    ? (l['amount'] is num
                                        ? 'INR ${l['amount']}'
                                        : 'Paid · amount not recorded')
                                    : 'Unpaid'),
                            Text(lastPayment == null ? 'Date unavailable' : _date(lastPayment['at']),
                                style: const TextStyle(fontSize: 11)),
                          ],
                        ),
                      ),
                      DataCell(
                        Row(
                          mainAxisSize:MainAxisSize.min,
                          children: [
                            if(l['revoked']!=true && _schools.any((s)=>s['id']==l['schoolId']&&
                              (s['licenseId']??s['activeLicenseHash'])==l['id']&&s['blocked']!=true&&s['deletedAt']==null) &&
                              l['expiresAt'] is num && (l['expiresAt'] as num)>_now)
                              for(final duration in const [(30,'30d'),(90,'90d'),(365,'12m')])
                                TextButton(
                                  onPressed:()=>_issue(l['schoolId'].toString(),duration.$1),
                                  child:Text(duration.$2),
                                ),
                            if (_schools.any((s) =>
                                s['id'] == l['schoolId'] &&
                                (s['licenseId'] ?? s['activeLicenseHash']) == l['id'] &&
                                s['blocked'] != true && s['loginDisabled'] != true &&
                                s['deletedAt'] == null) &&
                                (l['revoked'] == true ||
                                    l['expiresAt'] is num && (l['expiresAt'] as num) <= _now))
                              TextButton(
                                onPressed: () => _issue(l['schoolId'].toString()),
                                child: const Text('New Key'),
                              ),
                            TextButton(
                              onPressed: () => _showLicenceHistory(receipts),
                              child: const Text('History'),
                            ),
                            TextButton(
                              onPressed: l['revoked'] == true
                                  ? null
                                  : () async {
                                      final yes = await _confirm(
                                        'Revoke this licence?',
                                        'This school will lose paid access. Its records will remain intact.',
                                        'Revoke',
                                      );
                                      if (yes) {
                                        try {
                                          await _call('license/revoke', {
                                            'licenseId': l['id'],
                                          });
                                          await _load(silent: true);
                                        } catch (e) {
                                          if (mounted)
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              SnackBar(content: Text('$e')),
                                            );
                                        }
                                      }
                                    },
                              child: const Text('Revoke Licence'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    );
                  },
                )
                .toList(),
          ),
        ),
      ],
    ),
  );

  // Receipts are immutable licence purchase records, not school fee collections.
  // Older installations have no receipt ledger; do not invent historic revenue.
  String _money(num amount) => '₹${amount.toStringAsFixed(0)}';

  Widget _earnings() {
    final now=DateTime.now();
    final cutoff=_earningsDays==0?0:now.subtract(Duration(days:_earningsDays)).millisecondsSinceEpoch;
    final schoolIds=_schools.map((s)=>s['id']?.toString()??'').where((s)=>s.isNotEmpty).toSet();
    final schoolNames={for(final s in _schools) s['id']?.toString()??'':s['name']?.toString()??s['id']?.toString()??''};
    final visible=_receipts.where((r){
      final at=(r['at'] as num?)?.toInt()??0;
      return at>0 && at>=cutoff && (_earningsSchool=='all'||r['schoolId']==_earningsSchool);
    }).toList()..sort((a,b)=>((b['at'] as num?)?.toInt()??0).compareTo((a['at'] as num?)?.toInt()??0));
    final paid=visible.where((r)=>r['paid']==true).toList();
    num total=0, pending=0;
    for(final r in visible) {
      final value=r['amount'] is num?(r['amount'] as num):0;
      if(value<0)continue;
      if(r['paid']==true)total+=value;else pending+=value;
    }
    final bySchool=<String,num>{};
    for(final r in paid) {
      final id=r['schoolId']?.toString()??'';
      final amount=r['amount'] is num?(r['amount'] as num):0;
      if(id.isEmpty||amount<0)continue;
      bySchool[id]=(bySchool[id]??0)+amount;
    }
    final ranking=bySchool.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));
    final largest=ranking.isEmpty?1.0:max(1.0,ranking.first.value.toDouble());
    final dated=paid.map((r)=>(r['at'] as num?)?.toInt()??0).where((d)=>d>0).toList();
    final earliest=dated.isEmpty?now.millisecondsSinceEpoch:dated.reduce(min);
    final date=DateTime.fromMillisecondsSinceEpoch(earliest);
    final firstDay=DateTime(date.year,date.month,date.day);
    final lastDay=DateTime(now.year,now.month,now.day);
    final chartDays=_earningsDays==0?max(1,lastDay.difference(firstDay).inDays+1):_earningsDays;
    final startDay=DateTime(now.year,now.month,now.day).subtract(Duration(days:chartDays-1));
    final buckets=List<double>.filled(chartDays,0);
    for(final r in paid){
      final at=(r['at'] as num?)?.toInt()??0;
      if(at<=0)continue;
      final date=DateTime.fromMillisecondsSinceEpoch(at);
      final day=DateTime(date.year,date.month,date.day);
      final delta=day.difference(startDay).inDays;
      if(delta>=0&&delta<chartDays) buckets[delta]+=(r['amount'] as num?)?.toDouble()??0;
    }
    Widget metric(String name,String value,IconData icon){
      return _panel(Row(children:[
        Container(padding:const EdgeInsets.all(8),decoration:BoxDecoration(color:const Color(0xFFE9F2FF),borderRadius:BorderRadius.circular(12)),child:Icon(icon,color:_mint,size:19)),
        const SizedBox(width:10),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(name,style:const TextStyle(color:Color(0xFF637DA4),fontSize:11)),
          const SizedBox(height:3),
          Text(value,style:const TextStyle(fontSize:21,fontWeight:FontWeight.w800)),
        ]))
      ]));
    }
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('School licence earnings • recorded receipts only',style:TextStyle(color:Color(0xFF637DA4),fontSize:12)),
      const SizedBox(height:10),
      LayoutBuilder(builder:(context,size){
        final columns=size.maxWidth>=950?4:size.maxWidth>=460?2:1;
        final w=(size.maxWidth-(columns-1)*10)/columns;
        return Wrap(spacing:10,runSpacing:10,children:[
          SizedBox(width:w,child:metric('Paid receipts',_money(total),Icons.account_balance_wallet_outlined)),
          SizedBox(width:w,child:metric('Recorded payments','${paid.length}',Icons.receipt_long_outlined)),
          SizedBox(width:w,child:metric('Unpaid recorded',_money(pending),Icons.schedule_outlined)),
          SizedBox(width:w,child:metric('Schools with payments','${ranking.length}',Icons.school_outlined)),
        ]);
      }),
      const SizedBox(height:10),
      _panel(Wrap(spacing:12,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
        const Text('Period',style:TextStyle(fontWeight:FontWeight.w600)),
        DropdownButton<int>(value:_earningsDays,items:const[
          DropdownMenuItem(value:7,child:Text('Last 7 days')),
          DropdownMenuItem(value:30,child:Text('Last 30 days')),
          DropdownMenuItem(value:90,child:Text('Last 90 days')),
          DropdownMenuItem(value:365,child:Text('Last 12 months')),
          DropdownMenuItem(value:0,child:Text('All loaded receipts')),
        ],onChanged:(v)=>setState(()=>_earningsDays=v??30)),
        const Text('School',style:TextStyle(fontWeight:FontWeight.w600)),
        DropdownButton<String>(value:schoolIds.contains(_earningsSchool)?_earningsSchool:'all',items:[
          const DropdownMenuItem(value:'all',child:Text('All schools')),
          for(final s in _schools) if(s['id']!=null)
            DropdownMenuItem(value:s['id'].toString(),child:Text(s['name']?.toString()??s['id'].toString())),
        ],onChanged:(v)=>setState(()=>_earningsSchool=v??'all')),
        const Text('Only paid licence receipts count as earnings.',style:TextStyle(color:Color(0xFF637DA4),fontSize:11)),
      ])),
      const SizedBox(height:10),
      LayoutBuilder(builder:(context,size){
        final wide=size.maxWidth>=850;
        final left=_panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('Earnings by date',style:TextStyle(fontWeight:FontWeight.w800,fontSize:16)),
          const SizedBox(height:5),
          SizedBox(height:158,child:CustomPaint(painter:_EarningsLinePainter(buckets),child:const SizedBox.expand())),
          const SizedBox(height:3),
          Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[
            Text(_date(startDay.millisecondsSinceEpoch),style:const TextStyle(fontSize:10,color:Color(0xFF637DA4))),
            Text(_date(DateTime.now().millisecondsSinceEpoch),style:const TextStyle(fontSize:10,color:Color(0xFF637DA4))),
          ])
        ]));
        final right=_panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          const Text('School-wise earnings',style:TextStyle(fontWeight:FontWeight.w800,fontSize:16)),
          const SizedBox(height:10),
          if(ranking.isEmpty) const Text('No recorded paid licences in this period.',style:TextStyle(color:Color(0xFF637DA4))),
          for(final e in ranking.take(5))...[
            Row(children:[Expanded(child:Text(schoolNames[e.key]??e.key,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(fontSize:11,fontWeight:FontWeight.w700))),Text(_money(e.value),style:const TextStyle(fontSize:11))]),
            const SizedBox(height:4),
            ClipRRect(borderRadius:BorderRadius.circular(4),child:LinearProgressIndicator(value:(e.value/largest).clamp(0.0,1.0).toDouble(),minHeight:7,color:_mint,backgroundColor:const Color(0xFFE0EAF8))),
            const SizedBox(height:9),
          ]
        ]));
        return wide?Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Expanded(flex:6,child:left),const SizedBox(width:10),Expanded(flex:4,child:right),
        ]):Column(children:[left,const SizedBox(height:10),right]);
      }),
      const SizedBox(height:10),
      _panel(Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[
          const Expanded(child:Text('Payment history',style:TextStyle(fontSize:16,fontWeight:FontWeight.w800))),
          Text('Latest ${min(visible.length,10)} / ${visible.length} loaded',style:const TextStyle(fontSize:11,color:Color(0xFF637DA4))),
        ]),
        const SizedBox(height:7),
        if(visible.isEmpty)const Text('No recorded licence transactions for this selection. Older payments are not reconstructed.'),
        for(final r in visible.take(10))...[
          const Divider(height:1,color:Color(0xFFE5ECF8)),
          ListTile(dense:true,contentPadding:EdgeInsets.zero,
            title:Text(schoolNames[r['schoolId']]??r['schoolId']?.toString()??'Unknown school',maxLines:1,overflow:TextOverflow.ellipsis),
            subtitle:Text('${_date(r['at'])} • ${r['type']=='renew'?'Extension':'New licence'} • ${r['days']??'—'} days'),
            trailing:Column(mainAxisAlignment:MainAxisAlignment.center,crossAxisAlignment:CrossAxisAlignment.end,children:[
              Text(_money(r['amount'] is num?r['amount'] as num:0),style:const TextStyle(fontWeight:FontWeight.w700)),
              Text(r['paid']==true?'Recorded paid':'Unpaid',style:TextStyle(fontSize:10,color:r['paid']==true?const Color(0xFF078363):const Color(0xFFAE7216))),
            ]),
          ),
        ],
        const SizedBox(height:5),
        const Text('Historical receipts before this ledger was introduced may be unavailable. These amounts are manually marked as paid, not bank-verified.',style:TextStyle(color:Color(0xFF637DA4),fontSize:10)),
      ])),
    ]);
  }

  Widget _support() => _panel(
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DeveloperNotificationPanel(schools: _schools),
        const Text(
          'App complaints',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(
          value: _complaintSchool,
          decoration: const InputDecoration(labelText: 'Complaints for'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Select school')),
            const DropdownMenuItem(value: 'all', child: Text('All schools')),
            for (final school in _schools)
              DropdownMenuItem(
                value: school['id'].toString(),
                child: Text((school['name'] ?? school['id']).toString()),
              ),
          ],
          onChanged: (value) => setState(() => _complaintSchool = value ?? ''),
        ),
        if (_visibleComplaints.isEmpty)
          const Text(
            'No complaints received yet.',
            style: TextStyle(color: const Color(0xFF647899)),
          ),
        ..._visibleComplaints.map(
          (c) => ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            leading: Icon(
              c['source'] == 'windows'
                  ? Icons.desktop_windows
                  : Icons.phone_android,
              color: _mint,
            ),
            title: Text(
              c['message'].toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${c['schoolId']} • ${c['role']} • ${_date(c['createdAt'])}',
            ),
            trailing: _chip(
              c['status'].toString(),
              c['status'] == 'resolved' ? _mint : Colors.orangeAccent,
            ),
            onTap: () => _complaint(c),
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final titles = [
      'Overview',
      'Schools',
      'Licences',
      'School Earnings',
      'App Themes',
      'Admin Profile',
      'Support',
      'Cloud Services',
    ];
    return Theme(
      data: ThemeData(useMaterial3:true,brightness:Brightness.light,
        colorScheme:ColorScheme.fromSeed(seedColor:_mint,brightness:Brightness.light),
        scaffoldBackgroundColor:_ink,
        textTheme:ThemeData.light().textTheme.apply(bodyColor:const Color(0xFF18335C),displayColor:const Color(0xFF18335C))),
      child: Scaffold(
        backgroundColor: _ink,
        body: LayoutBuilder(
          builder: (ctx, c) {
            final narrow = c.maxWidth < 850;
            final nav = Container(
              width: 218,
              color: const Color(0xFFF8FBFF),
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 18),
                  const Row(
                    children: [
                      Icon(Icons.school_rounded, color: _mint),
                      SizedBox(width: 10),
                      Text(
                        'Saarthi AI',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 7, bottom: 35),
                    child: Text(
                      'DEVELOPER PLATFORM',
                      style: TextStyle(
                        color: const Color(0xFF8195B2),
                        fontSize: 9,
                        letterSpacing: 1.8,
                      ),
                    ),
                  ),
                  ...List.generate(
                    titles.length,
                    (i) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        selected: _page == i,
                        selectedColor: _mint,
                        selectedTileColor: _mint.withOpacity(.1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(
                          [
                            Icons.grid_view_rounded,
                            Icons.school_outlined,
                            Icons.vpn_key_outlined,
                             Icons.bar_chart_rounded,
                             Icons.palette_outlined,
                             Icons.manage_accounts_outlined,
                             Icons.support_agent_rounded,
                             Icons.cloud_outlined,
                          ][i],
                        ),
                        title: Text(titles[i]),
                        onTap: () => setState(() => _page = i),
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    FirebaseAuth.instance.currentUser?.email ?? '',
                    style: const TextStyle(color: const Color(0xFF8195B2), fontSize: 11),
                  ),
                  TextButton.icon(
                    onPressed: () => FirebaseAuth.instance.signOut(),
                    icon: const Icon(Icons.logout, size: 16),
                    label: const Text('Sign out'),
                  ),
                ],
              ),
            );
            final main = Expanded(
              child: _page == 4
                  ? Padding(
                      padding: EdgeInsets.all(narrow ? 12 : 20),
                      child: Column(
                        children: [
                          if (narrow)
                            SizedBox(
                              height: 42,
                              child: Row(
                                children: [
                                  const Expanded(child: Text('Saarthi AI')),
                                  PopupMenuButton<int>(
                                    tooltip: 'Navigation',
                                    initialValue: _page,
                                    onSelected: (value) =>
                                        setState(() => _page = value),
                                    itemBuilder: (_) => List.generate(
                                      titles.length,
                                      (i) => PopupMenuItem(
                                        value: i,
                                        child: Text(titles[i]),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          const Expanded(child: DeveloperWindowsTheme()),
                        ],
                      ),
                    )
                  : ListView(
                padding: EdgeInsets.all(narrow ? 14 : 20),
                children: [
                  if (narrow)
                    Wrap(
                      spacing: 8,
                      children: List.generate(
                        titles.length,
                        (i) => ChoiceChip(
                          label: Text(titles[i]),
                          selected: _page == i,
                          onSelected: (_) => setState(() => _page = i),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              titles[_page],
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -.5,
                              ),
                            ),
                            const SizedBox(height: 7),
                            const Text(
                              'Your schools. Their activity. One control centre.',
                              style: TextStyle(
                                color: const Color(0xFF647899),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => _load(),
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Refresh',
                      ),
                    ],
                  ),
                  const SizedBox(height: 30),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: _panel(
                        Text(
                          _error!,
                          style: const TextStyle(color: Colors.orangeAccent),
                        ),
                      ),
                    ),
                  if (_loading) const LinearProgressIndicator(),
                  if (!_loading) ...[
                    _page == 0
                        ? _overview()
                        : _page == 1
                        ? _schoolTable()
                        : _page == 2
                        ? _licenceTable()
                        : _page == 3
                        ? _earnings()
                        : _page == 5
                        ? const DeveloperAccountProfile()
                        : _page == 6
                        ? _support()
                        : const FirebaseMonitorPanel(),
                  ],
                  if (narrow)
                    TextButton(
                      onPressed: () => FirebaseAuth.instance.signOut(),
                      child: const Text('Sign out'),
                    ),
                ],
              ),
            );
            return Row(children: [
              if (!narrow) _page==4 ? SizedBox(width:230,child:FittedBox(
                fit:BoxFit.contain,alignment:Alignment.topCenter,
                child:SizedBox(width:230,height:c.maxHeight<700?700:c.maxHeight,child:nav),
              )) : nav,
              main,
            ]);
          },
        ),
      ),
    );
  }
}

class _EarningsLinePainter extends CustomPainter {
  const _EarningsLinePainter(this.values);
  final List<double> values;
  @override
  void paint(Canvas canvas,Size size){
    final grid=Paint()..color=const Color(0xFFDCE7F7)..strokeWidth=1;
    final line=Paint()..color=const Color(0xFF1268F3)..strokeWidth=2.5..style=PaintingStyle.stroke..strokeCap=StrokeCap.round;
    for(var i=1;i<=3;i++){final y=size.height*i/4;canvas.drawLine(Offset(0,y),Offset(size.width,y),grid);}
    if(values.isEmpty)return;
    final highest=values.fold<double>(1,(v,x)=>max(v,x));
    final points=<Offset>[];
    for(var i=0;i<values.length;i++){
      final x=values.length==1?size.width/2:size.width*i/(values.length-1);
      final y=size.height-8-(values[i]/highest)*(size.height-18);
      points.add(Offset(x,y));
    }
    final path=Path()..moveTo(points.first.dx,points.first.dy);
    for(final point in points.skip(1))path.lineTo(point.dx,point.dy);
    canvas.drawPath(path,line);
    if(points.length<=35){
      final dot=Paint()..color=const Color(0xFF1268F3);
      for(final p in points)canvas.drawCircle(p,2.5,dot);
    }
  }
  @override
  bool shouldRepaint(covariant _EarningsLinePainter old)=>old.values!=values;
}
