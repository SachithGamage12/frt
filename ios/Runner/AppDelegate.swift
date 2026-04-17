import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
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
        // Ensure APNs is always registered
        application.registerForRemoteNotifications()
    }
}
