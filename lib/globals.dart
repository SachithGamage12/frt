import 'package:flutter/material.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Stores call information to handle cold-starts and handoffs between isolates.
class InitialCallState {
  static String? targetChannel;
  static String? targetCallerId;
  static String? targetCallerName;
  static bool hasPendingCall = false;

  static void clear() {
    targetChannel = null;
    targetCallerId = null;
    targetCallerName = null;
    hasPendingCall = false;
  }
}
