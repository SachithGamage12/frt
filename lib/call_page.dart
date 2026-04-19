import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'style_utils.dart';
import 'globals.dart';
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
  final String appId = 'ca5bbd43c13b42229ac1ac316fc6e13d';
  late RtcEngine _engine;
  bool _isMuted = false;
  bool _isSpeakerOn = false;
  int? _remoteUid;
  StreamSubscription? _callStreamSubscription;
  bool _isEngineInitialized = false;
  bool _isMinimizing = false; // v24: flag to skip leaveChannel on minimize

  @override
  void initState() {
    super.initState();
    try { FlutterRingtonePlayer().stop(); } catch (e) {}

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
      await _engine.initialize(RtcEngineContext(
        appId: appId,
        channelProfile: ChannelProfileType.channelProfileCommunication,
      ));
      await _engine.setAudioProfile(
        profile: AudioProfileType.audioProfileSpeechStandard,
        scenario: AudioScenarioType.audioScenarioDefault,
      );
      // Register with global manager so overlay can control it
      CallManager.instance.engine = _engine;
      CallManager.instance.channelName = widget.channelName;
      CallManager.instance.callerId = widget.callerId;
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
            _retryCount++;
            if (_retryCount > 2) _leaveChannel();
          } else {
            _retryCount = 0;
          }
        });
  }

  Future<void> _joinCallSession() async {
    if (!mounted) return;
    await [Permission.microphone].request();

    _engine.registerEventHandler(RtcEngineEventHandler(
      onJoinChannelSuccess: (RtcConnection connection, int elapsed) async {
        debugPrint("Local user uid:${connection.localUid} joined");
        await _engine.setEnableSpeakerphone(true);
        if (mounted) setState(() => _isSpeakerOn = true);
        CallManager.instance.isSpeakerOn = true;
      },
      onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
        debugPrint("Remote user uid:$remoteUid joined");
        setState(() => _remoteUid = remoteUid);
        CallManager.instance.remoteUid = remoteUid;
        // Rebuild overlay if minimized to show CONNECTED
        if (CallManager.instance.isMinimized) {
          CallManager.instance.overlayEntry?.markNeedsBuild();
        }
      },
      onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
        debugPrint("Remote user uid:$remoteUid left");
        setState(() => _remoteUid = null);
        CallManager.instance.remoteUid = null;
        _leaveChannel();
      },
    ));

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
    _isMinimizing = false;
    CallManager.instance.removeOverlay();
    CallManager.instance.isMinimized = false;
    _callStreamSubscription?.cancel();

    try {
      if (_isEngineInitialized) {
        await _engine.leaveChannel();
        await _engine.release();
        _isEngineInitialized = false;
        CallManager.instance.engine = null;
      }
    } catch (e) { debugPrint("Error leaving channel: $e"); }

    try {
      await FirebaseFirestore.instance.collection('calls').doc(widget.calleeId).delete();
    } catch (_) {}

    await FlutterCallkitIncoming.endAllCalls();
    CallManager.instance.clear();

    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  // v24: Minimize call — show overlay, go back to app, engine keeps running
  void _minimizeCall() {
    if (!_isEngineInitialized) return;
    _isMinimizing = true;
    CallManager.instance.isMinimized = true;
    CallManager.instance.isMuted = _isMuted;
    CallManager.instance.isSpeakerOn = _isSpeakerOn;
    CallManager.instance.remoteUid = _remoteUid;
    CallManager.instance.onEndCall = _leaveChannel;
    CallManager.instance.onToggleMute = _onToggleMute;
    CallManager.instance.onToggleSpeaker = _onToggleSpeaker;
    CallManager.instance.onExpand = _expandCall;

    // Insert floating overlay
    final overlayState = navigatorKey.currentState?.overlay;
    if (overlayState != null) {
      CallManager.instance.overlayEntry = OverlayEntry(
        builder: (ctx) => _MiniCallOverlay(
          onEnd: () async {
            _isMinimizing = false;
            await _leaveChannel();
          },
          onExpand: _expandCall,
        ),
      );
      overlayState.insert(CallManager.instance.overlayEntry!);
    }

    Navigator.of(context).pop();
  }

  void _expandCall() {
    CallManager.instance.removeOverlay();
    CallManager.instance.isMinimized = false;
    _isMinimizing = false;
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (context) => CallPage(
          channelName: widget.channelName,
          callerId: widget.callerId,
          calleeId: widget.calleeId,
          isCaller: widget.isCaller,
        ),
      ),
    );
  }

  void _onToggleMute() {
    setState(() => _isMuted = !_isMuted);
    _engine.muteLocalAudioStream(_isMuted);
    CallManager.instance.isMuted = _isMuted;
    CallManager.instance.overlayEntry?.markNeedsBuild();
  }

  void _onToggleSpeaker() {
    setState(() => _isSpeakerOn = !_isSpeakerOn);
    _engine.setEnableSpeakerphone(_isSpeakerOn);
    CallManager.instance.isSpeakerOn = _isSpeakerOn;
  }

  @override
  void dispose() {
    _callStreamSubscription?.cancel();
    if (!_isMinimizing) {
      // Only actually leave the channel if NOT minimizing
      _leaveChannel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar with minimize button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white54, size: 30),
                    tooltip: 'Minimize',
                    onPressed: _minimizeCall,
                  ),
                  const Text(
                    'FRT Call',
                    style: TextStyle(color: Colors.white38, fontSize: 14, letterSpacing: 1.5),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
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
                shadows: [Shadow(color: AppColors.primary.withOpacity(0.5), blurRadius: 10)],
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
          color: isEndCall ? color.withOpacity(0.3) : (active ? color.withOpacity(0.2) : Colors.white10),
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

// ─── Mini Floating Call Overlay Widget ───────────────────────────────────────
class _MiniCallOverlay extends StatefulWidget {
  final VoidCallback onEnd;
  final VoidCallback onExpand;

  const _MiniCallOverlay({required this.onEnd, required this.onExpand});

  @override
  State<_MiniCallOverlay> createState() => _MiniCallOverlayState();
}

class _MiniCallOverlayState extends State<_MiniCallOverlay> {
  Offset _offset = const Offset(16, 100);
  bool _isMuted = false;

  @override
  Widget build(BuildContext context) {
    _isMuted = CallManager.instance.isMuted;
    final isConnected = CallManager.instance.remoteUid != null;

    return Positioned(
      left: _offset.dx,
      top: _offset.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            _offset = Offset(
              (_offset.dx + details.delta.dx).clamp(0, MediaQuery.of(context).size.width - 180),
              (_offset.dy + details.delta.dy).clamp(0, MediaQuery.of(context).size.height - 120),
            );
          });
        },
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 175,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surface.withOpacity(0.97),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppColors.primary.withOpacity(0.4)),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.4), blurRadius: 16, offset: const Offset(0, 4))],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Status badge
                Row(
                  children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: isConnected ? AppColors.primary : Colors.orangeAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isConnected ? 'CONNECTED' : 'CALLING...',
                      style: TextStyle(
                        color: isConnected ? AppColors.primary : Colors.orangeAccent,
                        fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 1,
                      ),
                    ),
                    const Spacer(),
                    // Expand/maximize button
                    GestureDetector(
                      onTap: widget.onExpand,
                      child: const Icon(Icons.open_in_full, color: Colors.white38, size: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Caller info
                Text(
                  CallManager.instance.callerId ?? 'FRT Call',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 10),
                // Controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Mute toggle
                    GestureDetector(
                      onTap: () {
                        CallManager.instance.engine?.muteLocalAudioStream(!_isMuted);
                        setState(() {
                          _isMuted = !_isMuted;
                          CallManager.instance.isMuted = _isMuted;
                        });
                      },
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _isMuted ? Colors.red.withOpacity(0.2) : Colors.white10,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _isMuted ? Icons.mic_off : Icons.mic,
                          color: _isMuted ? Colors.redAccent : Colors.white70,
                          size: 16,
                        ),
                      ),
                    ),
                    // End call
                    GestureDetector(
                      onTap: widget.onEnd,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.3),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.red.withOpacity(0.5)),
                        ),
                        child: const Icon(Icons.call_end, color: Colors.white, size: 18),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
