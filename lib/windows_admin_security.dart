import 'dart:math';
import 'package:flutter/material.dart';

import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_local_settings.dart';
import 'windows_local_admin_security.dart';
import 'windows_local_firestore.dart';

/// Independent school-wide administrator credential. App Lock remains local.
class WindowsAdminSecurity {
  WindowsAdminSecurity._();
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static String? _panelSchool;
  static DateTime? _panelUntil;
  static int? _panelPasswordVersion;
  static String? _panelLocalFingerprint;
  static final Map<String,Map<String,String>> _localApprovalTickets={};
  static final Map<String,DateTime> _consumedActions={};

  static Future<String> _actionKey(String scope,String target) async {
    final saved=await CentralSchoolCloud.saved();
    final school=saved['managed']==true?saved['schoolId']?.toString():_standaloneScope();
    if(school==null||school.isEmpty)throw StateError('School context missing.');
    return '$scope|$target|$school';
  }

  static Future<void> _rememberConsumedAction(String scope,String target) async {
    final current=DateTime.now();
    _consumedActions.removeWhere((_,at)=>
      current.difference(at)>const Duration(minutes:2));
    if(_consumedActions.length>=64) {
      _consumedActions.clear();
    }
    _consumedActions[await _actionKey(scope,target)]=current;
  }

  static Future<void> requireConsumedAction({
    required String scope,
    required String target,
  }) async {
    final key=await _actionKey(scope,target);
    final approvedAt=_consumedActions.remove(key);
    if(approvedAt==null || DateTime.now().difference(approvedAt) >
        const Duration(minutes:2)) {
      throw StateError('A fresh independent Admin Password confirmation is required.');
    }
  }

  static void clearPanelSession() {
    _panelSchool=null;
    _panelUntil=null;
    _panelPasswordVersion=null;
    _panelLocalFingerprint=null;
    _localApprovalTickets.clear();
    _consumedActions.clear();
  }

  static String _standaloneScope() =>
    'local:${FirebaseFirestore.instance.activeProfileId}';

  static Future<bool> hasPanelSession() async {
    final saved=await CentralSchoolCloud.saved();
    final managed=saved['managed']==true;
    final scope=managed?saved['schoolId']?.toString():_standaloneScope();
    if(scope==null||scope.isEmpty||scope!=_panelSchool||
        _panelUntil==null||!DateTime.now().isBefore(_panelUntil!)){
      clearPanelSession();
      return false;
    }
    if(!managed){
      final fingerprint=await WindowsLocalAdminSecurity.fingerprint();
      if(fingerprint==null||fingerprint!=_panelLocalFingerprint) {
        clearPanelSession();
        return false;
      }
      return true;
    }
    // Verify again at every new Admin navigation; another PC can rotate it.
    final remote=await _call({'operation':'status'});
    if(remote['configured']!=true||remote['updatedAt']!=_panelPasswordVersion){
      clearPanelSession();
      return false;
    }
    return true;
  }

  static Future<void> grantPanelSession() async {
    final saved=await CentralSchoolCloud.saved();
    if(saved['managed']!=true){
      final fingerprint=await WindowsLocalAdminSecurity.fingerprint();
      if(fingerprint==null)throw StateError('Set local Admin Password first.');
      _panelSchool=_standaloneScope();
      _panelLocalFingerprint=fingerprint;
      _panelUntil=DateTime.now().add(const Duration(minutes:15));
      return;
    }
    if(saved['schoolId'] is! String)
      throw StateError('Managed school identity is missing.');
    final status=await _call({'operation':'status'});
    if(status['configured']!=true||status['updatedAt'] is! int)
      throw StateError('Independent Admin Password status is not verified.');
    _panelSchool=saved['schoolId'];
    _panelPasswordVersion=status['updatedAt'];
    _panelUntil=DateTime.now().add(const Duration(minutes:15));
  }

  static Future<bool> get isManaged async =>
      (await CentralSchoolCloud.saved())['managed'] == true;

