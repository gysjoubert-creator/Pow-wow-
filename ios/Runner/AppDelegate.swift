import UIKit
import CallKit
import AVFAudio
import PushKit
import Flutter
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CallkitIncomingAppDelegate {
    var voipRegistry: PKPushRegistry?
    private let callkitActivationUrl = URL(string: "powwow://callkit-answer")!

    private func activateAppSceneIfNeeded(source: String) {
        DispatchQueue.main.async {
            guard #available(iOS 13.0, *) else { return }

            let preferredSession = UIApplication.shared.connectedScenes
                .first { $0.activationState != .unattached }?
                .session

            UIApplication.shared.requestSceneSessionActivation(
                preferredSession,
                userActivity: nil,
                options: nil
            ) { error in
                print("#### AppDelegate:: \(source) scene activation failed: \(error.localizedDescription)")
            }
        }
    }

    private func openAppFromCallkit(source: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350)) {
            self.activateAppSceneIfNeeded(source: source)
            UIApplication.shared.open(self.callkitActivationUrl, options: [:]) { success in
                print("#### AppDelegate:: \(source) open(powwow://callkit-answer) success = \(success)")
            }
        }
    }

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        
        //Setup VOIP
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry?.delegate = self
        voipRegistry?.desiredPushTypes = [PKPushType.voIP]
        
        // Required for CallKit + WebRTC: use manual audio so CallKit can own the session.
        // Set isAudioEnabled=true immediately so normal PTT works without a CallKit call.
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        
        //Add for Missed call notification
        if #available(iOS 10.0, *) {
            UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
        }
       
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    
    // Add for Missed call notification(show notification when foreground)
    override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                         willPresent notification: UNNotification,
                                         withCompletionHandler completionHandler:
                                         @escaping (UNNotificationPresentationOptions) -> Void) {
        
        CallkitNotificationManager.shared.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
    
    // Add for Missed call notification(action when click callback in missed notification)
    override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                         didReceive response: UNNotificationResponse,
                                         withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == CallkitNotificationManager.CALLBACK_ACTION {
            let data = response.notification.request.content.userInfo as? [String: Any]
            SwiftFlutterCallkitIncomingPlugin.sharedInstance?.sendCallbackEvent(data)
        }
        completionHandler()
    }
    
    
    
    // Call back from Recent history
    override func application(_ application: UIApplication,
                              continue userActivity: NSUserActivity,
                              restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        
        guard let handleObj = userActivity.handle else {
            return false
        }
        
        guard let isVideo = userActivity.isVideo else {
            return false
        }
        let objData = handleObj.getDecryptHandle()
        let nameCaller = objData["nameCaller"] as? String ?? ""
        let handle = objData["handle"] as? String ?? ""
        let data = flutter_callkit_incoming.Data(id: UUID().uuidString, nameCaller: nameCaller, handle: handle, type: isVideo ? 1 : 0)
        //set more data...
        //data.nameCaller = nameCaller
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.startCall(data, fromPushKit: true)
        
        return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }
    
    // Handle updated push credentials
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        let deviceToken = credentials.token.map { String(format: "%02x", $0) }.joined()
        print("#### AppDelegate:: deviceToken = \(deviceToken)")
       
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(deviceToken)
    }
    
    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("#### AppDelegate:: didInvalidatePushTokenFor")
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
    }
    
    // Handle incoming pushes
    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        print("#### AppDelegate:: didReceiveIncomingPushWith payload = \(payload.dictionaryPayload), type = \(type)")
        guard type == .voIP else { return }
        
        let id = payload.dictionaryPayload["callUUID"] as? String ?? ""
        let nameCaller = payload.dictionaryPayload["callerName"] as? String ?? ""
        //let handle = payload.dictionaryPayload["handle"] as? String ?? ""
        //let isVideo = payload.dictionaryPayload["isVideo"] as? Bool ?? false
        let handle = payload.dictionaryPayload["handle"] as? String ?? "audio"
        let isVideo = payload.dictionaryPayload["isVideo"] as? Bool ?? false;
        let data = flutter_callkit_incoming.Data(id: id, nameCaller: nameCaller, handle: handle, type: isVideo ? 1 : 0)
        //set more data
        //data.extra = ["user": "abc@123", "platform": "ios"]
        //data.iconName = ...
        //data.....
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(data, fromPushKit: true){
            completion()
        }
    }
    
    
    func onAccept(_ call: Call, _ action: CXAnswerCallAction) {
        print("#### AppDelegate:: LOG: onAccept")
        action.fulfill()
        openAppFromCallkit(source: "onAccept")
    }

    func onDecline(_ call: Call, _ action: CXEndCallAction) {
        print("#### AppDelegate:: LOG: onDecline")
        action.fulfill()
    }

    func onEnd(_ call: Call, _ action: CXEndCallAction) {
        print("#### AppDelegate:: LOG: onEnd")
        action.fulfill()
    }

    func onTimeOut(_ call: Call) {
        print("#### AppDelegate:: LOG: onTimeOut")
    }
    
    // Func Callback Toggle Audio Session
    func didActivateAudioSession(_ audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    // Func Callback Toggle Audio Session
    func didDeactivateAudioSession(_ audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        // Restore audio for normal PTT use after CallKit call ends.
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }
    
}
