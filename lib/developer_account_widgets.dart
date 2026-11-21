import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'platform/managed_developer_service.dart';
import 'release_download.dart';
import 'website_installer_transfer.dart';
import 'website_installer_transfer_stub.dart'
    if (dart.library.html) 'website_installer_transfer_web.dart' as transfers;

class DeveloperAccountProfile extends StatefulWidget {
  const DeveloperAccountProfile({super.key});
  @override
  State<DeveloperAccountProfile> createState() => _DeveloperAccountProfileState();
}

class _DeveloperAccountProfileState extends State<DeveloperAccountProfile> {
  final current=TextEditingController(),otp=TextEditingController(),
      next=TextEditingController(),confirm=TextEditingController();
  Timer? ticker;
  bool busy=false,sent=false,verified=false;
  bool showCurrentPassword = false;
  int expiresAt=0,resendAfter=0;
  String? message, changeProof;
  int get remaining => ((expiresAt-DateTime.now().millisecondsSinceEpoch)/1000).ceil().clamp(0,300).toInt();
  String get countdown => '${(remaining~/60).toString().padLeft(2,'0')}:${(remaining%60).toString().padLeft(2,'0')}';
  bool get unlocked => verified && remaining>0;
  @override
  void initState(){
    super.initState();
    ticker=Timer.periodic(const Duration(seconds:1),(_){
      if(mounted&&sent)setState((){
        if(remaining==0){verified=false;changeProof=null;}
      });
    });
  }
  @override
  void dispose(){
    ticker?.cancel();
    current.dispose();otp.dispose();next.dispose();confirm.dispose();
    super.dispose();
  }
  Future<void> send() async {
    if(busy)return;
    setState(() {busy=true;message=null;});
    try{
      final user=FirebaseAuth.instance.currentUser;
      if(user==null||user.email==null)throw StateError('Developer sign-in required');
      final result = await ManagedDeveloperService.call(
        'security/otp/send', {'currentPassword': current.text},
      );
      if(!mounted)return;
      setState((){
        sent=true;verified=false;changeProof=null;otp.clear();next.clear();confirm.clear();
        expiresAt=(result['expiresAt'] as num).toInt();
        resendAfter=(result['resendAfter'] as num).toInt();
        message=null;
      });
    }catch(_){
      if(mounted)setState(()=>message='OTP could not be emailed. Check your current password and developer email setup.');
    }finally{
      if(mounted)setState(()=>busy=false);
    }
  }
  Future<void> resend() async {
    if(busy||!sent||DateTime.now().millisecondsSinceEpoch<resendAfter)return;
    await send();
  }
  Future<void> verify() async {
    if(busy||remaining==0||otp.text.trim().length!=6)return;
    setState((){busy=true;message=null;});
    try{
      final result=await ManagedDeveloperService.call('security/otp/verify',{'otp':otp.text.trim()});
      final proof=result['proof'];
      if(result['verified']!=true||proof is! String||proof.isEmpty){
        throw StateError('Verification not confirmed');
      }
      if(mounted)setState((){verified=true;changeProof=proof;otp.clear();});
    }catch(_){
      if(mounted)setState(()=>message='Incorrect or expired OTP. Check your email or resend.');
    }finally{
      if(mounted)setState(()=>busy=false);
    }
  }
  Future<void> save() async {
    if(busy||!unlocked)return;
    if(next.text.length<12||next.text.length>128||next.text!=confirm.text){
      setState(()=>message='Use 12–128 characters and matching passwords.');
      return;
    }
    setState((){busy=true;message=null;});
    try{
      final result=await ManagedDeveloperService.call('security/otp/change',{'password':next.text,'proof':changeProof});
      if(result['passwordChanged']!=true)throw StateError('Password update was not confirmed');
      await FirebaseAuth.instance.signOut();
    }catch(_){
      if(mounted)setState((){
        verified=false;changeProof=null;next.clear();confirm.clear();
        message='Password change was not confirmed. Request a new OTP before retrying.';
      });
    }finally{
      if(mounted)setState(()=>busy=false);
    }
  }