  static Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    final result = await ManagedSchoolSession.call('managed/admin/security', body);
    if (result['success'] != true) {
      throw StateError('School administrator authorization was not verified.');
    }
    return result;
  }

  static Future<bool> configured() async {
    if(!await isManaged)return WindowsLocalAdminSecurity.configured();
    return (await _call({'operation':'status'}))['configured']==true;
  }

  static Future<void> enroll({
    required String schoolPassword,
    required String newPassword,
  }) async {
    if(!await isManaged){
      await WindowsLocalAdminSecurity.enroll(newPassword);
      clearPanelSession();
      revision.value++;
      return;
    }
    final fresh = await ManagedSchoolSession.freshSchoolPasswordProof(schoolPassword);
    final result = await _call({
      'operation':'enroll', 'freshIdToken':fresh, 'newPassword':newPassword,
    });
    if(result['configured'] != true) {
      throw StateError('The school Admin Password was not registered.');
    }
    clearPanelSession();
    revision.value++;
  }

  static Future<void> unlock(String password) async {
    if(!await isManaged){
      await WindowsLocalAdminSecurity.verify(password);
      return;
    }
    final result = await _call({'operation':'unlock','password':password});
    if(result['verified'] != true || result['scope'] != 'admin-panel') {
      throw StateError('Admin Panel verification was not confirmed.');
    }
  }

  static Future<String> approve({
    required String password,
    required String scope,
    required String target,
  }) async {
    if(!await isManaged){
      if(!{'drive-connection','person-delete','force-promotion','protected-settings'}.contains(scope)||
          target.isEmpty||target.length>1000)
        throw StateError('Invalid protected school action.');
      await WindowsLocalAdminSecurity.verify(password);
      final now=DateTime.now().millisecondsSinceEpoch;
      _localApprovalTickets.removeWhere((_,value)=>
        (int.tryParse(value['issuedAt']??'')??0)<now-120000);
      if(_localApprovalTickets.length>=32)
        throw StateError('Too many pending administrator confirmations.');
      final rng=Random.secure();
      final token=List<String>.generate(32,
        (_)=>rng.nextInt(256).toRadixString(16).padLeft(2,'0')).join();
      _localApprovalTickets[token]={
        'scope':scope,'target':target,'school':_standaloneScope(),
        'issuedAt':now.toString(),
      };
      return token;
    }
    final result = await _call({
      'operation':'authorize','password':password,'scope':scope,'target':target,
    });
    final token = result['approvalToken'];
    if(result['authorized'] != true || token is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw StateError('Protected action approval was not confirmed.');
    }
    return token;
  }

  /// One-time school authorization is consumed before a protected local action.
  static Future<void> consumeApproval({
    required String token,
    required String scope,
    required String target,
  }) async {
    if(!await isManaged){
      final ticket=_localApprovalTickets.remove(token);
      final issuedAt=int.tryParse(ticket?['issuedAt']??'')??0;
      if(ticket==null||ticket['scope']!=scope||
         ticket['target']!=target||ticket['school']!=_standaloneScope()||
         DateTime.now().millisecondsSinceEpoch-issuedAt>120000)
        throw StateError('Local Admin Password approval is missing or expired.');
      await _rememberConsumedAction(scope,target);
      return;
    }
    if(token.length != 64 || !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw StateError('Missing school administrator authorization.');
    }
    final result=await _call({
      'operation':'consume','approvalToken':token,
      'scope':scope,'target':target,
    });
    if(result['authorized'] != true) {
      throw StateError('School Admin approval was not accepted by the backend.');
    }
    await _rememberConsumedAction(scope,target);
  }

  static Future<void> change({
    required String currentPassword,
    required String newPassword,
  }) async {
    if(!await isManaged){
      await WindowsLocalAdminSecurity.change(currentPassword,newPassword);
    }else{
      await _call({
        'operation':'change','password':currentPassword,'newPassword':newPassword,
      });
    }
    clearPanelSession();
    revision.value++;
  }

  static Future<void> recover({
    required String schoolPassword,
    required String newPassword,
  }) async {
    if(!await isManaged)
      throw StateError('Standalone Admin Password recovery requires school owner verification; no App Lock reset bypass is available.');
    final fresh = await ManagedSchoolSession.freshSchoolPasswordProof(schoolPassword);
    await _call({
      'operation':'recover','freshIdToken':fresh,'newPassword':newPassword,
    });
    clearPanelSession();
    revision.value++;
  }
}

