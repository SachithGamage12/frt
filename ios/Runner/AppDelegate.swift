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
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Force the token type to .prod for TestFlight/App Store builds
        Messaging.messaging().setAPNSToken(deviceToken, type: .prod)
        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }
    
    override func applicationDidBecomeActive(_ application: UIApplication) {
        // Trigger a re-registration whenever the app comes to foreground 
        // to ensure we capture the token if the initial boot handshake failed.
        print("🔄 App active: Requesting APNs token refresh...")
        application.registerForRemoteNotifications()
    }
}
