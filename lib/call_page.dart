import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class CallPage extends StatefulWidget {
  final String channelName;
  final String callerId;
  final String calleeId;
  final bool isCaller;

  const CallPage({
    super.key,
    required this.channelName,
    required this.callerId,
    required this.calleeId,
    this.isCaller = false,
  });

  @override
  _CallPageState createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final String appId = '04360d4224f0484f9d5b57a720dcb87b'; // Agora App ID
  late RtcEngine _engine;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  int? _remoteUid;

  @override
  void initState() {
    super.initState();
    _initAgora();
  }

  Future<void> _initAgora() async {
    // Determine permissions needed
    await [Permission.microphone].request();

    // Create RtcEngine
    _engine = createAgoraRtcEngine();
    await _engine.initialize(RtcEngineContext(
      appId: appId,
      channelProfile: ChannelProfileType.channelProfileCommunication,
    ));

    _engine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
          debugPrint("Local user uid:${connection.localUid} joined the channel");
        },
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          debugPrint("Remote user uid:$remoteUid joined the channel");
          setState(() {
            _remoteUid = remoteUid;
          });
        },
        onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
          debugPrint("Remote user uid:$remoteUid left the channel");
          setState(() {
            _remoteUid = null;
          });
          // End call if remote user leaves
          _leaveChannel();
        },
      ),
    );

    // Join channel
    await _engine.joinChannel(
      token: '', // Leave empty if token is not required for testing
      channelId: widget.channelName,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        autoSubscribeAudio: true,
        publishMicrophoneTrack: true,
      ),
      uid: 0, // Agora generates random UID
    );

    // Initially route audio to earpiece
    await _engine.setEnableSpeakerphone(false);
  }

  Future<void> _leaveChannel() async {
    await _engine.leaveChannel();
    await _engine.release();
    
    // Clear ringing state from Firestore if we were the caller
    if (widget.isCaller) {
      await FirebaseFirestore.instance.collection('calls').doc(widget.calleeId).delete().catchError((e) {});
    } else {
      await FirebaseFirestore.instance.collection('calls').doc(widget.callerId).delete().catchError((e) {});
    }
    
    if (mounted) {
      Navigator.pop(context);
    }
  }

  void _onToggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _engine.muteLocalAudioStream(_isMuted);
  }

  void _onToggleSpeaker() {
    setState(() {
      _isSpeakerOn = !_isSpeakerOn;
    });
    _engine.setEnableSpeakerphone(_isSpeakerOn);
  }

  @override
  void dispose() {
    _leaveChannel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F2027),
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            const CircleAvatar(
              radius: 60,
              backgroundColor: Colors.white24,
              child: Icon(Icons.person, size: 80, color: Colors.white),
            ),
            const SizedBox(height: 30),
            Text(
              _remoteUid != null ? "Connected" : "Calling...",
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
            ),
            const SizedBox(height: 10),
            Text(
              "Channel: ${widget.channelName}",
              style: const TextStyle(fontSize: 14, color: Colors.white54),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 30),
              decoration: const BoxDecoration(
                color: Color(0xFF203A43),
                borderRadius: BorderRadius.vertical(top: Radius.circular(40)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildCallButton(
                    icon: _isMuted ? Icons.mic_off : Icons.mic,
                    color: _isMuted ? Colors.redAccent : Colors.white,
                    onTap: _onToggleMute,
                  ),
                  _buildCallButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    size: 70,
                    iconSize: 35,
                    onTap: _leaveChannel,
                  ),
                  _buildCallButton(
                    icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                    color: _isSpeakerOn ? Colors.greenAccent : Colors.white,
                    onTap: _onToggleSpeaker,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallButton({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    double size = 60,
    double iconSize = 30,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: iconSize),
      ),
    );
  }
}
