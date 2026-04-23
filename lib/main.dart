import 'package:firebase_core/firebase_core.dart';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'interface.dart';
import 'admin_panel.dart';
import 'style_utils.dart';
import 'globals.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter/services.dart';
import 'call_page.dart';
import 'dart:math' as math;
import 'package:url_launcher/url_launcher.dart';

class AwaitingActivationPage extends StatelessWidget {
  final String userId;
  const AwaitingActivationPage({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(30.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.timer_outlined, color: Colors.orangeAccent, size: 60),
              ),
              const SizedBox(height: 30),
              const Text(
                'Account Awaiting Activation',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your account has been registered but tracking is not yet active.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 30),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Column(
                  children: [
                    Text(
                      'HOW TO ACTIVATE?',
                      style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.2),
                    ),
                    SizedBox(height: 12),
                    Text(
                      '1. Log in to your dashboard at www.lankafrt.com\n2. Follow the activation steps provided there.\n3. Your account will be active within 24 hours.',
                      style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.6),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
              TextButton(
                onPressed: () => Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false),
                child: const Text('Back to Login', style: TextStyle(color: Colors.white38)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String generateUuidV4() {
  final random = math.Random();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant
  return '${_hex(bytes.sublist(0, 4))}-${_hex(bytes.sublist(4, 6))}-${_hex(bytes.sublist(6, 8))}-${_hex(bytes.sublist(8, 10))}-${_hex(bytes.sublist(10, 16))}';
}

String _hex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // CRITICAL: Must be called before anything else in background isolate
  WidgetsFlutterBinding.ensureInitialized();
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp();
  }

  try {
    final data = message.data;
    debugPrint("Background FCM: ${data['type']} / channel: ${data['channelName']}");

    if (data['type'] == 'call' || data['channelName'] != null) {
      final callId = generateUuidV4();
      final params = CallKitParams(
        id: callId,
        nameCaller: data['callerName'] ?? 'Family Member',
        appName: 'FRT',
        handle: 'Incoming Voice Call',
        avatar: data['callerAvatar'],
        type: 0,
        textAccept: 'ANSWER',
        textDecline: 'DECLINE',
        duration: 30000,
        extra: data,
        android: const AndroidParams(
          isCustomNotification: true,
          isShowLogo: true,
          ringtonePath: 'system_ringtone_default',
        ),
        ios: const IOSParams(
          iconName: 'AppIcon',
          handleType: 'generic',
          supportsVideo: false,
          audioSessionMode: 'voiceChat',
          audioSessionActive: true,
          configureAudioSession: false,
        ),
      );
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      debugPrint("✅ CallKit shown from background");
    }
  } catch (e) {
    // IMPORTANT: catch all errors - uncaught exceptions here cause iOS restart loops
    debugPrint("Background handler error (suppressed): $e");
  }
}

StreamSubscription? _globalCallSyncSub;

void _startGlobalCallSyncListener(String userId) {
  _globalCallSyncSub?.cancel();
  _globalCallSyncSub = FirebaseFirestore.instance
      .collection('calls')
      .doc(userId)
      .snapshots()
      .listen((snapshot) {
        if (!snapshot.exists || (snapshot.data()?['status'] == 'ended')) {
          debugPrint("Global Sync: Call ended via Firestore. Dismissing CallKit.");
          FlutterCallkitIncoming.endAllCalls();
          _globalCallSyncSub?.cancel();
        }
      }, onError: (e) => debugPrint("Global Sync Error: $e"));
}

void main() async {

  WidgetsFlutterBinding.ensureInitialized();
  try {
    // v31: Idempotent initialization check to prevent settings conflict on iOS
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp();
    }
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    
    // v22: Restoring the missing initialization link. This is mandatory for iOS FCM permissions.
    _initializeFCM();
    
    // Check for cold start call BEFORE app initializes (Essential for Killed State)
    try {
      final activeCalls = await FlutterCallkitIncoming.activeCalls();
      if (activeCalls is List && activeCalls.isNotEmpty) {
          final firstCall = activeCalls.first;
          if (firstCall is Map && firstCall['extra'] != null) {
              final extra = firstCall['extra'] as Map;
              if (extra['channelName'] != null) {
                   InitialCallState.targetChannel = extra['channelName'];
                   InitialCallState.targetCallerId = extra['callerId'];
                   InitialCallState.targetCallerName = extra['callerName'];
                   InitialCallState.hasPendingCall = true;
                   debugPrint("Captured Cold Start Call: ${extra['channelName']}");
              }
          }
      }
    } catch (e) {
      debugPrint("CallKit Cold Start Error (Suppressed): $e");
    }
    
    // v30: Dedicated listener for CallKit events to handle accepted calls reliably
    FlutterCallkitIncoming.onEvent.listen((event) {
        try {
          if (event == null || event.body == null) return;
          debugPrint("CallKit Global Event: ${event.event}");
          
          if (event.event == 'ACTION_CALL_ACCEPT') {
             final body = event.body as Map;
             final extra = body['extra'] as Map?;
             if (extra != null && extra['channelName'] != null) {
                InitialCallState.targetChannel = extra['channelName'];
                InitialCallState.targetCallerId = extra['callerId'];
                InitialCallState.targetCallerName = extra['callerName'];
                InitialCallState.hasPendingCall = true;
                _globalCallSyncSub?.cancel(); // Accept event stops the ringing listener
                
                // v30: Enhanced navigation - check navigatorKey and retry if needed
                void navigateToCall() {
                  if (navigatorKey.currentState != null) {
                     navigatorKey.currentState?.push(
                       MaterialPageRoute(
                         builder: (context) => CallPage(
                           channelName: extra['channelName']!,
                           callerId: extra['callerId'] ?? 'unknown',
                           calleeId: 'current_user', 
                           isCaller: false,
                         ),
                       ),
                     );
                  } else {
                    // If navigator isn't ready yet (e.g. app resuming), wait and retry
                    debugPrint("⚠️ Navigator not ready, retrying navigation in 1s...");
                    Future.delayed(const Duration(milliseconds: 1000), navigateToCall);
                  }
                }
                navigateToCall();
             }
          } else if (event.event == 'ACTION_CALL_DECLINE' || event.event == 'ACTION_CALL_ENDED' || event.event == 'ACTION_CALL_TIMEOUT') {
             InitialCallState.hasPendingCall = false;
             _globalCallSyncSub?.cancel();
             // v24: Delete Firestore call doc so CALLER side also knows call was declined/ended
             SharedPreferences.getInstance().then((prefs) async {
               try {
                 final userId = prefs.getString('mobile');
                 if (userId != null) {
                   await FirebaseFirestore.instance.collection('calls').doc(userId).delete();
                   debugPrint("✅ Call doc cleaned up on decline for $userId");
                 }
               } catch (e) { debugPrint("Decline Firestore cleanup error: $e"); }
             });

             // Also end any existing overlay if app was open with minimized call
             CallManager.instance.removeOverlay();
             CallManager.instance.clear();

             if (navigatorKey.currentState != null) {
                navigatorKey.currentState?.pushReplacement(
                   MaterialPageRoute(builder: (context) => const FRTAnimationPage()),
                );
             }
          }
        } catch (e) {
          debugPrint("CallKit Event Error: $e");
        }
    });

  } catch (e) {
    debugPrint("Firebase initialization error: $e");
  }
  runApp(const MyApp());
}

Future<void> _initializeFCM() async {
  try {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    // Give iOS a moment to finish delegate handshake
    if (Platform.isIOS) {
        await Future.delayed(const Duration(seconds: 2));
    }

    // Get FCM token and immediately save it to Firestore
    NotificationSettings settings = await messaging.getNotificationSettings();
    debugPrint("Notification Permission: ${settings.authorizationStatus}");
    
    String? token = await messaging.getToken();
    if (token == null && Platform.isIOS) {
       // On iOS, sometimes we need the APNs token to be ready first
       String? apnsToken = await messaging.getAPNSToken();
       debugPrint("APNS Token at startup: $apnsToken");
    }
    
    if (token != null) {
      debugPrint("FCM Token: $token");
      // Save to SharedPreferences first so we have it ready
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcmToken', token);
      
      // v31: ONLY sync to Firestore if we AREN'T in the middle of a critical call launch
      if (!InitialCallState.hasPendingCall) {
        final userId = prefs.getString('mobile');
        if (userId != null && userId.isNotEmpty) {
          try {
            await FirebaseFirestore.instance.collection('users').doc(userId).update({
              'fcmToken': token,
              'platform': Platform.isIOS ? 'ios' : 'android',
              'lastActive': FieldValue.serverTimestamp(),
            });
            debugPrint("✅ FCM Token synced to Firestore for user: $userId");
          } catch (e) {
            debugPrint("FCM token sync error (will retry on login/auto-login): $e");
          }
        }
      } else {
        debugPrint("⏳ Deferring FCM token sync due to active call...");
      }
    }

    // Handle foreground FCM messages - show callkit if it's a call
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('Foreground FCM: ${message.data}');
      final data = message.data;
      if (data['type'] == 'call' || data['channelName'] != null) {
        _showIncomingCallUI(data);
      }
    });