  @override
  Widget build(BuildContext context){
    final small=MediaQuery.sizeOf(context).width<740;
    final fieldDecoration=InputDecoration(
      isDense:true,contentPadding:const EdgeInsets.symmetric(vertical:13,horizontal:12),
      border:OutlineInputBorder(borderRadius:BorderRadius.circular(12)));
    final currentField = TextField(
      key: const ValueKey('developer-security-current'),
      controller: current,
      obscureText: !showCurrentPassword,
      enableSuggestions: false,
      autocorrect: false,
      decoration: fieldDecoration.copyWith(
        hintText: 'Current Password',
        prefixIcon: const Icon(Icons.lock_outline),
        suffixIcon: IconButton(
          tooltip: showCurrentPassword ? 'Hide current password' : 'Show current password',
          icon: Icon(showCurrentPassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          onPressed: () => setState(() => showCurrentPassword = !showCurrentPassword),
        ),
      ),
    );
    Widget lockedField(TextEditingController controller) => TextField(
      controller:controller,enabled:unlocked&&!busy,obscureText:true,
      enableSuggestions:false,autocorrect:false,
      decoration:fieldDecoration.copyWith(
        filled:true,fillColor:unlocked?Colors.white:const Color(0xFFE8EEF7),
        prefixIcon:const Icon(Icons.lock_outline,size:18),
      ),
    );
    final sendButton=FilledButton.icon(
      key:const ValueKey('developer-security-send-otp'),
      onPressed:busy||sent?null:send,icon:const Icon(Icons.mail_outline,size:17),
      label:const Text('Send OTP'));
    final otpControls=Row(children:[
      Expanded(child:TextField(
        key:const ValueKey('developer-security-otp'),
        controller:otp,enabled:!busy&&!verified&&remaining>0,
        keyboardType:TextInputType.number,maxLength:6,
        decoration:fieldDecoration.copyWith(counterText:'',prefixIcon:const Icon(Icons.key_outlined,size:18)),
      )),
      const SizedBox(width:8),
      FilledButton(key:const ValueKey('developer-security-verify'),
        onPressed:busy||verified||remaining==0?null:verify,child:const Text('Verify OTP')),
      const SizedBox(width:8),
      OutlinedButton(
        key:const ValueKey('developer-security-resend'),
        onPressed:busy||DateTime.now().millisecondsSinceEpoch<resendAfter?null:resend,
        child:Text('Resend ($countdown)')),
    ]);
    return Align(
      alignment:Alignment.topCenter,
      child:ConstrainedBox(
        constraints:const BoxConstraints(maxWidth:980),
        child:Container(
          padding:EdgeInsets.all(small?12:20),
          decoration:BoxDecoration(
            color:const Color(0xFFF9FBFF),
            borderRadius:BorderRadius.circular(20),
            border:Border.all(color:Colors.white),
            boxShadow:const [BoxShadow(color:Color(0x162A72D9),blurRadius:24,offset:Offset(0,10))],
          ),
          child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            if(small)...[
              currentField,
              const SizedBox(height:8),sendButton,
            ] else Row(children:[
              Expanded(child: currentField),
              const SizedBox(width:10),sendButton,
            ]),
            if(sent)...[
              const SizedBox(height:12),
              if(small)Column(children:[
                TextField(key:const ValueKey('developer-security-otp'),
                  controller:otp,enabled:!busy&&!verified&&remaining>0,maxLength:6,
                  keyboardType:TextInputType.number,decoration:fieldDecoration.copyWith(counterText:'')),
                const SizedBox(height:8),
                Row(children:[
                  FilledButton(onPressed:busy||verified||remaining==0?null:verify,child:const Text('Verify OTP')),
                  const SizedBox(width:8),
                  OutlinedButton(onPressed:busy||DateTime.now().millisecondsSinceEpoch<resendAfter?null:resend,
                    child:Text('Resend ($countdown)')),
                ]),
              ])else otpControls,
            ],
            const SizedBox(height:12),
            lockedField(next),
            const SizedBox(height:10),
            lockedField(confirm),
            if(message!=null)...[
              const SizedBox(height:8),
              Text(message!,style:const TextStyle(color:Color(0xFFC23D4B),fontSize:12)),
            ],
            const SizedBox(height:12),
            Align(alignment:Alignment.centerLeft,child:FilledButton.icon(
              key:const ValueKey('developer-security-save'),
              onPressed:busy||!unlocked?null:save,icon:const Icon(Icons.save_outlined,size:17),
              label:const Text('Save Password'),
            )),
          ]),
        ),
      ),
    );
  }
}
class DeveloperIdleSession extends StatefulWidget {
  const DeveloperIdleSession({super.key, required this.child});
  final Widget child;

