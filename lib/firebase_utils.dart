import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io';

class FirebaseUtils {
  static bool _isSecondaryInitialized = false;

  static Future<void> initializeSecondaryApp() async {
    if (_isSecondaryInitialized) return;

    try {
      if (Platform.isAndroid) {
        // Connecting to Project B (frtapp-ff79b)
        await Firebase.initializeApp(
          name: 'secondaryApp',
          options: const FirebaseOptions(
            apiKey: 'AIzaSyBWRGXCiqYgZWCuxwlnosDjtuHZAC7SZjg',
            appId: '1:1060214465512:android:62c8205792a43ba5d', // Corrected to android format
            messagingSenderId: '1060214465512',
            projectId: 'frtapp-ff79b',
            storageBucket: 'frtapp-ff79b.firebasestorage.app',
          ),
        );
      } else if (Platform.isIOS) {
        // Connecting to Project A (testapp-ce8aa)
        await Firebase.initializeApp(
          name: 'secondaryApp',
          options: const FirebaseOptions(
            apiKey: 'AIzaSyBWRGXCiqYgZWCuxwlnosDjtuHZAC7SZjg',
            appId: '1:422057941225:ios:a8567fd0663acba1b0f878', // Corrected to ios format
            messagingSenderId: '422057941225',
            projectId: 'testapp-ce8aa',
            storageBucket: 'testapp-ce8aa.firebasestorage.app',
          ),
        );
      }
      _isSecondaryInitialized = true;
      print('Secondary Firebase initialized successfully');
    } catch (e) {
      print('Secondary Firebase initialization failed: $e');
    }
  }

  static FirebaseFirestore? get secondaryFirestore {
    try {
      final app = Firebase.app('secondaryApp');
      return FirebaseFirestore.instanceFor(app: app);
    } catch (e) {
      return null;
    }
  }
}
