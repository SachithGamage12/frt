import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:io';

class FirebaseUtils {
  static bool _isSecondaryInitialized = false;

  static Future<void> initializeSecondaryApp() async {
    if (_isSecondaryInitialized) return;

    try {
      if (Platform.isAndroid) {
        await Firebase.initializeApp(
          name: 'secondaryApp',
          options: const FirebaseOptions(
            apiKey: 'AIzaSyCmtV4tRTpCCgFZIVxGsW2lLiExZsTIOR4',
            appId: '1:1060214465512:ios:377eddb6c315792a43ba5d',
            messagingSenderId: '1060214465512',
            projectId: 'frtapp-ff79b',
            storageBucket: 'frtapp-ff79b.firebasestorage.app',
          ),
        );
      } else if (Platform.isIOS) {
        await Firebase.initializeApp(
          name: 'secondaryApp',
          options: const FirebaseOptions(
            apiKey: 'AIzaSyABraObEM0yqXaU7sB2ylzqjhGnl1SXmXc',
            appId: '1:422057941225:android:a8567fd0663acba1b0f878',
            messagingSenderId: '422057941225',
            projectId: 'testapp-ce8aa',
            storageBucket: 'testapp-ce8aa.firebasestorage.app',
          ),
        );
      }
      _isSecondaryInitialized = true;
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
