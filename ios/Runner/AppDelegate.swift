import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import GoogleMaps
import flutter_foreground_task
import PushKit
import CallKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CXProviderDelegate {
    
    var voipRegistry: PKPushRegistry!
    var callProvider: CXProvider!
    var callController: CXCallController!
    
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
        
        // Setup VoIP Push (PushKit)
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = [.voIP]
        
        // Setup CallKit Configuration
        let config = CXProviderConfiguration(localizedName: "FRT")
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        
        // Try to load AppIcon for the CallKit UI
        if let iconImage = UIImage(named: "AppIcon") {
            config.iconTemplateImageData = iconImage.pngData()
        }
        
        callProvider = CXProvider(configuration: config)
        callProvider.setDelegate(self, queue: nil)
        callController = CXCallController()
        
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    // MARK: - PKPushRegistryDelegate
    
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        // Convert token to string
        let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 VoIP Token Generated: \(token)")
        
        // Send VoIP Token to Flutter via Method Channel
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.frt.voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("voipToken", arguments: token)
        }
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        print("📞 VoIP Push Received in Background")
        
        let data = payload.dictionaryPayload
        let callerName = data["callerName"] as? String ?? "Family Member"
        let callerId = data["callerId"] as? String ?? "unknown"
        let channelName = data["channelName"] as? String ?? UUID().uuidString
        
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerId)
        update.localizedCallerName = callerName
        update.hasVideo = false
        update.supportsHolding = false
        
        // REPORT CALL TO SYSTEM (This wakes up the screen even if locked)
        callProvider.reportNewIncomingCall(with: uuid, update: update) { error in
            if error == nil {
                // Store metadata in standard defaults for retrieval after app launch
                UserDefaults.standard.set(channelName, forKey: "pendingCallChannel")
                UserDefaults.standard.set(callerId, forKey: "pendingCallerId")
                UserDefaults.standard.set(callerName, forKey: "pendingCallerName")
            }
            completion()
        }
    }
    
    // MARK: - CXProviderDelegate
    
    func providerDidReset(_ provider: CXProvider) {}
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let channelName = UserDefaults.standard.string(forKey: "pendingCallChannel") ?? ""
        let callerId = UserDefaults.standard.string(forKey: "pendingCallerId") ?? ""
        let callerName = UserDefaults.standard.string(forKey: "pendingCallerName") ?? ""
        
        // Bridge the Answer action to Flutter
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.frt.voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("callAccepted", arguments: [
                "channelName": channelName,
                "callerId": callerId,
                "callerName": callerName
            ])
        }
        action.fulfill()
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.frt.voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("callEnded", arguments: nil)
        }
        action.fulfill()
        clearPendingCall()
    }
    
    func clearPendingCall() {
        UserDefaults.standard.removeObject(forKey: "pendingCallChannel")
        UserDefaults.standard.removeObject(forKey: "pendingCallerId")
        UserDefaults.standard.removeObject(forKey: "pendingCallerName")
    }
}

func registerPlugins(registry: FlutterPluginRegistry) {
    GeneratedPluginRegistrant.register(with: registry)
}
