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
/// Windows/Android only: browser-native downloads do not expose trustworthy
/// per-byte progress to Flutter after redirecting to a GitHub release.
class AppDownloadButtons extends StatefulWidget {
  const AppDownloadButtons({super.key});

  @override
  State<AppDownloadButtons> createState() => _AppDownloadButtonsState();
}

class _AppDownloadButtonsState extends State<AppDownloadButtons> {
  String? busy;
  String? error;

  Future<void> download(String platform) async {
    if (busy != null) return;
    setState(() {
      busy = platform;
      error = null;
    });
    try {
      if (kIsWeb) {
        // Preserve the latest GitHub release selection and the same verified
        // Firebase Hosting redirect as the existing website.
        Uri? chosen;
        try {
          final response = await http
              .get(Uri.parse(
                  'https://api.github.com/repos/cscticket01-hash/Saarthi_Ai/releases?per_page=100'))
              .timeout(const Duration(seconds: 8));
          if (response.statusCode == 200) {
            chosen = latestReleasedInstaller(
              jsonDecode(response.body) as List,
              platform,
            );
          }
        } catch (_) {
          // GitHub rate limiting must not remove the release redirect fallback.
        }
        chosen ??= Uri.base.resolve(platform == 'windows'
            ? '/downloads/windows.exe'
            : '/downloads/android.apk');
        if (!await launchUrl(chosen, webOnlyWindowName: '_self')) {
          throw StateError('Download unavailable');
        }
        return;
      }
      final response = await http
          .get(Uri.parse(
              'https://api.github.com/repos/cscticket01-hash/Saarthi_Ai/releases?per_page=100'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw StateError('Download list unavailable');
      }
      final selected =
          latestReleasedInstaller(jsonDecode(response.body) as List, platform);
      if (selected == null) {
        throw StateError('No released installer available');
      }
      if (!await launchUrl(selected, webOnlyWindowName: '_self')) {
        throw StateError('Download unavailable');
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            error = 'Download unavailable. Please try again shortly.');
      }
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AnimatedDownloadCard(
            title: 'Windows App',
            subtitle: 'Windows desktop installer',
            platform: 'windows',
            icon: Icons.desktop_windows_rounded,
            accent: const Color(0xFF1475F5),
            busy: busy == 'windows',
            disabled: busy != null,
            onDownload: () => download('windows'),
          ),
          const SizedBox(height: 18),
          _AnimatedDownloadCard(
            title: 'Android App',
            subtitle: 'Student Android application',
            platform: 'android',
            icon: Icons.android_rounded,
            accent: const Color(0xFF16A76B),
            busy: busy == 'android',
            disabled: busy != null,
            onDownload: () => download('android'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: const TextStyle(color: Color(0xFFAE2843)),
              ),
            ),
          const SizedBox(height: 9),
          const Text(
            'The browser manages file transfer progress after download starts.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF697B9D),
              fontSize: 12,
            ),
          ),
        ],
      );
}

class _AnimatedDownloadCard extends StatefulWidget {
  const _AnimatedDownloadCard({
    required this.title,
    required this.subtitle,
    required this.platform,
    required this.icon,
    required this.accent,
    required this.busy,
    required this.disabled,
    required this.onDownload,
  });

  final String title;
  final String subtitle;
  final String platform;
  final IconData icon;
  final Color accent;
  final bool busy;
  final bool disabled;
  final VoidCallback onDownload;

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
                onPressed: widget.disabled ? null : widget.onDownload,
                icon: widget.busy
                    ? const SizedBox(
                        width: 17,
                        height: 17,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.file_download_outlined, size: 19),
                label: Text(
                  widget.busy ? 'Preparing…' : 'Download',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                style: FilledButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: widget.accent,
                  disabledBackgroundColor: widget.accent.withOpacity(0.70),
                  disabledForegroundColor: Colors.white,
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
                    child: Icon(
                      widget.icon,
                      color: widget.accent,
                      size: 39,
                    ),
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
                  if (widget.busy) ...[
                    const SizedBox(height: 13),
                    LinearProgressIndicator(
                      minHeight: 3,
                      color: widget.accent,
                      backgroundColor: widget.accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      'Finding the latest released installer…',
                      style: TextStyle(
                        color: widget.accent,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
      );
}
