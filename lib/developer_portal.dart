import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'platform/developer_service.dart';

const _ink = Color(0xFF101B24),
    _surface = Color(0xFF16242E),
    _mint = Color(0xFF63E6BE);

class DeveloperPortal extends StatelessWidget {
  const DeveloperPortal({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, s) {
        if (s.connectionState == ConnectionState.waiting)
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        return s.data == null
            ? const _DeveloperLogin()
            : _DeveloperAccess(user: s.data!);
      });
}

class _DeveloperAccess extends StatelessWidget {
  const _DeveloperAccess({required this.user});
  final User user;
  @override
  Widget build(BuildContext context) => FutureBuilder<IdTokenResult>(
      future: user.getIdTokenResult(true),
      builder: (context, s) {
        if(s.hasError) return Scaffold(body:Center(child:TextButton(
          onPressed:()=>FirebaseAuth.instance.signOut(),child:const Text('Sign in again to verify developer access'))));
        if (!s.hasData)
          return const Scaffold(
              body: Center(child: CircularProgressIndicator()));
        if (s.data!.claims?['admin'] != true &&
            s.data!.claims?['developer'] != true)
          return Scaffold(
              body: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 16),
            const Text('Developer access required'),
            const Text('School accounts do not have access to this website.'),
            TextButton(
                onPressed: () => FirebaseAuth.instance.signOut(),
                child: const Text('Sign out'))
          ])));
        return const _DeveloperDashboard();
      });
}

class _DeveloperLogin extends StatefulWidget {
  const _DeveloperLogin();
  @override
  State<_DeveloperLogin> createState() => _DeveloperLoginState();
}

class _DeveloperLoginState extends State<_DeveloperLogin> {
  final _email = TextEditingController(), _password = TextEditingController();
  bool _busy = false, _show = false;
  String? _error;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: _email.text.trim(), password: _password.text);
    } on FirebaseAuthException catch (e) {
      if (mounted)
        setState(() => _error = e.code == 'invalid-credential'
            ? 'Check your ID and password.'
            : 'Sign-in unavailable. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: _ink,
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Align(
                            alignment: Alignment.centerLeft,
                            child: Icon(Icons.hub_rounded,
                                size: 44, color: _mint)),
                        const SizedBox(height: 28),
                        const Text('Vidya Saarthi',
                            style: TextStyle(
                                fontSize: 31,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1)),
                        const SizedBox(height: 8),
                        const Text('Developer control centre',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 17)),
                        const SizedBox(height: 36),
                        TextField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            decoration: const InputDecoration(
                                labelText: 'Developer ID / Email',
                                prefixIcon: Icon(Icons.person_outline))),
                        const SizedBox(height: 16),
                        TextField(
                            controller: _password,
                            obscureText: !_show,
                            onSubmitted: (_) => _login(),
                            decoration: InputDecoration(
                                labelText: 'Password',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                    onPressed: () =>
                                        setState(() => _show = !_show),
                                    icon: Icon(_show
                                        ? Icons.visibility_off
                                        : Icons.visibility)))),
                        if (_error != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(_error!,
                                  style: const TextStyle(
                                      color: Colors.redAccent))),
                        const SizedBox(height: 24),
                        FilledButton(
                            onPressed: _busy ? null : _login,
                            child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Text(_busy
                                    ? 'Signing in…'
                                    : 'Open control centre'))),
                        const SizedBox(height: 24),
                        const Text(
                            'Licensing, school activity and app support in one place.',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 12))
                      ])))));
}

class _DeveloperDashboard extends StatefulWidget {
  const _DeveloperDashboard();
  @override
  State<_DeveloperDashboard> createState() => _DeveloperDashboardState();
}