/// A real independent gate AFTER the Windows App Lock. No local bypass in
/// managed schools, and no admin credential is written to Windows storage.
class WindowsAdminSecurityGate extends StatefulWidget {
  const WindowsAdminSecurityGate({super.key, required this.child});
  final Widget child;
  @override
  State<WindowsAdminSecurityGate> createState() => _WindowsAdminSecurityGateState();
}

class _WindowsAdminSecurityGateState extends State<WindowsAdminSecurityGate> {
  final _schoolPassword = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = true, _busy = false, _configured = false;
  bool _opened = false, _legacy = false, _recover = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WindowsAdminSecurity.revision.addListener(_credentialChanged);
    _load();
  }

  void _credentialChanged() {
    if(!mounted) return;
    WindowsAdminSecurity.clearPanelSession();
    setState(() { _opened = false; _password.clear(); _confirm.clear(); });
  }

  Future<void> _load() async {
    setState(() { _loading=true; _error=null; });
    try {
      final managed = await WindowsAdminSecurity.isManaged;
      if (!managed) {
        if(await WindowsAdminSecurity.hasPanelSession()){
          if(mounted)setState(() { _legacy=true;_configured=true;_opened=true;_loading=false; });
          return;
        }
        final configured=await WindowsAdminSecurity.configured();
        if(mounted)setState(() { _legacy=true;_configured=configured;_opened=!configured;_loading=false; });
        return;
      }
      if(await WindowsAdminSecurity.hasPanelSession()) {
        if(mounted)setState(() { _configured=true;_opened=true;_loading=false; });
        return;
      }
      final configured = await WindowsAdminSecurity.configured();
      if(mounted) setState(() { _configured=configured; _loading=false; });
    } catch (_) {
      if(mounted) setState(() {
        _loading=false;
        _error='School Admin Security is unavailable. Reconnect and retry.';
      });
    }
  }

  Future<void> _submit() async {
    if (_busy || _loading) return;
    final pass = _password.text;
    if ((!_configured || _recover) && (pass.length < 12 || pass.length > 128 || pass != _confirm.text)) {
      setState(() => _error='Use a matching Admin Password of 12–128 characters.');
      return;
    }
    if((!_configured || _recover) && WindowsLocalSecurity.verifyPassword(pass)) {
      setState(() => _error='Admin Password must be different from App Lock.');
      return;
    }
    setState(() { _busy=true; _error=null; });
    try {
      if (_configured && !_recover) {
        await WindowsAdminSecurity.unlock(pass);
      } else {
        if(!_legacy && _schoolPassword.text.isEmpty)
          throw StateError('Enter your school login password.');
        if(!_legacy && _schoolPassword.text == pass)
          throw StateError('Admin Password must be different from School Login Password.');
        if(_recover) {
          await WindowsAdminSecurity.recover(
            schoolPassword:_schoolPassword.text, newPassword:pass);
        } else {
          await WindowsAdminSecurity.enroll(
            schoolPassword:_schoolPassword.text, newPassword:pass);
        }
      }
      await WindowsAdminSecurity.grantPanelSession();
      _password.clear();
      _confirm.clear();
      _schoolPassword.clear();
      if(mounted) setState(() { _configured=true; _recover=false; _opened=true; _busy=false; });
    } catch (e) {
      if(mounted) setState(() { _busy=false; _error=e.toString(); });
    }
  }

  @override
  void dispose() {
    WindowsAdminSecurity.revision.removeListener(_credentialChanged);
    _schoolPassword.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if(_opened) return widget.child;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar:AppBar(title:const Text('Admin Panel Security')),
      body:Center(
        child:ConstrainedBox(
          constraints:const BoxConstraints(maxWidth:470),
          child:SingleChildScrollView(
            padding:const EdgeInsets.all(24),
            child:Card(child:Padding(
              padding:const EdgeInsets.all(24),
              child:Column(mainAxisSize:MainAxisSize.min,children:[
                Icon(Icons.admin_panel_settings_rounded,size:48,color:colors.primary),
                const SizedBox(height:12),
                Text(_recover ? 'Recover Admin Password' :
                  _configured ? 'Unlock Admin Panel' : 'Create Admin Password',
                  style:Theme.of(context).textTheme.titleLarge),
                const SizedBox(height:8),
                Text(_recover
                  ? 'Verify the school login password to reset the independent Admin Password.'
                  : _configured
                  ? 'Enter the independent school administrator password.'
                  : _legacy
                  ? 'Create an independent Admin Password for this Windows school profile.'
                  : 'School-wide Admin Password is separate from this PC App Lock.',
                  textAlign:TextAlign.center),
                const SizedBox(height:22),
                if(_loading) const CircularProgressIndicator()
                else ...[
                  if(!_legacy && (!_configured || _recover)) ...[
                    TextField(controller:_schoolPassword,obscureText:true,
                      enabled:!_busy,
                      decoration:const InputDecoration(
                        labelText:'Current School Login Password',
                        prefixIcon:Icon(Icons.verified_user_outlined))),
                    const SizedBox(height:12),
                  ],
                  TextField(controller:_password,obscureText:true,enabled:!_busy,
                    onSubmitted:(_) => _submit(),
                    decoration:InputDecoration(
                      labelText:_configured && !_recover ? 'Admin Password' : 'New Admin Password',
                      prefixIcon:const Icon(Icons.lock_outline))),
                  if(!_configured || _recover) ...[
                    const SizedBox(height:12),
                    TextField(controller:_confirm,obscureText:true,enabled:!_busy,
                      onSubmitted:(_) => _submit(),
                      decoration:const InputDecoration(labelText:'Confirm Admin Password')),
                  ],
                  if(_error != null) ...[
                    const SizedBox(height:12),
                    Text(_error!,style:TextStyle(color:colors.error)),
                  ],
                  const SizedBox(height:18),
                  FilledButton.icon(
                    onPressed:_busy ? null : _submit,
                    icon:_busy ? const SizedBox(width:16,height:16,
                      child:CircularProgressIndicator(strokeWidth:2))
                      : const Icon(Icons.lock_open_rounded),
                    label:Text(_busy ? 'Verifying...' :
                      _recover ? 'Reset Admin Password' :
                      _configured ? 'Unlock Admin Panel' : 'Create Admin Password'),
                  ),
                ],
                if(!_loading && _configured && !_legacy) ...[
                  const SizedBox(height:8),
                  TextButton(onPressed:_busy ? null : () => setState(() {
                    _recover=!_recover;
                    _password.clear();_confirm.clear();_schoolPassword.clear();_error=null;
                  }),child:Text(_recover ? 'Back to Admin Password' : 'Forgot Admin Password?')),
                ],
                if(!_loading && _error != null) ...[
                  const SizedBox(height:10),
                  TextButton(onPressed:_busy ? null : _load,
                    child:const Text('Retry security connection')),
                ],
              ]),
            )),
          ),
        ),
      ),
    );
  }
}

