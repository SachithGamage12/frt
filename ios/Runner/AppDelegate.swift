import Flutter
import UIKit
import FirebaseCore
import FirebaseMessaging
import GoogleMaps
import PushKit
import CallKit

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CXProviderDelegate {
    
    var voipRegistry: PKPushRegistry!
    var provider: CXProvider?
    
    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        
        Messaging.messaging().delegate = self as? MessagingDelegate
        GMSServices.provideAPIKey("AIzaSyBWRGXCiqYgZWCuxwlnosDjtuHZAC7SZjg")
        
        // Setup CallKit Provider
        let configuration = CXProviderConfiguration(localizedName: "FRT")
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.supportedHandleTypes = [.generic]
        
        provider = CXProvider(configuration: configuration)
        provider?.setDelegate(self, queue: nil)
        
        // Setup VoIP Push
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = [.voIP]
        
        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    // MARK: - PKPushRegistryDelegate
    
    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 Native VoIP Token: \(token)")
        
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.frt.voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("voipToken", arguments: token)
        }
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        
        let data = payload.dictionaryPayload["custom"] as? [String: Any] ?? payload.dictionaryPayload
        let channelName = data["channelName"] as? String ?? "incoming_call"
        let callerName = data["callerName"] as? String ?? "Family Member"
        
        // INSTANT REPORT: Satisfy Apple's requirement immediately
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.hasVideo = false
        
        let uuid = UUID()
        provider?.reportNewIncomingCall(with: uuid, update: update) { error in
            if error == nil {
                print("✅ Call Reported to CallKit")
            }
            completion()
        }
        
        // Notify Flutter so it can prepare the Agora connection
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.frt.voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("callAccepted", arguments: data)
        }
    }

    // MARK: - CXProviderDelegate
    func providerDidReset(_ provider: CXProvider) {}

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        // Signal Flutter to open the CallPage
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.frt.voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("answerAction", arguments: nil)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
        if let controller = window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.frt.voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("endAction", arguments: nil)
        }
    }
}