class _DeveloperDashboardState extends State<_DeveloperDashboard> {
  final _service = DeveloperService();
  int _page = 0;
  String _search = '', _filter = 'all';
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _data = {};
  Timer? _timer;
  List<Map<String, dynamic>> get _schools => _maps(_data['schools']);
  List<Map<String, dynamic>> get _licenses => _maps(_data['licenses']);
  List<Map<String, dynamic>> get _complaints => _maps(_data['complaints']);
  List<Map<String, dynamic>> _maps(dynamic raw) => raw is List
      ? raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : [];
  Map<String, dynamic> get _stats =>
      Map<String, dynamic>.from(_data['summary'] ?? {});
  int get _now =>
      (_data['serverTime'] as num?)?.toInt() ??
      DateTime.now().millisecondsSinceEpoch;
  @override
  void initState() {
    super.initState();
    _load();
    _timer =
        Timer.periodic(const Duration(minutes: 5), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
      String action, Map<String, dynamic> body) async {
    return _service.call(action, body);
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final d = await _call('developer/dashboard', {'refresh': !silent});
      if (mounted)
        setState(() {
          _data = d;
          _error = null;
        });
    } catch (e) {
      if (mounted)
        setState(() => _error = e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _date(dynamic n) {
    final v = (n as num?)?.toInt() ?? 0;
    if (v <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(v);
    return '${d.day.toString().padLeft(2, '0')} ${const [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ][d.month - 1]} ${d.year}';
  }

  bool _active(Map s) => (s['lastSeenAt'] as num? ?? 0) >= _now - 86400000;
  bool _expiring(Map s) =>
      (s['licenseExpiresAt'] as num? ?? 0) > _now &&
      (s['licenseExpiresAt'] as num? ?? 0) <= _now + 14 * 86400000;
  Widget _chip(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
          color: color.withOpacity(.12),
          borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700)));
  Widget _panel(Widget child) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withOpacity(.06))),
      child: child);
  Future<void> _issue([String? selected]) async {
    if (_schools.isEmpty) {
      await _addSchool();
      return;
    }
    String school = selected ?? _schools.first['id'].toString();
    bool paid = true, busy = false;
    String? error;
    final days = TextEditingController(text: '365'),
        amount = TextEditingController(text: '0');
    final result = await showDialog<Map<String, dynamic>>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialog) => AlertDialog(
                    title: const Text('Create a school licence'),
                    content: SizedBox(
                        width: 420,
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              DropdownButtonFormField<String>(
                                  initialValue: school,
                                  decoration: const InputDecoration(
                                      labelText: 'School'),
                                  items: _schools
                                      .map((s) => DropdownMenuItem(
                                          value: s['id'].toString(),
                                          child: Text(s['name']?.toString() ??
                                              s['id'].toString())))
                                      .toList(),
                                  onChanged: busy
                                      ? null
                                      : (v) => setDialog(() => school = v!)),
                              const SizedBox(height: 16),
                              TextField(
                                  controller: days,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: 'Validity in days')),
                              const SizedBox(height: 16),
                              TextField(
                                  controller: amount,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                      labelText: 'Purchase amount (INR)')),
                              CheckboxListTile(
                                  contentPadding: EdgeInsets.zero,
                                  value: paid,
                                  onChanged: busy
                                      ? null
                                      : (v) => setDialog(() => paid = v!),
                                  title: const Text('Payment received')),
                              const Text(
                                  'The key will work only for this school. Share it manually after creation.',
                                  style: TextStyle(
                                      color: Colors.white54, fontSize: 12)),
                              if (error != null)
                                Text(error!,
                                    style: const TextStyle(
                                        color: Colors.redAccent))
                            ])),
                    actions: [
                      TextButton(
                          onPressed: busy ? null : () => Navigator.pop(ctx),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  setDialog(() {
                                    busy = true;
                                    error = null;
                                  });
                                  try {
                                    final r = await _call('license/issue', {
                                      'schoolId': school,
                                      'days': int.tryParse(days.text),
                                      'paid': paid,
                                      'amount':
                                          double.tryParse(amount.text) ?? 0
                                    });
                                    if (ctx.mounted) Navigator.pop(ctx, r);
                                  } catch (e) {
                                    setDialog(() {
                                      busy = false;
                                      error = e.toString();
                                    });
                                  }
                                },
                          child: Text(busy ? 'Creating…' : 'Generate key'))
                    ])));
    days.dispose();
    amount.dispose();
    if (result == null || !mounted) return;
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
                      SelectableText(result['key'].toString(),
                          style: const TextStyle(
                              color: _mint,
                              fontSize: 18,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      Text('Valid until ${_date(result['expiresAt'])}'),
                      if (result['setup'] != null) ...[
                        const SizedBox(height: 12),
                        const Text('Copy the school setup too. Paste it into this school’s Google Script only.'),
                      ],
                    ]),
                actions: [
                  TextButton(
                      onPressed: () => Clipboard.setData(
                          ClipboardData(text: result['key'].toString())),
                      child: const Text('Copy key')),
                  if (result['setup'] != null) TextButton(
                    onPressed: () => _copySetup(result['setup']),
                    child: const Text('Copy school setup')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Done'))
                ]));
    _load(silent: true);
  }

  Future<void> _copySetup(dynamic setup) async {
    // All values are generated alphanumeric strings or a validated project ID.
    final s = Map<String,dynamic>.from(setup);
    final fields = s.entries.map((e) => "${e.key}: '${e.value}'").join(',\n  ');
    await Clipboard.setData(ClipboardData(text: "function setupSchoolMonitoring() {\n  return VS_setupPlatform({\n  $fields\n  });\n}"));
  }

  Future<void> _addSchool() async {
    final project = TextEditingController(), name = TextEditingController();
    bool busy = false;
    String? error;
    final result = await showDialog<Map<String,dynamic>>(context: context,
      barrierDismissible:false, builder:(ctx) => StatefulBuilder(builder:(ctx,setD) => AlertDialog(
        title:const Text('School monitoring setup'),
        content:SizedBox(width:420,child:Column(mainAxisSize:MainAxisSize.min,children:[
          TextField(controller:name,decoration:const InputDecoration(labelText:'School name')),
          const SizedBox(height:16),
          TextField(controller:project,decoration:const InputDecoration(labelText:'School Firebase project ID')),
          const SizedBox(height:16),
          const Text('Copy the setup into that school’s Google Script. Generating it again replaces the previous monitoring credentials.'),
          if(error!=null) Text(error!,style:const TextStyle(color:Colors.redAccent)),
        ])),
        actions:[
          TextButton(onPressed:busy?null:()=>Navigator.pop(ctx),child:const Text('Cancel')),
          FilledButton(onPressed:busy?null:() async {
            setD(() {busy=true;error=null;});
            try {
              final r=await _call('school/create',{'schoolId':project.text.trim(),'schoolName':name.text.trim(),'replaceMonitor':true});
              if(ctx.mounted) Navigator.pop(ctx,r);
            }catch(e){setD((){busy=false;error=e.toString();});}
          },child:Text(busy?'Creating…':'Generate setup')),
        ],
      )));
    project.dispose();name.dispose();
    if(result==null||!mounted) return;
    await showDialog(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('School setup ready'),
      content:const Text('Copy this now and run it as the owner in the school’s Google Script. These credentials can send only that school’s summary and support reports.'),
      actions:[TextButton(onPressed:()=>_copySetup(result['setup']),child:const Text('Copy setup')),
        FilledButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Done'))],
    ));
    await _load();
  }

  Future<void> _complaint(Map<String, dynamic> c) async {
    String status = c['status']?.toString() ?? 'open';
    final note =
        TextEditingController(text: c['developerNote']?.toString() ?? '');
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
                              const SizedBox(height: 20),
                              DropdownButtonFormField<String>(
                                  initialValue: status,
                                  items: const [
                                    DropdownMenuItem(
                                        value: 'open', child: Text('Open')),
                                    DropdownMenuItem(
                                        value: 'in_progress',
                                        child: Text('In progress')),
                                    DropdownMenuItem(
                                        value: 'resolved',
                                        child: Text('Resolved'))
                                  ],
                                  onChanged: (v) => setD(() => status = v!)),
                              const SizedBox(height: 16),
                              TextField(
                                  controller: note,
                                  maxLines: 3,
                                  decoration: const InputDecoration(
                                      labelText: 'Developer note'))
                            ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('Close')),
                      FilledButton(
                          onPressed: () async {
                            try {
                              await _call('complaint/update', {
                                'complaintId': c['id'],
                                'status': status,
                                'note': note.text
                              });
                              if (ctx.mounted) Navigator.pop(ctx);
                              _load(silent: true);
                            } catch (e) {
                              if (ctx.mounted)
                                ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(content: Text('$e')));
                            }
                          },
                          child: const Text('Save'))
                    ])));
    note.dispose();
  }

  Widget _overview() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LayoutBuilder(builder: (ctx, c) {
          final width =
              c.maxWidth > 1000 ? (c.maxWidth - 48) / 4 : (c.maxWidth - 16) / 2;
          final stats = [
            ('Active schools', 'activeSchools', Icons.school_outlined, _mint),
            (
              'Inactive schools',
              'inactiveSchools',
              Icons.pause_circle_outline,
              Colors.orangeAccent
            ),
            (
              'Student app users',
              'studentAppUsers',
              Icons.people_outline,
              Colors.lightBlueAccent
            ),
            (
              'Students online now',
              'studentsOnline',
              Icons.sensors,
              Colors.purpleAccent
            ),
            ('Total schools', 'totalSchools', Icons.apartment, Colors.white70),
            (
              'Purchased licences',
              'purchasedSchools',
              Icons.verified_outlined,
              _mint
            ),
            (
              'Expiry in 14 days',
              'expiringSchools',
              Icons.event_busy,
              Colors.orangeAccent
            )
          ];
          return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: stats
                  .map((v) => SizedBox(
                      width: width,
                      child: _panel(Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(v.$3, color: v.$4, size: 24),
                            const SizedBox(height: 22),
                            Text('${_stats[v.$2] ?? '—'}',
                                style: const TextStyle(
                                    fontSize: 33, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 5),
                            Text(v.$1,
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12))
                          ]))))
                  .toList());
        }),
        const SizedBox(height: 26),
        _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Licences approaching expiry',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          if (_schools.where(_expiring).isEmpty)
            const Text('No licences expire in the next 14 days.',
                style: TextStyle(color: Colors.white54)),
          ..._schools.where(_expiring).map((s) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s['name']?.toString() ?? s['id'].toString()),
              subtitle: Text(_date(s['licenseExpiresAt'])),
              trailing: TextButton(
                  onPressed: () => _issue(s['id'].toString()),
                  child: const Text('Renew'))))
        ])),
        const SizedBox(height: 16),
        const Text(
            'Active schools: a school summary in the past 24 hours. Online students: estimated recent activity, refreshed every 5 minutes. Student app users are counted by each school; individual sessions stay at the school.',
            style: TextStyle(color: Colors.white38, fontSize: 11))
      ]);
  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
          ],
        ),
      ) ?? false;

  Future<void> _deleteLicence(Map<String, dynamic> licence) async {
    final yes = await _confirm(
      'Delete this licence?',
      'This permanently removes the selected licence from the developer dashboard. The key will stop working. School records are not deleted.',
      'Delete licence',
    );
    if (!yes) return;
    try {
      await _call('license/delete', {'licenseId': licence['id']});
      await _load(silent: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

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
      await _call('school/block', {'schoolId': school['id'], 'blocked': !blocked});
      await _load(silent: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _deleteSchool(Map<String, dynamic> school) async {
    final yes = await _confirm(
      'Delete school from platform?',
      'This removes this school, its developer-platform licences, monitoring summary and support records. It does NOT delete the school\'s operational/student data.',
      'Delete school',
    );
    if (!yes) return;
    try {
      await _call('school/delete', {'schoolId': school['id']});
      await _load(silent: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _schoolTable() {
    final list = _schools.where((s) {
      final text = '${s['name']} ${s['id']}'.toLowerCase();
      return text.contains(_search.toLowerCase()) &&
          (_filter == 'all' ||
              _filter == 'active' && _active(s) ||
              _filter == 'inactive' && !_active(s) ||
              _filter == 'expiring' && _expiring(s) ||
              _filter == 'purchased' && s['purchased'] == true);
    }).toList();
    return _panel(
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        OutlinedButton.icon(onPressed: _addSchool, icon: const Icon(Icons.add),
          label: const Text('School setup')),
        SizedBox(
            width: 300,
            child: TextField(
                onChanged: (v) => setState(() => _search = v),
                decoration: const InputDecoration(
                    hintText: 'Search school / project',
                    prefixIcon: Icon(Icons.search)))),
        DropdownButton<String>(
            value: _filter,
            items: const ['all', 'active', 'inactive', 'expiring', 'purchased']
                .map((v) =>
                    DropdownMenuItem(value: v, child: Text(v.toUpperCase())))
                .toList(),
            onChanged: (v) => setState(() => _filter = v!))
      ]),
      const SizedBox(height: 20),
      if (list.isEmpty)
        const Padding(
            padding: EdgeInsets.all(24),
            child: Text('No schools match this view.')),
      SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
              columns: const [
                DataColumn(label: Text('SCHOOL')),
                DataColumn(label: Text('ACTIVITY')),
                DataColumn(label: Text('STUDENTS')),
                DataColumn(label: Text('WINDOWS')),
                DataColumn(label: Text('LICENCE EXPIRY')),
                DataColumn(label: Text('ACTION'))
              ],
              rows: list
                  .map((s) => DataRow(cells: [
                        DataCell(Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(s['name']?.toString() ?? s['id'].toString()),
                              Text(s['id'].toString(),
                                  style: const TextStyle(
                                      fontSize: 10, color: Colors.white38))
                            ])),
                        DataCell(_chip(_active(s) ? 'Active' : 'Inactive',
                            _active(s) ? _mint : Colors.orangeAccent)),
                        DataCell(Text('${s['studentCount'] ?? 0}')),
                        DataCell(Text(s['windowsVersion']?.toString() ?? '—')),
                        DataCell(Text(_date(s['licenseExpiresAt']))),
                        DataCell(Wrap(spacing: 4, children: [
                          TextButton(
                              onPressed: () => _issue(s['id'].toString()),
                              child: const Text('Create licence')),
                          TextButton(
                              onPressed: () => _setSchoolBlocked(s),
                              child: Text(s['blocked'] == true ? 'Unblock' : 'Block')),
                          TextButton(
                              onPressed: () => _deleteSchool(s),
                              child: const Text('Delete',
                                  style: TextStyle(color: Colors.redAccent))),
                        ]))
                      ]))
                  .toList()))
    ]));
  }

  Widget _licenceTable() =>
      _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
              child: Text('School licences',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
          FilledButton.icon(
              onPressed: _issue,
              icon: const Icon(Icons.add),
              label: const Text('Generate licence'))
        ]),
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
                  DataColumn(label: Text('PURCHASE')),
                  DataColumn(label: Text(''))
                ],
                rows: _licenses
                    .map((l) => DataRow(cells: [
                          DataCell(Text(l['schoolId'].toString())),
                          DataCell(Text('•••• ${l['keyHint'] ?? l['keySuffix'] ?? '—'}')),
                          DataCell(_chip(
                              l['revoked'] != true &&
                                      (l['expiresAt'] as num) > _now
                                  ? 'Active'
                                  : 'Expired / revoked',
                              l['revoked'] != true &&
                                      (l['expiresAt'] as num) > _now
                                  ? _mint
                                  : Colors.orangeAccent)),
                          DataCell(Text(_date(l['expiresAt']))),
                          DataCell(Text(l['paid'] == true
                              ? 'INR ${l['amount']}'
                              : 'Unpaid')),
                          DataCell(Wrap(spacing: 4, children: [
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
                                            await _call('license/revoke', {'licenseId': l['id']});
                                            await _load(silent: true);
                                          } catch (e) {
                                            if (mounted) ScaffoldMessenger.of(context)
                                                .showSnackBar(SnackBar(content: Text('$e')));
                                          }
                                        }
                                      },
                                child: const Text('Revoke')),
                            TextButton(
                                onPressed: () => _deleteLicence(l),
                                child: const Text('Delete',
                                    style: TextStyle(color: Colors.redAccent))),
                          ]))
                        ]))
                    .toList()))
      ]));
  Widget _support() =>
      _panel(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('App complaints',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 18),
        if (_complaints.isEmpty)
          const Text('No complaints received yet.',
              style: TextStyle(color: Colors.white54)),
        ..._complaints.map((c) => ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            leading: Icon(
                c['source'] == 'windows'
                    ? Icons.desktop_windows
                    : Icons.phone_android,
                color: _mint),
            title: Text(c['message'].toString(),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${c['schoolId']} • ${c['role']} • ${_date(c['createdAt'])}'),
            trailing: _chip(c['status'].toString(),
                c['status'] == 'resolved' ? _mint : Colors.orangeAccent),
            onTap: () => _complaint(c)))
      ]));
  @override
  Widget build(BuildContext context) {
    final titles = ['Overview', 'Schools', 'Licences', 'Support'];
    return Scaffold(
        backgroundColor: _ink,
        body: LayoutBuilder(builder: (ctx, c) {
          final narrow = c.maxWidth < 850;
          final nav = Container(
              width: 230,
              color: const Color(0xFF0C161E),
              padding: const EdgeInsets.all(18),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 18),
                    const Row(children: [
                      Icon(Icons.hub_rounded, color: _mint),
                      SizedBox(width: 10),
                      Text('Vidya Saarthi',
                          style: TextStyle(
                              fontWeight: FontWeight.w800, fontSize: 18))
                    ]),
                    const Padding(
                        padding: EdgeInsets.only(top: 7, bottom: 35),
                        child: Text('DEVELOPER PLATFORM',
                            style: TextStyle(
                                color: Colors.white38,
                                fontSize: 9,
                                letterSpacing: 1.8))),
                    ...List.generate(
                        titles.length,
                        (i) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                                selected: _page == i,
                                selectedColor: _mint,
                                selectedTileColor: _mint.withOpacity(.1),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                leading: Icon([
                                  Icons.grid_view_rounded,
                                  Icons.school_outlined,
                                  Icons.vpn_key_outlined,
                                  Icons.support_agent_rounded
                                ][i]),
                                title: Text(titles[i]),
                                onTap: () => setState(() => _page = i)))),
                    const Spacer(),
                    Text(FirebaseAuth.instance.currentUser?.email ?? '',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11)),
                    TextButton.icon(
                        onPressed: () => FirebaseAuth.instance.signOut(),
                        icon: const Icon(Icons.logout, size: 16),
                        label: const Text('Sign out'))
                  ]));
          final main = Expanded(
              child: ListView(
                  padding: EdgeInsets.all(narrow ? 20 : 36),
                  children: [
                if (narrow)
                  Wrap(
                      spacing: 8,
                      children: List.generate(
                          4,
                          (i) => ChoiceChip(
                              label: Text(titles[i]),
                              selected: _page == i,
                              onSelected: (_) => setState(() => _page = i)))),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(titles[_page],
                            style: const TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -.5)),
                        const SizedBox(height: 7),
                        const Text(
                            'Your schools. Their activity. One control centre.',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 13))
                      ])),
                  IconButton(
                      onPressed: () => _load(),
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh')
                ]),
                const SizedBox(height: 30),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: _panel(Text(_error!,
                          style: const TextStyle(color: Colors.orangeAccent)))),
                if (_loading) const LinearProgressIndicator(),
                if (!_loading) ...[
                  _page == 0
                      ? _overview()
                      : _page == 1
                          ? _schoolTable()
                          : _page == 2
                              ? _licenceTable()
                              : _support()
                ],
                if (narrow)
                  TextButton(
                      onPressed: () => FirebaseAuth.instance.signOut(),
                      child: const Text('Sign out'))
              ]));
          return Row(children: [if (!narrow) nav, main]);
        }));
  }
}