  @override
  State<DeveloperIdleSession> createState() => _DeveloperIdleSessionState();
}

class _DeveloperIdleSessionState extends State<DeveloperIdleSession>
    with WidgetsBindingObserver {
  Timer? _expiry;
  Timer? _activityTimer;
  DateTime? _checkedAt;
  bool _ready = false;
  bool _checking = false;
  bool _activityPending = false;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointer);
    HardwareKeyboard.instance.addHandler(_handleKey);
    unawaited(_check());
  }

  Future<void> _check({bool activity = false}) async {
    if (_checking || !mounted) return;
    _checking = true;
    final started = DateTime.now();
    try {
      final session = await ManagedDeveloperService.call(
        activity ? 'session/activity' : 'session/status',
        {},
        timeout: const Duration(seconds: 10),
      );
      if (!mounted) return;
      final remaining = (session['expiresAt'] as int) - (session['serverTime'] as int);
      _checkedAt = started;
      _expiry?.cancel();
      _expiry = Timer(
        Duration(milliseconds: remaining),
        () {
          if (!mounted) return;
          _hideDashboard();
          unawaited(_check());
        },
      );
      if (!_ready || _unavailable) {
        setState(() {
          _ready = true;
          _unavailable = false;
        });
      }
    } on DeveloperRequestException catch (error) {
      if (!mounted) return;
      _hideDashboard();
      if (error.status == 401 || error.status == 403) {
        await FirebaseAuth.instance.signOut();
      } else {
        setState(() => _unavailable = true);
      }
    } catch (_) {
      if (mounted) {
        _hideDashboard();
        setState(() => _unavailable = true);
      }
    } finally {
      _checking = false;
      if (_activityPending && mounted && !_unavailable) _scheduleActivity();
    }
  }

  void _hideDashboard() {
    Navigator.of(context, rootNavigator: true).popUntil((route) => route.isFirst);
    setState(() => _ready = false);
  }

  void _handlePointer(PointerEvent event) {
    if (event is PointerDownEvent || event is PointerSignalEvent) _recordActivity();
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) _recordActivity();
    return false;
  }

  void _recordActivity() {
    if (!_ready || _unavailable) return;
    _activityPending = true;
    _scheduleActivity();
  }

  void _scheduleActivity() {
    if (_checking || _activityTimer?.isActive == true) return;
    const interval = Duration(seconds: 5);
    final elapsed = DateTime.now().difference(_checkedAt ?? DateTime.now());
    _activityTimer = Timer(interval - elapsed, () {
      _activityPending = false;
      unawaited(_check(activity: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  @override
  void dispose() {
    _expiry?.cancel();
    _activityTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handlePointer);
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unavailable) {
      return Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Developer session could not be verified.'),
            TextButton(onPressed: () => _check(), child: const Text('Retry')),
            TextButton(onPressed: ManagedDeveloperService.signOut, child: const Text('Sign out')),
          ]),
        ),
      );
    }
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return widget.child;
  }
}
/// Both cards have independent transfers. Browser-native downloads cannot be
/// cancelled by Flutter once dispatched, so Web first downloads the verified
/// installer over an abortable same-origin-allowlisted HTTP request.
class AppDownloadButtons extends StatefulWidget {
  const AppDownloadButtons({super.key, this.createTransfer});

