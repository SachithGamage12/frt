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
        
        // --- v30: Secure Controller Access for Background Stability ---
        // Replacing unsafe 'as!' forced cast to prevent crashes during background/VoIP launches
        if let controller = window?.rootViewController as? FlutterViewController {
            setupMethodChannels(controller: controller)
        }
        
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func setupMethodChannels(controller: FlutterViewController) {
        let fcmChannel = FlutterMethodChannel(name: "com.frt.fcm/diagnostics",
                                              binaryMessenger: controller.binaryMessenger)
        fcmChannel.setMethodCallHandler({
          (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
          if call.method == "getNativeFCMToken" {
              let token = Messaging.messaging().fcmToken
              print("🔍 Native Diagnostic FCM Token Request: \(String(describing: token))")
              result(token)
          } else if call.method == "forceRetrieveFCMToken" {
              let senderID = "1060214465512"
              Messaging.messaging().retrieveFCMToken(forSenderID: senderID) { (token, error) in
                  if let error = error {
                      let errStr = "Force Error: \(error.localizedDescription)"
                      // v30: Native Firestore sync disabled to prevent initialization conflicts (IllegalStateException)
                      print("❌ Native token retrieval fail: \(errStr)")
                      result(nil)
                  } else {
                      result(token)
                  }
              }
          } else if call.method == "saveUserIdToNative" {
              if let args = call.arguments as? [String: Any],
                 let userId = args["userId"] as? String {
                  UserDefaults.standard.set(userId, forKey: "frt_user_id")
                  print("✅ v30: Saved User ID for Native Context: \(userId)")
                  result(true)
              } else {
                  result(false)
              }
          } else {
            result(FlutterMethodNotImplemented)
          }
        })
    }

    override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }

    override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ APNs Registration Fail: \(error.localizedDescription)")
        super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    }

    override func applicationDidBecomeActive(_ application: UIApplication) {
        application.registerForRemoteNotifications()
    }
}

extension AppDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let token = fcmToken {
            print("🚀 v30 Native Handshake Success: \(token.prefix(8))...")
        } else {
            print("❌ v30 Native Handshake: Null Token")
        }
        // v30: Skipping native Firestore sync to resolve FIRIllegalStateException (Firestore already started in Flutter)
    }
}
