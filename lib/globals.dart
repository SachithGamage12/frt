import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Stores call information to handle cold-starts and handoffs between isolates.
class InitialCallState {
  static String? targetChannel;
  static String? targetCallerId;
  static String? targetCallerName;
  static String? voipToken;
  static bool hasPendingCall = false;

  static void clear() {
    targetChannel = null;
    targetCallerId = null;
    targetCallerName = null;
    hasPendingCall = false;
  }
}

/// Global call manager — keeps engine alive when call is minimized to overlay
class CallManager {
  static final CallManager instance = CallManager._();
  CallManager._();

  RtcEngine? engine;
  bool isMinimized = false;
  bool isMuted = false;
  bool isSpeakerOn = false;
  int? remoteUid;
  String? channelName;
  String? callerId;
  OverlayEntry? overlayEntry;
  VoidCallback? onEndCall;
  VoidCallback? onToggleMute;
  VoidCallback? onToggleSpeaker;
  VoidCallback? onExpand;

  void clear() {
    isMinimized = false;
    isMuted = false;
    isSpeakerOn = false;
    remoteUid = null;
    channelName = null;
    callerId = null;
    onEndCall = null;
    onToggleMute = null;
    onToggleSpeaker = null;
    onExpand = null;
  }

  void removeOverlay() {
    overlayEntry?.remove();
    overlayEntry = null;
  }
}