/// Call immediately before sensitive UI actions. The verified result and any
/// short-lived server grant must never be written into school sync records.
Future<String?> requestWindowsAdminApproval(
  BuildContext context, {
  required String scope,
  required String target,
}) async {
  if (!context.mounted) return null;
  final controller = TextEditingController();
  bool working = false;
  String? error;
  final token = await showDialog<String>(
    context:context, barrierDismissible:false,
    builder:(dialog) => StatefulBuilder(builder:(ctx, update) => AlertDialog(
      title:const Text('Administrator Approval'),
      content:Column(mainAxisSize:MainAxisSize.min,children:[
        const Text('Enter the separate Admin Password to authorize this action.'),
        const SizedBox(height:12),
        TextField(controller:controller,obscureText:true,enabled:!working,
          onSubmitted:(_) {},
          decoration:InputDecoration(labelText:'Admin Password',errorText:error)),
      ]),
      actions:[
        TextButton(onPressed:working ? null : () => Navigator.pop(dialog),
          child:const Text('Cancel')),
        FilledButton(
          onPressed:working ? null : () async {
            update(() {working=true;error=null;});
            try {
              final grant=await WindowsAdminSecurity.approve(
                password:controller.text,scope:scope,target:target);
              if(dialog.mounted) Navigator.pop(dialog,grant);
            } catch (_) {
              if(dialog.mounted) update(() {
                working=false;
                error='Admin verification failed or server is unavailable.';
              });
            }
          },
          child:Text(working ? 'Verifying...' : 'Authorize')),
      ],
    )),
  );
  controller.dispose();
  return token;
}