    // Handle notification tap when app is in background (not killed)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('Notification tapped: ${message.data}');
      final data = message.data;
      if (data['channelName'] != null) {
        InitialCallState.targetChannel = data['channelName'];
        InitialCallState.targetCallerId = data['callerId'];
        InitialCallState.targetCallerName = data['callerName'];
        InitialCallState.hasPendingCall = true;
      }
    });

  } catch (e) {
    debugPrint("Error initializing FCM: $e");
  }
}

Future<void> _showIncomingCallUI(Map<String, dynamic> data) async {
  final callId = generateUuidV4();
  final params = CallKitParams(
    id: callId,
    nameCaller: data['callerName'] ?? 'Family Member',
    appName: 'FRT',
    handle: 'Incoming Voice Call',
    avatar: data['callerAvatar'],
    type: 0,
    textAccept: 'ANSWER',
    textDecline: 'DECLINE',
    duration: 30000,
    extra: data,
    android: const AndroidParams(
      isCustomNotification: true,
      isShowLogo: true,
      ringtonePath: 'system_ringtone_default',
    ),
    ios: const IOSParams(
      iconName: 'AppIcon',
      handleType: 'generic',
      supportsVideo: false,
      audioSessionMode: 'voiceChat',
      audioSessionActive: true,
      configureAudioSession: false,
    ),
  );
  await FlutterCallkitIncoming.showCallkitIncoming(params);
  // v33: Start global sync listener
  SharedPreferences.getInstance().then((prefs) {
    final userId = prefs.getString('mobile');
    if (userId != null) _startGlobalCallSyncListener(userId);
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Family Road Track',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      // v31: Dummy wait screen to protect background GPU memory. Actual call UI loads ON ACCEPT EVENT.
      home: InitialCallState.hasPendingCall 
          ? const StartupWaitingPage() 
          : const FRTAnimationPage(),
    );
  }
}

