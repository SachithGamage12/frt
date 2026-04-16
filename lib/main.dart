import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'interface.dart';
import 'payment_page.dart';
import 'admin_panel.dart';
import 'style_utils.dart';
import 'globals.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'call_page.dart';

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
      final params = CallKitParams(
        id: data['channelName'] ?? 'call_${DateTime.now().millisecondsSinceEpoch}',
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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    _initializeFCM(); // Non-blocking
    
    // Check for cold start call BEFORE app initializes (Essential for Killed State)
    final activeCalls = await FlutterCallkitIncoming.activeCalls();
    if (activeCalls is List && activeCalls.isNotEmpty) {
        final firstCall = activeCalls.first;
        final extra = firstCall['extra'];
        if (extra != null && extra['channelName'] != null) {
             InitialCallState.targetChannel = extra['channelName'];
             InitialCallState.targetCallerId = extra['callerId'];
             InitialCallState.targetCallerName = extra['callerName'];
             InitialCallState.hasPendingCall = true;
             debugPrint("Captured Cold Start Call: ${extra['channelName']}");
        }
    }
    
    // Listen for events while app is running
    FlutterCallkitIncoming.onEvent.listen((event) {
       if (event == null) return;
       debugPrint("CallKit Global Event: ${event.event}");
       
       if (event.event == 'ACTION_CALL_ACCEPT') {
          final extra = event.body['extra'];
          if (extra != null && extra['channelName'] != null) {
             InitialCallState.targetChannel = extra['channelName'];
             InitialCallState.targetCallerId = extra['callerId'];
             InitialCallState.targetCallerName = extra['callerName'];
             InitialCallState.hasPendingCall = true;
             debugPrint("Bufferized Pending Call: ${extra['channelName']}");
             
             // INSTANT-PUSH: If app is already active, jump to call immediately
             if (navigatorKey.currentState != null) {
                navigatorKey.currentState?.push(
                  MaterialPageRoute(
                    builder: (context) => CallPage(
                      channelName: extra['channelName'],
                      callerId: extra['callerId'] ?? 'unknown',
                      calleeId: 'current_user', 
                      isCaller: false,
                    ),
                  ),
                );
             }
          }
       }
    });

  } catch (e) {
    print("Firebase initialization error: $e");
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

    // Get FCM token and immediately save it to Firestore
    String? token = await messaging.getToken();
    if (token != null) {
      debugPrint("FCM Token: $token");
      // Save to SharedPreferences first so we have it ready
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcmToken', token);
      // Try to sync to Firestore immediately if user is already logged in
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
          debugPrint("FCM token sync error (will retry on login): $e");
        }
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
  final params = CallKitParams(
    id: data['channelName'] ?? 'incoming_call_${DateTime.now().millisecondsSinceEpoch}',
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
    ),
  );
  await FlutterCallkitIncoming.showCallkitIncoming(params);
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
      home: const FRTAnimationPage(),
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
              builder: (context) => PaymentPage(userId: mobile, userData: doc.data() as Map<String, dynamic>),
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

          bool isUnlocked = doc.data()?['isAppUnlocked'] == true;
          Timestamp? expiry = doc.data()?['subscriptionExpiry'] as Timestamp?;
          
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

          if (isUnlocked && expiry != null && expiry.toDate().isBefore(DateTime.now())) {
            isUnlocked = false;
            await _firestore.collection('users').doc(_mobileController.text).update({'isAppUnlocked': false});
          }

          if (isUnlocked) {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => InterfacePage(userId: _mobileController.text)),
            );
          } else {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                builder: (context) => PaymentPage(userId: _mobileController.text, userData: doc.data() as Map<String, dynamic>),
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
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const WelcomePage()),
                    );
                  },
                  child: const Text(
                    'Not registered? Create an account',
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
  bool _isLoading = false; // Track loading state

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
                const SizedBox(height: 20),
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

      DocumentSnapshot userDoc = await _firestore.collection('users').doc(widget.userId).get();
      Map<String, dynamic>? userData = userDoc.data() as Map<String, dynamic>?;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => PaymentPage(userId: widget.userId, userData: userData ?? {}),
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