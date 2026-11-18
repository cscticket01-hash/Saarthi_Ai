import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'school_password_panel.dart';
import 'release_download.dart';
import 'website_installer_transfer.dart';
import 'website_installer_transfer_stub.dart'
    if (dart.library.html) 'website_installer_transfer_web.dart' as transfers;
class DeveloperAccountProfile extends StatelessWidget {
  const DeveloperAccountProfile({super.key});
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(FirebaseAuth.instance.currentUser?.email??'',style:const TextStyle(fontSize:20)),const Text('Developer administrator'),SchoolPasswordPanel(change:(current,next)async{final user=FirebaseAuth.instance.currentUser;if(user==null||user.email==null)throw StateError('Sign in again');await user.reauthenticateWithCredential(EmailAuthProvider.credential(email:user.email!,password:current));await user.updatePassword(next);await FirebaseAuth.instance.signOut();})]);
}
class DeveloperIdleSession extends StatefulWidget {
  const DeveloperIdleSession({super.key,required this.child,this.idle=const Duration(minutes:30)});
  final Widget child;final Duration idle;
  @override State<DeveloperIdleSession> createState()=>_DeveloperIdleSessionState();
}
class _DeveloperIdleSessionState extends State<DeveloperIdleSession> with WidgetsBindingObserver{
  Timer? timer;DateTime activity=DateTime.now(),persisted=DateTime.fromMillisecondsSinceEpoch(0);bool ready=false;
  String get key=>'vs_developer_activity_${FirebaseAuth.instance.currentUser?.uid}';
  @override void initState(){super.initState();WidgetsBinding.instance.addObserver(this);restore();timer=Timer.periodic(const Duration(seconds:1),(_)=>check());}
  Future<void> restore()async{final p=await SharedPreferences.getInstance();final prior=p.getInt(key);final user=FirebaseAuth.instance.currentUser;final signed=user?.metadata.lastSignInTime?.millisecondsSinceEpoch??0;activity=DateTime.fromMillisecondsSinceEpoch(prior!=null&&prior>=signed?prior:signed);if(activity.millisecondsSinceEpoch==0)activity=DateTime.now();ready=true;await p.setInt(key,activity.millisecondsSinceEpoch);check();if(mounted)setState((){});}
  void touch(){if(!ready)return;check();if(DateTime.now().difference(activity)>=widget.idle)return;activity=DateTime.now();if(activity.difference(persisted)>const Duration(seconds:15)){persisted=activity;unawaited(SharedPreferences.getInstance().then((p)=>p.setInt(key,activity.millisecondsSinceEpoch)));}setState((){});}
  void check(){if(!ready)return;if(DateTime.now().difference(activity)>=widget.idle){ready=false;unawaited(FirebaseAuth.instance.signOut());}else if(mounted)setState((){});}
  @override void didChangeAppLifecycleState(AppLifecycleState state){if(state==AppLifecycleState.resumed)check();}
  @override void dispose(){timer?.cancel();WidgetsBinding.instance.removeObserver(this);super.dispose();}
  @override Widget build(BuildContext context){if(!ready)return const Scaffold(body:Center(child:CircularProgressIndicator()));final seconds=(widget.idle-DateTime.now().difference(activity)).inSeconds.clamp(0,widget.idle.inSeconds);return Listener(onPointerDown:(_)=>touch(),onPointerSignal:(_)=>touch(),child:Focus(onKeyEvent:(_,__) {touch();return KeyEventResult.ignored;},child:Stack(children:[widget.child,Positioned(right:20,bottom:10,child:IgnorePointer(child:Material(color:const Color(0xFF16242E),child:Padding(padding:const EdgeInsets.all(8),child:Text('Auto logout ${seconds~/60}:${(seconds%60).toString().padLeft(2,'0')}')))))])));}
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
    // Immediately aborts the active HTTP transfer, not a browser download
    // already handed off. onCancelled resets the button when abort completes.
    _active[platform]?.cancel();
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