class StartupWaitingPage extends StatelessWidget {
  const StartupWaitingPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black, // Extremely lightweight background page
    );
  }
}

class FRTAnimationPage extends StatefulWidget {
  const FRTAnimationPage({super.key});

  @override
  _FRTAnimationPageState createState() => _FRTAnimationPageState();
}

class _FRTAnimationPageState extends State<FRTAnimationPage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fAnimation;
  late Animation<double> _rAnimation;
  late Animation<double> _tAnimation;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    );

    _fAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0, 0.33, curve: Curves.easeInOut),
      ),
    );

    _rAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.33, 0.66, curve: Curves.easeInOut),
      ),
    );

    _tAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.66, 1, curve: Curves.easeInOut),
      ),
    );

    _controller.forward().then((_) {
      _checkAutoLogin();
    });
  }

  Future<void> _checkAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final String? mobile = prefs.getString('mobile');
    final String? password = prefs.getString('password');

    if (mobile != null && password != null) {
      // Admin Check FIRST
      if (mobile == '0771246939' && password == 'Admin123@j') {
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (context) => const AdminPanelPage()),
          );
        }
        return;
      }

      final FirebaseFirestore _firestore = FirebaseFirestore.instance;
      final doc = await _firestore.collection('users').doc(mobile).get();

      bool isUnlocked = doc.data()?['isAppUnlocked'] == true;
      Timestamp? expiry = doc.data()?['subscriptionExpiry'] as Timestamp?;
      
      // Store FCM and VoIP tokens (Unified Sync)
      try {
        String? token = await FirebaseMessaging.instance.getToken();
        final updates = <String, dynamic>{
          'lastActive': FieldValue.serverTimestamp(),
          'platform': Platform.isIOS ? 'ios' : 'android',
        };
        if (token != null) updates['fcmToken'] = token;
        await _firestore.collection('users').doc(mobile).update(updates);
      } catch (e) {
        print("Skipping token update: $e");
      }

      // Expiry Check
      if (isUnlocked && expiry != null && expiry.toDate().isBefore(DateTime.now())) {
        isUnlocked = false;
        await _firestore.collection('users').doc(mobile).update({'isAppUnlocked': false});
      }

      if (mounted) {
        if (isUnlocked) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => InterfacePage(userId: mobile),
            ),
          );
        } else {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (context) => AwaitingActivationPage(userId: mobile),
            ),
          );
        }
        return;
      }
    }

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const LoginPage()),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _fAnimation,
              builder: (context, child) {
                return Opacity(
                  opacity: _fAnimation.value,
                  child: Text(
                    'F',
                    style: TextStyle(
                      fontSize: 100,
                      fontWeight: FontWeight.bold,
                      color: Color.lerp(Colors.purple, Colors.blue, _fAnimation.value),
                    ),
                  ),
                );
              },
            ),
            AnimatedBuilder(
              animation: _rAnimation,
              builder: (context, child) {
                return Opacity(
                  opacity: _rAnimation.value,
                  child: Text(
                    'R',
                    style: TextStyle(
                      fontSize: 100,
                      fontWeight: FontWeight.bold,
                      color: Color.lerp(Colors.purple, Colors.blue, _rAnimation.value),
                    ),
                  ),
                );
              },
            ),
            AnimatedBuilder(
              animation: _tAnimation,
              builder: (context, child) {
                return Opacity(
                  opacity: _tAnimation.value,
                  child: Text(
                    'T',
                    style: TextStyle(
                      fontSize: 100,
                      fontWeight: FontWeight.bold,
                      color: Color.lerp(Colors.purple, Colors.blue, _tAnimation.value),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  _LoginPageState createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _circleAnimation;
  late Animation<double> _textAnimation;
  late Animation<Color?> _colorAnimation;
  late Animation<double> _waveAnimation;
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _rememberMe = false;
  bool _obscurePassword = true;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _showFakeRegister = false;
  bool _showRealRegister = false;


  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );

    _circleAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    _textAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.2, 1, curve: Curves.easeInOut),
      ),
    );

    _colorAnimation = ColorTween(
      begin: Colors.purple,
      end: Colors.blue,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    _waveAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 1, curve: Curves.easeInOut),
      ),
    );

    _controller.forward();
    _loadRememberMe();
    _checkRegistrationToggle();
  }

  Future<void> _checkRegistrationToggle() async {
    try {
      final doc = await _firestore.collection('settings').doc('appConfig').get();
      if (doc.exists) {
        setState(() {
          _showFakeRegister = doc.data()?['showFakeRegister'] ?? false;
          _showRealRegister = doc.data()?['showRealRegister'] ?? false;
        });
      }
    } catch (e) {
      debugPrint("Error checking toggle: $e");
    }
  }

  Future<void> _loadRememberMe() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _rememberMe = prefs.getBool('rememberMe') ?? false;
      if (_rememberMe) {
        _mobileController.text = prefs.getString('mobile') ?? '';
        _passwordController.text = prefs.getString('password') ?? '';
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _mobileController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_mobileController.text.isEmpty || _passwordController.text.isEmpty) {
      AppAlerts.show(context, 'Please enter mobile number and password', isError: true);
      return;
    }

    // Admin Check BEFORE database query
    if (_mobileController.text == '0771246939' && _passwordController.text == 'Admin123@j') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const AdminPanelPage()),
      );
      return;
    }

    int retryCount = 0;
    const int maxRetries = 3;

    while (retryCount < maxRetries) {
      try {
        final doc = await _firestore.collection('users').doc(_mobileController.text).get();
        if (doc.exists && doc.data()?['password'] == _passwordController.text) {
          final prefs = await SharedPreferences.getInstance();
          if (_rememberMe) {
            await prefs.setString('mobile', _mobileController.text);
            await prefs.setString('password', _passwordController.text);
            await prefs.setBool('rememberMe', true);
          } else {
            await prefs.remove('mobile');
            await prefs.remove('password');
            await prefs.setBool('rememberMe', false);
          }

          final data = doc.data()!;
          
          // Store tokens (Unified Sync)
          try {
            String? token = await FirebaseMessaging.instance.getToken();
            final updates = <String, dynamic>{
              'lastActive': FieldValue.serverTimestamp(),
              'platform': Platform.isIOS ? 'ios' : 'android',
            };
            if (token != null) updates['fcmToken'] = token;
            await _firestore.collection('users').doc(_mobileController.text).update(updates);
          } catch (e) {
            print("Skipping token update: $e");
          }

          if (data['isAppUnlocked'] == true) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) => InterfacePage(userId: _mobileController.text),
              ),
            );
          } else {
            // v28: No in-app payment. Redirect to activation status page.
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) => AwaitingActivationPage(userId: _mobileController.text),
              ),
            );
          }
          return; // Success
        } else {
          AppAlerts.show(context, 'Invalid mobile number or password', isError: true);
          return; // User error, don't retry
        }
      } catch (e) {
        String errorStr = e.toString().toLowerCase();
        if (errorStr.contains('unavailable') || errorStr.contains('network') || errorStr.contains('deadline')) {
          retryCount++;
          if (retryCount < maxRetries) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Mobile data slow. Retrying ($retryCount/$maxRetries)...')),
            );
            await Future.delayed(const Duration(seconds: 3));
            continue; // Loop again
          }
        }
        AppAlerts.show(context, 'Error: $e', isError: true);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          // Top Half Circle
          Positioned(
            top: -MediaQuery.of(context).size.height * 0.2,
            left: -MediaQuery.of(context).size.width * 0.2,
            child: AnimatedBuilder(
              animation: _circleAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _circleAnimation.value,
                  child: Container(
                    width: MediaQuery.of(context).size.width * 0.8,
                    height: MediaQuery.of(context).size.width * 0.8,
                    decoration: BoxDecoration(
                      color: Colors.yellow.shade700,
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              },
            ),
          ),

          // Content
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _textAnimation,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, 50 * (1 - _textAnimation.value)),
                      child: Opacity(
                        opacity: _textAnimation.value,
                        child: Text(
                          'Login',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                            color: _colorAnimation.value,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 40),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: TextField(
                    controller: _mobileController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      hintText: 'Mobile Number',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: TextField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      hintText: 'Password',
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Checkbox(
                      value: _rememberMe,
                      onChanged: (value) {
                        setState(() {
                          _rememberMe = value!;
                        });
                      },
                    ),
                    const Text('Remember me'),
                  ],
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _login,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.yellow.shade700,
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                  ),
                  child: const Text(
                    'Login',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                const SizedBox(height: 30),
                if (_showFakeRegister)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: TextButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const FakeRegisterPage()),
                        );
                      },
                      child: const Text(
                        "Register New Account",
                        style: TextStyle(
                          color: Colors.white70,
                          decoration: TextDecoration.underline,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                if (_showRealRegister)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                    child: Column(
                      children: [
                        const Text(
                          "Don't have an account?",
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () async {
                            final uri = Uri.parse("https://www.lankafrt.com/login.html");
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            }
                          },
                          child: const Text(
                            "Register here on website",
                            style: TextStyle(
                              color: Color(0xFF00E5FF),
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Wave Animation
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _waveAnimation,
              builder: (context, child) {
                return ClipPath(
                  clipper: WaveClipper(_waveAnimation.value),
                  child: Container(
                    height: 100,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF00E5FF), Color(0xFF00B4D8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}


class FakeRegisterPage extends StatefulWidget {
  const FakeRegisterPage({super.key});

  @override
  _FakeRegisterPageState createState() => _FakeRegisterPageState();
}

class _FakeRegisterPageState extends State<FakeRegisterPage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _circleAnimation;
  late Animation<double> _textAnimation;
  late Animation<Color?> _colorAnimation;
  late Animation<double> _waveAnimation;
  
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(seconds: 2), vsync: this);
    _circleAnimation = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _textAnimation = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _controller, curve: const Interval(0.2, 1, curve: Curves.easeInOut)));
    _colorAnimation = ColorTween(begin: Colors.purple, end: Colors.blue).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _waveAnimation = Tween<double>(begin: 0, end: 1).animate(CurvedAnimation(parent: _controller, curve: const Interval(0.5, 1, curve: Curves.easeInOut)));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    _mobileController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _fakeSubmit() async {
    if (_nameController.text.isEmpty || _mobileController.text.isEmpty || _passwordController.text.isEmpty) {
      AppAlerts.show(context, 'Please fill all fields', isError: true);
      return;
    }
    setState(() => _isLoading = true);
    await Future.delayed(const Duration(seconds: 2));
    setState(() => _isLoading = false);
    
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1e293b),
          title: const Text('Registration Success', style: TextStyle(color: Color(0xFF00E5FF))),
          content: const Text(
            'Admin will review your details and within 24 hours we will activate your account. You will receive a notification once activated.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                Navigator.of(context).pop();
              },
              child: const Text('OK', style: TextStyle(color: Color(0xFF00E5FF))),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          Positioned(
            top: -MediaQuery.of(context).size.height * 0.2,
            left: -MediaQuery.of(context).size.width * 0.2,
            child: AnimatedBuilder(
              animation: _circleAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _circleAnimation.value,
                  child: Container(
                    width: MediaQuery.of(context).size.width * 0.8,
                    height: MediaQuery.of(context).size.width * 0.8,
                    decoration: const BoxDecoration(color: Color(0xFF00E5FF), shape: BoxShape.circle),
                  ),
                );
              },
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Create Account',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 40),
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      hintText: 'Full Name',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _mobileController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      hintText: 'Mobile Number',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 15),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white,
                      hintText: 'Password',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 30),
                  _isLoading
                      ? const CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)))
                      : ElevatedButton(
                          onPressed: _fakeSubmit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00E5FF),
                            padding: const EdgeInsets.symmetric(horizontal: 60, vertical: 15),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text('Register', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 16)),
                        ),
                  const SizedBox(height: 20),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Back to Login', style: TextStyle(color: Colors.white54)),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _waveAnimation,
              builder: (context, child) {
                return ClipPath(
                  clipper: WaveClipper(_waveAnimation.value),
                  child: Container(
                    height: 100,
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF00E5FF), Color(0xFF00B4D8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});

  @override
  _WelcomePageState createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _circleAnimation;
  late Animation<double> _textAnimation;
  late Animation<Color?> _colorAnimation;
  late Animation<double> _waveAnimation;
  File? _profileImage;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  bool _isLoading = false;
  bool _privacyAccepted = false; // v22: App Store requirement

  final ImagePicker _picker = ImagePicker();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );

    _circleAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    _textAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.2, 1, curve: Curves.easeInOut),
      ),
    );

    _colorAnimation = ColorTween(
      begin: Colors.purple,
      end: Colors.blue,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    _waveAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 1, curve: Curves.easeInOut),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    _mobileController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        _profileImage = File(image.path);
      });
    }
  }

  Future<String> _uploadImageToCloudinary(File image) async {
    final url = Uri.parse('https://api.cloudinary.com/v1_1/dz86er6fe/image/upload');
    final request = http.MultipartRequest('POST', url)
      ..fields['upload_preset'] = 'ml_default'
      ..files.add(await http.MultipartFile.fromPath('file', image.path));

    final response = await request.send();
    if (response.statusCode == 200) {
      final responseData = await response.stream.bytesToString();
      final jsonResponse = jsonDecode(responseData);
      return jsonResponse['secure_url'];
    } else {
      throw Exception('Failed to upload image');
    }
  }

  Future<void> _saveData() async {
    if (!_privacyAccepted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please accept the Privacy Policy to continue.')),
      );
      return;
    }
    if (_nameController.text.isEmpty || _profileImage == null || _mobileController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter your name, mobile number, and select a profile picture')),
      );
      return;
    }

    setState(() {
      _isLoading = true; // Show loading indicator
    });

    try {
      // Check if mobile number already exists
      final userId = _mobileController.text;
      final doc = await _firestore.collection('users').doc(userId).get();
      if (doc.exists) {
        setState(() {
          _isLoading = false;
        });
        AppAlerts.show(context, 'This mobile number is already registered', isError: true);
        return;
      }

      // Upload image and save data
      final String imageUrl = await _uploadImageToCloudinary(_profileImage!);

      await _firestore.collection('users').doc(userId).set({
        'name': _nameController.text,
        'profilePicture': imageUrl,
        'mobile': _mobileController.text,
        'timestamp': FieldValue.serverTimestamp(),
        'isAppUnlocked': false,
        'generatedPromoCode': '',
        'isPromoCodeUsed': false,
      });

      setState(() {
        _isLoading = false; // Hide loading indicator
      });

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => TellUsAboutYouPage(userId: userId),
        ),
      );
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      AppAlerts.show(context, 'Error: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          // Top Half Circle
          Positioned(
            top: -MediaQuery.of(context).size.height * 0.2,
            left: -MediaQuery.of(context).size.width * 0.2,
            child: AnimatedBuilder(
              animation: _circleAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _circleAnimation.value,
                  child: Container(
                    width: MediaQuery.of(context).size.width * 0.8,
                    height: MediaQuery.of(context).size.width * 0.8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00E5FF),
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              },
            ),
          ),

          // Welcome Content
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _textAnimation,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, 50 * (1 - _textAnimation.value)),
                      child: Opacity(
                        opacity: _textAnimation.value,
                        child: Text(
                          'Hi, Welcome to Family Road Track app',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                            color: _colorAnimation.value,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: _pickImage,
                  child: CircleAvatar(
                    radius: 50,
                    backgroundColor: Colors.white,
                    backgroundImage: _profileImage != null ? FileImage(_profileImage!) : null,
                    child: _profileImage == null
                        ? const Icon(
                            Icons.add_a_photo,
                            size: 40,
                            color: Colors.black,
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      hintText: 'Enter your name',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: TextField(
                    controller: _mobileController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      hintText: 'Enter your mobile number',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // v22: Privacy Policy checkbox (App Store requirement)
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.85,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Checkbox(
                        value: _privacyAccepted,
                        activeColor: const Color(0xFF00E5FF),
                        checkColor: Colors.black,
                        side: const BorderSide(color: Colors.white54),
                        onChanged: (val) => setState(() => _privacyAccepted = val ?? false),
                      ),
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            final uri = Uri.parse('https://lankafrt.com/privacy-policy.html');
                            if (await canLaunchUrl(uri)) launchUrl(uri, mode: LaunchMode.externalApplication);
                          },
                          child: const Text.rich(
                            TextSpan(
                              text: 'I agree to the ',
                              style: TextStyle(color: Colors.white70, fontSize: 13),
                              children: [
                                TextSpan(
                                  text: 'Privacy Policy',
                                  style: TextStyle(
                                    color: Color(0xFF00E5FF),
                                    decoration: TextDecoration.underline,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                _isLoading
                    ? const CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.yellow),
                      )
                    : ElevatedButton(
                        onPressed: _saveData,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF),
                          padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                        ),
                        child: const Text(
                          'Continue',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.black,
                          ),
                        ),
                      ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (context) => const LoginPage()),
                    );
                  },
                  child: const Text(
                    'Already registered? Sign in',
                    style: TextStyle(
                      color: Colors.white,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Wave Animation
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _waveAnimation,
              builder: (context, child) {
                return ClipPath(
                  clipper: WaveClipper(_waveAnimation.value),
                  child: Container(
                    height: 100,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF00E5FF), Color(0xFF00B4D8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class TellUsAboutYouPage extends StatefulWidget {
  final String userId;

  const TellUsAboutYouPage({super.key, required this.userId});

  @override
  _TellUsAboutYouPageState createState() => _TellUsAboutYouPageState();
}

class _TellUsAboutYouPageState extends State<TellUsAboutYouPage> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _circleAnimation;
  late Animation<double> _textAnimation;
  late Animation<Color?> _colorAnimation;
  late Animation<double> _waveAnimation;

  final TextEditingController _ageController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _agreeToTerms = false;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    );

    _circleAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    _textAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.2, 1, curve: Curves.easeInOut),
      ),
    );

    _colorAnimation = ColorTween(
      begin: Colors.purple,
      end: Colors.blue,
    ).animate(
      CurvedAnimation(
        parent: _controller,
        curve: Curves.easeInOut,
      ),
    );

    _waveAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(
        parent: _controller,
        curve: const Interval(0.5, 1, curve: Curves.easeInOut),
      ),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _ageController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showTermsDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Terms & Conditions', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: const SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Text(
              '''Effective Date: April 2026

Welcome to FRT (Family Road Track). These Business Terms & Conditions ("Terms") govern your use of the FRT application and associated services provided by UcodeX Solution. Please read them carefully.

1. Acceptance of Terms
By downloading, installing, or using the FRT application, you agree to be bound by these Terms. If you do not agree, you are restricted from utilizing our services and tracking features.

2. Service Provision
FRT provides real-time location sharing, SOS distress calling, and history logging. While we strive to ensure 99.9% uptime, GPS availability, battery constraints, and network coverage may affect software accuracy.

3. User Responsibilities & Lawful Use
You agree to use this application legally and exclusively for monitoring authorized family members or individuals who have provided explicit consent. Using FRT for unauthorized tracking, stalking, or harassment is strictly prohibited and will result in immediate termination.

4. Premium Accounts
Select features may require a premium digital subscription. Fees for these subscriptions will be clearly communicated prior to purchase. By confirming your subscription, you authorize automated cyclical billing.

5. Limitations of Liability
UcodeX Solution and FRT are not liable for any physical or digital damages, losses, or legal ramifications resulting from delayed alerts, application unavailability, or inaccurate tracking locations.''',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close', style: TextStyle(color: Color(0xFF00E5FF))),
          ),
        ],
      ),
    );
  }

  Future<void> _saveData() async {
    if (_ageController.text.isEmpty || _passwordController.text.isEmpty || !_agreeToTerms) {
      AppAlerts.show(context, 'Please fill all required fields and agree to the terms', isError: true);
      return;
    }

    try {
      await _firestore.collection('users').doc(widget.userId).set({
        'age': _ageController.text,
        'email': _emailController.text.isEmpty ? null : _emailController.text,
        'password': _passwordController.text,
        'agreeToTerms': _agreeToTerms,
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Data saved successfully')),
      );


      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => AwaitingActivationPage(userId: widget.userId),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Background Gradient
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          // Top Half Circle
          Positioned(
            top: -MediaQuery.of(context).size.height * 0.2,
            left: -MediaQuery.of(context).size.width * 0.2,
            child: AnimatedBuilder(
              animation: _circleAnimation,
              builder: (context, child) {
                return Transform.scale(
                  scale: _circleAnimation.value,
                  child: Container(
                    width: MediaQuery.of(context).size.width * 0.8,
                    height: MediaQuery.of(context).size.width * 0.8,
                    decoration: const BoxDecoration(
                      color: Color(0xFF00E5FF),
                      shape: BoxShape.circle,
                    ),
                  ),
                );
              },
            ),
          ),

          // Content
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _textAnimation,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, 50 * (1 - _textAnimation.value)),
                      child: Opacity(
                        opacity: _textAnimation.value,
                        child: Text(
                          'Tell us about you',
                          style: TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                            color: _colorAnimation.value,
                          ),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: TextField(
                    controller: _ageController,
                    decoration: InputDecoration(
                      hintText: 'Enter your age',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: TextField(
                    controller: _emailController,
                    decoration: InputDecoration(
                      hintText: 'Enter your email',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      hintText: 'Enter your password',
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Checkbox(
                      value: _agreeToTerms,
                      activeColor: const Color(0xFF00E5FF),
                      onChanged: (value) {
                        setState(() {
                          _agreeToTerms = value!;
                        });
                      },
                    ),
                    GestureDetector(
                      onTap: _showTermsDialog,
                      child: const Text(
                        'I agree to the terms and conditions',
                        style: TextStyle(
                          color: Colors.white70,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                ElevatedButton(
                  onPressed: _saveData,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                  ),
                  child: const Text(
                    'Start',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.black,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Wave Animation
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: AnimatedBuilder(
              animation: _waveAnimation,
              builder: (context, child) {
                return ClipPath(
                  clipper: WaveClipper(_waveAnimation.value),
                  child: Container(
                    height: 100,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Color(0xFF00E5FF), Color(0xFF00B4D8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class WaveClipper extends CustomClipper<Path> {
  final double animationValue;

  WaveClipper(this.animationValue);

  @override
  Path getClip(Size size) {
    final path = Path();
    path.moveTo(0, size.height);

    path.quadraticBezierTo(
      size.width * 0.25,
      size.height - 50 * animationValue,
      size.width * 0.5,
      size.height - 30 * animationValue,
    );
    path.quadraticBezierTo(
      size.width * 0.75,
      size.height - 10 * animationValue,
      size.width,
      size.height,
    );

    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => true;
}