  /// Dependency injection for widget tests; the production implementation
  /// performs a cancellable web XMLHttpRequest.
  final WebsiteInstallerTransfer Function()? createTransfer;

  @override
  State<AppDownloadButtons> createState() => _AppDownloadButtonsState();
}

class _AppDownloadButtonsState extends State<AppDownloadButtons> {
  static const _installerOrigin = 'https://saarthi-oauth-staging.onrender.com';
  final Map<String, WebsiteInstallerTransfer> _active = {};
  final Map<String, int> _received = {};
  final Map<String, int> _totals = {};
  final Map<String, String> _errors = {};
  final Set<String> _transferred = {};

  String _displayBytes(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  Future<void> _start(String platform) async {
    if (_active.containsKey(platform)) return;
    setState(() {
      _errors.remove(platform);
      _transferred.remove(platform);
      _received.remove(platform);
      _totals.remove(platform);
    });
    if (!kIsWeb && widget.createTransfer == null) {
      await _nativeDownload(platform);
      return;
    }
    final transfer = widget.createTransfer?.call() ??
        transfers.createWebsiteInstallerTransfer();
    _active[platform] = transfer;
    setState(() {});
    transfer.start(
      url: '$_installerOrigin/downloads/${platform == 'windows' ? 'windows.exe' : 'android.apk'}',
      filename: platform == 'windows'
          ? 'Vidya_Saarthi_Setup.exe'
          : 'Vidya_Saarthi_Student.apk',
      onProgress: (received, total) {
        if (!mounted || !identical(_active[platform], transfer)) return;
        setState(() {
          _received[platform] = received;
          if (total != null && total > 0) {
            _totals[platform] = total;
          }
        });
      },
      onTransferred: () {
        if (!mounted || !identical(_active[platform], transfer)) return;
        setState(() {
          _active.remove(platform);
          _transferred.add(platform);
        });
      },
      onCancelled: () {
        if (!mounted || !identical(_active[platform], transfer)) return;
        setState(() {
          _active.remove(platform);
          _received.remove(platform);
          _totals.remove(platform);
        });
      },
      onFailure: (message) {
        if (!mounted || !identical(_active[platform], transfer)) return;
        setState(() {
          _active.remove(platform);
          _errors[platform] = message;
        });
      },
    );
  }

  // Non-web developer builds keep the old release-link behavior. Browser UI
  // never silently falls back to an uncancellable native download.
  Future<void> _nativeDownload(String platform) async {
    try {
      final response = await http
          .get(Uri.parse(
              'https://api.github.com/repos/cscticket01-hash/Saarthi_Ai/releases?per_page=100'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw StateError('Latest release unavailable');
      }
      final installer = latestReleasedInstaller(
        jsonDecode(response.body) as List, platform);
      if (installer == null ||
          !await launchUrl(installer, webOnlyWindowName: '_self')) {
        throw StateError('No installer available');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _errors[platform] =
            'Download unavailable. Please try again later.');
      }
    }
  }

  void _cancel(String platform) {
    final transfer = _active[platform];
    if (transfer == null) return;
    // Abort the in-page HTTP transfer. Reset the button immediately even if
    // the browser dispatches its abort event asynchronously. Late progress
    // and completion callbacks are ignored because ownership was released.
    transfer.cancel();
    if (!mounted || !identical(_active[platform], transfer)) return;
    setState(() {
      _active.remove(platform);
      _received.remove(platform);
      _totals.remove(platform);
    });
  }

  @override
  void dispose() {
    for (final download in _active.values.toList()) {
      download.cancel();
    }
    super.dispose();
  }

  Widget _card(String platform) {
    final windows = platform == 'windows';
    final busy = _active.containsKey(platform);
    final transferred = _transferred.contains(platform);
    final total = _totals[platform];
    final received = _received[platform] ?? 0;
    final fraction = busy && total != null && total > 0
        ? (received / total).clamp(0.0, 1.0)
        : null;
    final progressLabel = !busy
        ? transferred
            ? 'Installer received. Check the browser save prompt.'
            : null
        : total != null && total > 0
            ? '${_displayBytes(received)} / ${_displayBytes(total)}'
            : received > 0
                ? '${_displayBytes(received)} received'
                : 'Preparing secure download…';

    return _AnimatedDownloadCard(
      title: windows ? 'Windows App' : 'Android App',
      subtitle: windows
          ? 'Windows desktop installer'
          : 'Student Android application',
      icon: windows ? Icons.desktop_windows_rounded : Icons.android_rounded,
      accent: windows ? const Color(0xFF1475F5) : const Color(0xFF16A76B),
      busy: busy,
      fraction: fraction,
      progressLabel: progressLabel,
      error: _errors[platform],
      onDownload: () => _start(platform),
      onCancel: () => _cancel(platform),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _card('windows'),
          const SizedBox(height: 18),
          _card('android'),
          // No explanatory text below the Android download card.
        ],
      );
}

class _AnimatedDownloadCard extends StatefulWidget {
  const _AnimatedDownloadCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.busy,
    required this.fraction,
    required this.progressLabel,
    required this.error,
    required this.onDownload,
    required this.onCancel,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final bool busy;
  final double? fraction;
  final String? progressLabel;
  final String? error;
  final VoidCallback onDownload;
  final VoidCallback onCancel;

