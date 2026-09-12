import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';

class CallScreen extends StatefulWidget {
  final String channelId;
  const CallScreen({super.key, required this.channelId});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  static const String _appId = "92698060d3cb4fbda710765a52243313"; 
  late RtcEngine _engine;
  bool _isJoined = false;
  bool _isMuted = false;

  @override
  void initState() {
    super.initState();
    _initAgora();
  }

  Future<void> _initAgora() async {
    await [Permission.microphone].request();

    _engine = createAgoraRtcEngine();
    await _engine.initialize(const RtcEngineContext(appId: _appId));

    _engine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          if (mounted) setState(() => _isJoined = true);
        },
        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          if (mounted) Navigator.pop(context);
        },
      ),
    );

    await _engine.enableAudio();
    await _engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);
    await _engine.joinChannel(
      token: '', 
      channelId: widget.channelId,
      uid: 0,
      options: const ChannelMediaOptions(
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ),
    );
  }

  @override
  void dispose() {
    _engine.leaveChannel();
    _engine.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircleAvatar(
                radius: 50,
                backgroundColor: Color(0xFF1F2C34),
                child: Icon(Icons.person, size: 60, color: Colors.white70),
              ),
              const SizedBox(height: 20),
              Text(
                _isJoined ? 'Connected' : 'Calling...',
                style: const TextStyle(color: Colors.white, fontSize: 20),
              ),
              const SizedBox(height: 60),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 32,
                    color: Colors.white,
                    icon: Icon(_isMuted ? Icons.mic_off : Icons.mic),
                    onPressed: () {
                      setState(() => _isMuted = !_isMuted);
                      _engine.muteLocalAudioStream(_isMuted);
                    },
                  ),
                  const SizedBox(width: 40),
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.red,
                    child: IconButton(
                      icon: const Icon(Icons.call_end, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }
}
