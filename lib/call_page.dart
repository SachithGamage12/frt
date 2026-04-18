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
  final String appId =
      'ca5bbd43c13b42229ac1ac316fc6e13d'; // Agora App ID (Testing Mode)
  late RtcEngine _engine;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  int? _remoteUid;
  StreamSubscription? _callStreamSubscription;
  bool _isEngineInitialized = false;

  @override
  void initState() {
    super.initState();
    // Stop all system ringtones immediately to clear audio hardware
    FlutterRingtonePlayer().stop();

    // v30: Delaying initialization slightly for iOS CallKit stability
    // This gives the OS time to switch the audio session context from ringing to voice.
    _initEnginePreWarm().then((_) {
      if (mounted) {
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted) {
            _joinCallSession();
            _listenToCallStatus();
          }
        });
      }
    });
  }

  Future<void> _initEnginePreWarm() async {
    try {
      _engine = createAgoraRtcEngine();
      await _engine.initialize(
        RtcEngineContext(
          appId: appId,
          channelProfile: ChannelProfileType.channelProfileCommunication,
        ),
      );
      await _engine.setAudioProfile(
        profile: AudioProfileType.audioProfileSpeechStandard,
        scenario: AudioScenarioType.audioScenarioDefault,
      );
      _isEngineInitialized = true;
    } catch (e) {
      debugPrint('Engine pre-warm error: $e');
    }
  }

  int _retryCount = 0;
  void _listenToCallStatus() {
    final String targetId = widget.isCaller ? widget.calleeId : widget.callerId;
    _callStreamSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(targetId)
        .snapshots()
        .listen((snapshot) {
          if (!snapshot.exists || (snapshot.data()?['status'] == 'ended')) {
            // Resilience: If doc is missing, wait 2 seconds before giving up
            // This stops disconnects caused by Firestore's internal sync latency.
            _retryCount++;
            if (_retryCount > 2) {
              _leaveChannel();
            }
          } else {
            _retryCount = 0;
          }
        });
  }

  Future<void> _joinCallSession() async {
    if (!mounted) return;
    await [Permission.microphone].request();

    _engine.registerEventHandler(
      RtcEngineEventHandler(
        onJoinChannelSuccess: (RtcConnection connection, int elapsed) async {
          debugPrint(
            "Local user uid:${connection.localUid} joined the channel",
          );
          await _engine.setEnableSpeakerphone(true);
          if (mounted) setState(() => _isSpeakerOn = true);
        },
        onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
          debugPrint("Remote user uid:$remoteUid joined the channel");
          setState(() {
            _remoteUid = remoteUid;
          });
        },
        onUserOffline: (
          RtcConnection connection,
          int remoteUid,
          UserOfflineReasonType reason,
        ) {
          debugPrint("Remote user uid:$remoteUid left the channel");
          setState(() {
            _remoteUid = null;
          });
          _leaveChannel();
        },
      ),
    );

    try {
      await _engine.joinChannel(
        token: '',
        channelId: widget.channelName,
        uid: 0,
        options: const ChannelMediaOptions(
          autoSubscribeAudio: true,
          publishMicrophoneTrack: true,
          clientRoleType: ClientRoleType.clientRoleBroadcaster,
        ),
      );
    } catch (e) {
      debugPrint('Join channel error: $e');
    }
  }

  Future<void> _leaveChannel() async {
    try {
      if (_isEngineInitialized) {
        await _engine.leaveChannel();
        await _engine.release();
        _isEngineInitialized = false;
      }
    } catch (e) {
      debugPrint("Error leaving channel: $e");
    }

    // Clear ringing state from Firestore
    try {
      await FirebaseFirestore.instance
          .collection('calls')
          .doc(widget.calleeId)
          .delete();
    } catch (_) {}

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
                  Shadow(
                    color: AppColors.primary.withOpacity(0.5),
                    blurRadius: 10,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "Session: ${widget.channelName}",
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white38,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 40),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(40),
                ),
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
          color:
              isEndCall
                  ? color.withOpacity(0.3)
                  : (active ? color.withOpacity(0.2) : Colors.white10),
          shape: BoxShape.circle,
          border: Border.all(
            color:
                isEndCall
                    ? color.withOpacity(0.5)
                    : (active ? color.withOpacity(0.4) : Colors.transparent),
            width: 2,
          ),
        ),
        child: Icon(
          icon,
          color: isEndCall ? Colors.white : color,
          size: iconSize,
        ),
      ),
    );
  }
}