  @override
  State<_AnimatedDownloadCard> createState() =>
      _AnimatedDownloadCardState();
}

class _AnimatedDownloadCardState extends State<_AnimatedDownloadCard> {
  bool hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => hovered = true),
        onExit: (_) => setState(() => hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(
            0,
            hovered ? -4 : 0,
            0,
          ),
          padding: const EdgeInsets.all(19),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(hovered ? 0.98 : 0.85),
            borderRadius: BorderRadius.circular(25),
            border: Border.all(
              color: hovered
                  ? widget.accent.withOpacity(0.45)
                  : Colors.white,
              width: 1.6,
            ),
            boxShadow: [
              BoxShadow(
                color: widget.accent.withOpacity(hovered ? 0.20 : 0.10),
                blurRadius: hovered ? 36 : 24,
                offset: Offset(0, hovered ? 14 : 10),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 410;
              final action = FilledButton.icon(
                key: ValueKey('${widget.title}-action'),
                onPressed: widget.busy
                    ? widget.onCancel
                    : widget.onDownload,
                icon: widget.busy
                    ? const Icon(Icons.close_rounded, size: 19)
                    : const Icon(Icons.file_download_outlined, size: 19),
                label: Text(
                  widget.busy ? 'Cancel' : 'Download',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: widget.busy
                      ? const Color(0xFF425879)
                      : widget.accent,
                  shape: const StadiumBorder(),
                  padding: const EdgeInsets.symmetric(
                    vertical: 12,
                    horizontal: 19,
                  ),
                  elevation: hovered ? 8 : 3,
                  shadowColor: widget.accent.withOpacity(0.50),
                ),
              );
              final description = Row(
                children: [
                  Container(
                    height: 65,
                    width: 65,
                    decoration: BoxDecoration(
                      color: widget.accent.withOpacity(0.09),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(widget.icon, color: widget.accent, size: 39),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: Color(0xFF162A55),
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          widget.subtitle,
                          style: const TextStyle(
                            color: Color(0xFF657798),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (compact) ...[
                    description,
                    const SizedBox(height: 15),
                    action,
                  ] else
                    Row(
                      children: [
                        Expanded(child: description),
                        const SizedBox(width: 12),
                        action,
                      ],
                    ),
                  if (widget.busy || widget.progressLabel != null) ...[
                    const SizedBox(height: 13),
                    if (widget.busy)
                      LinearProgressIndicator(
                        value: widget.fraction,
                        minHeight: 5,
                        color: widget.accent,
                        backgroundColor: widget.accent.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    const SizedBox(height: 7),
                    Text(
                      widget.progressLabel ?? 'Preparing secure download…',
                      style: TextStyle(
                        color: widget.accent,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (widget.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Text(
                        widget.error!,
                        style: const TextStyle(
                          color: Color(0xFFAE2843),
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
}