/// Password Management page: rotate or recover the school-wide credential.
class WindowsAdminPasswordCard extends StatefulWidget {
  const WindowsAdminPasswordCard({super.key});
  @override
  State<WindowsAdminPasswordCard> createState() => _WindowsAdminPasswordCardState();
}

class _WindowsAdminPasswordCardState extends State<WindowsAdminPasswordCard> {
  final _current=TextEditingController(), _next=TextEditingController(),
    _confirm=TextEditingController();
  bool _busy=false, _recover=false, _managed=true;
  bool? _configured;
  String? _message;
  @override
  void initState(){
    super.initState();
    _loadStatus();
  }
  Future<void> _loadStatus() async {
    try {
      final managed = await WindowsAdminSecurity.isManaged;
      final configured = await WindowsAdminSecurity.configured();
      if (mounted) setState(() { _managed=managed; _configured=configured; _message=null; });
    } catch (_) {
      if (mounted) setState(() => _message='Unable to check Admin Password status.');
    }
  }
  @override
  void dispose(){
    _current.dispose();_next.dispose();_confirm.dispose();
    super.dispose();
  }
  Future<void> _save() async {
    if(_busy || _configured == null)return;
    if(_next.text.length<12 || _next.text.length>128 || _next.text != _confirm.text) {
      setState(() => _message='Use 12–128 characters and matching passwords.');
      return;
    }
    if(WindowsLocalSecurity.verifyPassword(_next.text)) {
      setState(() => _message='Admin Password must be different from App Lock.');
      return;
    }
    setState(() { _busy=true;_message=null; });
    try {
      if(_configured == false) {
        await WindowsAdminSecurity.enroll(schoolPassword:_current.text, newPassword:_next.text);
      } else if(_recover) {
        if(!_managed)throw StateError('Standalone Admin Password recovery requires school owner verification.');
        await WindowsAdminSecurity.recover(
          schoolPassword:_current.text, newPassword:_next.text);
      } else {
        await WindowsAdminSecurity.change(
          currentPassword:_current.text, newPassword:_next.text);
      }
      _current.clear();_next.clear();_confirm.clear();
      if(mounted)setState(() { _busy=false;_configured=true;_recover=false;_message='Admin Password updated. Reopen Admin Panel to unlock again.'; });
    } catch (_) {
      if(mounted)setState(() { _busy=false;_message='Password update failed. Check your credentials and connection.'; });
    }
  }
  @override
  Widget build(BuildContext context)=>Card(child:Padding(
    padding:const EdgeInsets.all(18),
    child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('Admin Panel Password',style:TextStyle(fontSize:17,fontWeight:FontWeight.bold)),
      const SizedBox(height:6),
      Text(_managed
        ? 'Separate from App Lock. Applies to authorized PCs for this managed school.'
        : 'Separate from App Lock. Stored only in this Windows school profile.'),
      const SizedBox(height:14),
      if (_configured == null)
        TextButton(onPressed: _loadStatus, child: Text(_message ?? 'Checking status…')),
      if (_configured != null && (_managed || _configured == true))
      TextField(controller:_current,obscureText:true,enabled:!_busy,
        decoration:InputDecoration(labelText:_recover || _configured == false
          ? 'School Login Password (recovery)' : 'Current Admin Password')),
      if (_configured != null) const SizedBox(height:9),
      if (_configured != null) TextField(controller:_next,obscureText:true,enabled:!_busy,
        decoration:const InputDecoration(labelText:'New Admin Password')),
      const SizedBox(height:9),
      if (_configured != null) TextField(controller:_confirm,obscureText:true,enabled:!_busy,
        decoration:const InputDecoration(labelText:'Confirm New Password')),
      if(_message != null) Padding(
        padding:const EdgeInsets.symmetric(vertical:8),
        child:Text(_message!)),
      const SizedBox(height:10),
      if (_configured != null) Wrap(spacing:12,children:[
        FilledButton(onPressed:_busy ? null : _save,
          child:Text(_busy ? 'Saving...' : _recover ? 'Recover Admin Password' : _configured == true ? 'Change Admin Password' : 'Set Admin Password')),
        if(_managed && _configured == true)TextButton(onPressed:_busy ? null : () => setState(() {
          _recover=!_recover; _current.clear();_message=null;
        }),child:Text(_recover ? 'Use current Admin Password' : 'Forgot Admin Password?')),
      ]),
    ]),
  ));
}
