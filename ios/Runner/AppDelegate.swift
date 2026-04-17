import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import FirebaseFirestore
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate, MessagingDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        GMSServices.provideAPIKey("AIzaSyBWRGXCiqYgZWCuxwlnosDjtuHZAC7SZjg")
        
        // --- Added for Firebase Messaging Native Handshake ---
        Messaging.messaging().delegate = self
        
        if #available(iOS 10.0, *) {
          UNUserNotificationCenter.current().delegate = self
          let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
          UNUserNotificationCenter.current().requestAuthorization(options: authOptions) { granted, error in
              if let error = error {
                  print("❌ Notification Auth Error: \(error)")
              }
              if granted {
                  DispatchQueue.main.async {
                      application.registerForRemoteNotifications()
                  }
              }
          }
        } else {
          let settings: UIUserNotificationSettings = UIUserNotificationSettings(types: [.alert, .badge, .sound], categories: nil)
          application.registerUserNotificationSettings(settings)
          application.registerForRemoteNotifications()
        }
        // ---------------------------------------------------

        GeneratedPluginRegistrant.register(with: self)
        
        // --- Diagnostic Method Channel for FCM ---
        let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
        let fcmChannel = FlutterMethodChannel(name: "com.frt.fcm/diagnostics",
                                              binaryMessenger: controller.binaryMessenger)
        fcmChannel.setMethodCallHandler({
          (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
          if call.method == "getNativeFCMToken" {
              let token = Messaging.messaging().fcmToken
              print("🔍 Native Diagnostic FCM Token Request: \(String(describing: token))")
              result(token)
          } else if call.method == "forceRetrieveFCMToken" {
              // Forced retrieval using the absolute Sender ID
              let senderID = "1060214465512"
              Messaging.messaging().retrieveFCMToken(forSenderID: senderID) { (token, error) in
                  if let error = error {
                      print("❌ Forced FCM Retrieval Failed: \(error.localizedDescription)")
                      result(nil)
                  } else {
                      print("✅ Forced FCM Retrieval Success: \(String(describing: token))")
                      result(token)
                  }
              }
          } else if call.method == "saveUserIdToNative" {
              if let args = call.arguments as? [String: Any],
                 let userId = args["userId"] as? String {
                  UserDefaults.standard.set(userId, forKey: "frt_user_id")
                  print("✅ v17: Saved User ID for Native Rescue: \(userId)")
                  if let currentToken = Messaging.messaging().fcmToken {
                      self?.pushTokenToFirestore(fcmToken: currentToken, userId: userId)
                  }
                  result(true)
              } else {
                  result(false)
              }
          } else {
            result(FlutterMethodNotImplemented)
          }
        })
        
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Swizzling is enabled, so we don't need manual mapping.
        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }
    
    override func applicationDidBecomeActive(_ application: UIApplication) {
        application.registerForRemoteNotifications()
    }
}

extension AppDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken = fcmToken else { return }
        print("🚀 v17 Native Handshake: FCM Token received: \(fcmToken)")
        if let userId = UserDefaults.standard.string(forKey: "frt_user_id") {
            pushTokenToFirestore(fcmToken: fcmToken, userId: userId)
        }
    }
    
    func pushTokenToFirestore(fcmToken: String, userId: String) {
        print("📡 v17 Native Rescue: Pushing token to Firestore for \(userId)...")
        let db = Firestore.firestore()
        db.collection("users").document(userId).setData([
            "fcmToken": fcmToken,
            "platform": "ios",
            "lastSync": FieldValue.serverTimestamp()
        ], merge: true) { error in
            if let error = error {
                print("❌ v17 Native Rescue Error: \(error.localizedDescription)")
            } else {
                print("✅ v17 Native Rescue Success: Token synced via Swift Core")
            }
        }
    }
}
