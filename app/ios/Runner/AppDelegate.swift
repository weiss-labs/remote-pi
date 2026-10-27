import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var notifications: FlutterMethodChannel?
  private var pushToken: String?
  private var pendingTaps: [[String: Any]] = []
  private var flutterReady = false
  private var visiblePeer: String?
  private var visibleRoom: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "ai.weisslabs.remotepi/notifications",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    notifications = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "status": self.readStatus(result)
      case "requestPermission":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, error in
          DispatchQueue.main.async {
            if error != nil {
              result(FlutterError(code: "permission_failed", message: "Unable to request notification permission", details: nil))
            } else { self.readStatus(result) }
          }
        }
      case "takeTaps":
        self.flutterReady = true
        let taps = self.pendingTaps
        self.pendingTaps.removeAll()
        result(taps)
      case "visibleTarget":
        let args = call.arguments as? [String: Any]
        self.visiblePeer = args?["peer"] as? String
        self.visibleRoom = args?["room"] as? String
        result(nil)
      case "openSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func readStatus(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        let permission: String
        switch settings.authorizationStatus {
        case .authorized: permission = "authorized"
        case .provisional: permission = "provisional"
        case .denied: permission = "denied"
        default: permission = "notDetermined"
        }
        // Registration is silent; authorization is only requested by the UI action.
        if permission == "authorized" || permission == "provisional" {
          UIApplication.shared.registerForRemoteNotifications()
        }
        let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String ?? ""
        result(["permission": permission, "token": self.pushToken ?? "",
                "environment": environment == "development" ? "sandbox" : environment])
      }
    }
  }

  override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    if pushToken != token {
      pushToken = token
      notifications?.invokeMethod("tokenChanged", arguments: nil)
    }
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    pushToken = nil
    notifications?.invokeMethod("registrationFailed", arguments: nil)
    // Do not log token, notification payload, or platform error details.
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
       let target = response.notification.request.content.userInfo["remote_pi"] as? [String: Any] {
      if flutterReady { notifications?.invokeMethod("tap", arguments: target) }
      else { pendingTaps.append(target); if pendingTaps.count > 16 { pendingTaps.removeFirst() } }
    }
    completionHandler()
  }

  override func userNotificationCenter(_ center: UNUserNotificationCenter,
    willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    let target = notification.request.content.userInfo["remote_pi"] as? [String: Any]
    let activeRoom = NotificationPresentationPolicy.suppress(
      isActive: UIApplication.shared.applicationState == .active,
      visiblePeer: visiblePeer, visibleRoom: visibleRoom, target: target)
    completionHandler(activeRoom ? [] : [.banner, .sound, .list])
  }
}
