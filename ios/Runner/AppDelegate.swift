import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import GoogleMaps
import flutter_foreground_task
import PushKit

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate {
    
    var voipRegistry: PKPushRegistry!
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        
        Messaging.messaging().delegate = self as? MessagingDelegate
        
        GMSServices.provideAPIKey("AIzaSyBWRGXCiqYgZWCuxwlnosDjtuHZAC7SZjg")
        
        SwiftFlutterForegroundTaskPlugin.setPluginRegistrantCallback(registerPlugins)
        
        if #available(iOS 10.0, *) {
            UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
        }
        
        // Setup VoIP Push (PushKit) for Token Collection ONLY
        // We do NOT manualy manage CXProvider here to avoid plugin conflicts.
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = [.voIP]
        
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    // MARK: - PKPushRegistryDelegate (Token Collection Only)
    
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 Native VoIP Token: \(token)")
        
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.frt.voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("voipToken", arguments: token)
        }
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        // We let the flutter_callkit_incoming plugin handle the UI to avoid 'Double Provider' crashes.
        // But we MUST call completion() to tell the OS we received the push.
        completion()
    }
}

func registerPlugins(registry: FlutterPluginRegistry) {
    GeneratedPluginRegistrant.register(with: registry)
}
