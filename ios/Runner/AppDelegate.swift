import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import GoogleMaps
import flutter_foreground_task

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if FirebaseApp.app() == nil {
        FirebaseApp.configure()
    }
    
    // Set messaging delegate for background token management
    Messaging.messaging().delegate = self as? MessagingDelegate
    
    GMSServices.provideAPIKey("AIzaSyBWRGXCiqYgZWCuxwlnosDjtuHZAC7SZjg")
    
    SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback(registerPlugins)
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    }

    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Handle background notifications for CallKit wake-up
  override func application(_ application: UIApplication,
                          didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                          fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
      super.application(application, didReceiveRemoteNotification: userInfo, fetchCompletionHandler: completionHandler)
  }
}

func registerPlugins(registry: FlutterPluginRegistry) {
  GeneratedPluginRegistrant.register(with: registry)
}
