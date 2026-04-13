import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'style_utils.dart';
import 'dart:async';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

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
  final String appId = 'ca5bbd43c13b42229ac1ac316fc6e13d'; // Agora App ID (Testing Mode)
  late RtcEngine _engine;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  int? _remoteUid;
  StreamSubscription? _callStreamSubscription;

  @override
  void initState() {
    super.initState();
    FlutterRingtonePlayer().stop();
    // Delay Agora initialization to ensure CallKit audio session is ready
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) _initAgora();
    });
    _listenToCallStatus();
  }

  void _listenToCallStatus() {
    final String targetId = widget.isCaller ? widget.calleeId : widget.callerId;
    _callStreamSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(targetId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists || (snapshot.data()?['status'] == 'ended')) {
        // Automatically close call if document is deleted or marked as ended
        _leaveChannel();
      }
    });
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

    // Optimize audio for voice
    await _engine.setAudioProfile(
      profile: AudioProfileType.audioProfileDefault,
      scenario: AudioScenarioType.audioScenarioDefault,
    );

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
      token: '', // No token required for testing mode
      channelId: widget.channelName,
      options: const ChannelMediaOptions(
        clientRoleType: ClientRoleType.clientRoleBroadcaster,
        autoSubscribeAudio: true,
        publishMicrophoneTrack: true,
      ),
      uid: 0, // Agora generates random UID
    );

    // Initially route audio to speaker for tracking app convenience
    await _engine.setEnableSpeakerphone(true);
    setState(() => _isSpeakerOn = true);
  }

  Future<void> _leaveChannel() async {
    try {
      await _engine.leaveChannel();
      await _engine.release();
    } catch (e) {
      debugPrint("Error leaving channel: $e");
    }
    
    // Clear ringing state from Firestore
    // Always clear the callee's document ID as that is the primary signaling point
    try {
      await FirebaseFirestore.instance.collection('calls').doc(widget.calleeId).delete();
    } catch(_) {}
    
    await FlutterCallkitIncoming.endAllCalls();
    
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
    _callStreamSubscription?.cancel();
    _leaveChannel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(),
            const CircleAvatar(
              radius: 70,
              backgroundColor: Colors.white10,
              child: Icon(Icons.person, size: 90, color: Colors.white24),
            ),
            const SizedBox(height: 40),
            Text(
              _remoteUid != null ? "CONNECTED" : "CALLING...",
              style: TextStyle(
                fontSize: 28, 
                fontWeight: FontWeight.w900, 
                color: Colors.white,
                letterSpacing: 2.0,
                shadows: [
                  Shadow(color: AppColors.primary.withOpacity(0.5), blurRadius: 10),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "Session: ${widget.channelName}",
              style: const TextStyle(fontSize: 14, color: Colors.white38, letterSpacing: 1.2),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(40)),
                border: Border.all(color: Colors.white10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildCallButton(
                    icon: _isMuted ? Icons.mic_off : Icons.mic,
                    color: _isMuted ? Colors.redAccent : Colors.white70,
                    active: !_isMuted,
                    onTap: _onToggleMute,
                  ),
                  _buildCallButton(
                    icon: Icons.call_end,
                    color: Colors.red,
                    size: 80,
                    iconSize: 40,
                    onTap: _leaveChannel,
                    isEndCall: true,
                  ),
                  _buildCallButton(
                    icon: _isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                    color: _isSpeakerOn ? AppColors.primary : Colors.white70,
                    active: _isSpeakerOn,
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
    bool active = false,
    bool isEndCall = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: isEndCall 
              ? color.withOpacity(0.3) 
              : (active ? color.withOpacity(0.2) : Colors.white10),
          shape: BoxShape.circle,
          border: Border.all(
            color: isEndCall ? color.withOpacity(0.5) : (active ? color.withOpacity(0.4) : Colors.transparent),
            width: 2,
          ),
        ),
        child: Icon(icon, color: isEndCall ? Colors.white : color, size: iconSize),
      ),
    );
  }
}
