import Flutter
import UIKit
import UserNotifications
import QuickLook
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var artifacts: ArtifactViewer?
  private var pasteboard: PasteboardBridge?
  private var shareInbox: ShareInboxBridge?
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
    artifacts = ArtifactViewer(messenger: engineBridge.applicationRegistrar.messenger())
    pasteboard = PasteboardBridge(messenger: engineBridge.applicationRegistrar.messenger())
    shareInbox = ShareInboxBridge(messenger: engineBridge.applicationRegistrar.messenger())
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

/// Receives verified bytes only. Never accepts desktop URLs or arbitrary paths.
private final class ArtifactViewer: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
  private let channel: FlutterMethodChannel
  private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paired-artifacts", isDirectory: true)
  private var file: URL?
  private var controller: UIViewController?
  private var completion: FlutterResult?
  private var expiry: Timer?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ai.weisslabs.remotepi/artifacts", binaryMessenger: messenger)
    super.init()
    try? FileManager.default.removeItem(at: directory)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "preview": self.open(call.arguments, result)
      case "dismiss":
        self.controller?.dismiss(animated: false)
        self.cleanup()
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func open(_ arguments: Any?, _ result: @escaping FlutterResult) {
    guard completion == nil,
      let args = arguments as? [String: Any],
      let typed = args["bytes"] as? FlutterStandardTypedData,
      let ext = args["extension"] as? String,
      ["pdf", "png", "jpg", "gif", "webp", "html"].contains(ext),
      !typed.data.isEmpty, typed.data.count <= 20 * 1024 * 1024 else {
      result(FlutterError(code: "invalid_preview", message: "Invalid preview data", details: nil)); return
    }
    let data = typed.data
    let prefix = [UInt8](data.prefix(12))
    let valid: Bool
    switch ext {
    case "pdf": valid = data.starts(with: Data("%PDF-".utf8))
    case "png": valid = prefix.starts(with: [137,80,78,71,13,10,26,10])
    case "jpg": valid = prefix.starts(with: [255,216,255])
    case "gif": valid = data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8))
    case "webp": valid = prefix.count >= 12 && String(bytes: prefix[0..<4], encoding: .ascii) == "RIFF" && String(bytes: prefix[8..<12], encoding: .ascii) == "WEBP"
    case "html": valid = String(data: data, encoding: .utf8)?.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" }).first == "<"
    default: valid = false
    }
    guard valid else { result(FlutterError(code: "invalid_signature", message: "Invalid file signature", details: nil)); return }
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
      var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      result(FlutterError(code: "unavailable", message: "No active viewer", details: nil)); return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.complete])
      var folder = directory
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try folder.setResourceValues(values)
      let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
      try data.write(to: url, options: [.atomic, .completeFileProtection])
      let preview: UIViewController
      if ext == "html" {
        preview = HTMLPreview(file: url) { [weak self] in self?.cleanup() }
      } else {
        guard QLPreviewController.canPreview(url as NSURL) else {
          try? FileManager.default.removeItem(at: url)
          result(FlutterError(code: "unsupported", message: "This format cannot be previewed", details: nil)); return
        }
        let quickLook = QLPreviewController()
        quickLook.dataSource = self
        quickLook.delegate = self
        preview = quickLook
      }
      file = url
      completion = result
      controller = preview
      presenter.present(preview, animated: true) { [weak self] in
        // Cancellation can race UIKit's presentation animation.
        if self?.file != url { preview.dismiss(animated: false) }
      }
      expiry = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
        self?.controller?.dismiss(animated: false)
        self?.cleanup()
      }
    } catch {
      cleanup()
      result(FlutterError(code: "cache_failed", message: "Unable to prepare private preview", details: nil))
    }
  }
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int { self.controller === controller && file != nil ? 1 : 0 }
  func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { ((self.controller === controller ? file : nil) ?? directory.appendingPathComponent("unavailable")) as NSURL }
  func previewControllerDidDismiss(_ controller: QLPreviewController) {
    if self.controller === controller { cleanup() }
  }
  private func cleanup() {
    expiry?.invalidate()
    expiry = nil
    try? FileManager.default.removeItem(at: directory)
    file = nil
    controller = nil
    let result = completion
    completion = nil
    result?(nil)
  }
}

/// Weiss Labs: a paired HTML artifact (e.g. a clickable mockup) in a sandboxed web view.
/// Scripts run so mockups stay interactive, but network requests and WebRTC are blocked, the
/// page can read only its own file, nothing persists, and it cannot navigate elsewhere.
private final class HTMLPreview: UINavigationController, WKNavigationDelegate {
  private let file: URL
  private let onClose: () -> Void
  private let web: WKWebView
  private static let offlineGuard = #"(()=>{for(const k of ["RTCPeerConnection","webkitRTCPeerConnection","RTCDataChannel","RTCIceTransport","RTCIceCandidate","RTCSessionDescription","RTCRtpSender","RTCRtpReceiver","RTCRtpTransceiver","WebTransport","EventSource"]){try{delete window[k]}catch(e){}}for(const p of ["contentWindow","contentDocument"]){try{Object.defineProperty(HTMLIFrameElement.prototype,p,{get(){return null},configurable:false})}catch(e){}}window.open=()=>null;})();"#

  init(file: URL, onClose: @escaping () -> Void) {
    self.file = file
    self.onClose = onClose
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    // Content rules don't cover WebRTC/WebTransport connections, so remove those APIs
    // (and fresh-realm escapes via iframes/window.open) before any page script runs.
    config.userContentController.addUserScript(WKUserScript(source: HTMLPreview.offlineGuard, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    web = WKWebView(frame: .zero, configuration: config)
    let page = UIViewController()
    page.view = web
    page.title = "Preview"
    super.init(rootViewController: page)
    modalPresentationStyle = .fullScreen
    page.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
    web.navigationDelegate = self
    let blockNetwork = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}}]"#
    WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "remotepi-offline-preview", encodedContentRuleList: blockNetwork) { [weak self] list, _ in
      guard let self = self else { return }
      // Fail closed: without the offline rule the page is never loaded.
      guard let list = list else { self.web.loadHTMLString("<p style='font:17px -apple-system;padding:24px'>Preview unavailable.</p>", baseURL: nil); return }
      self.web.configuration.userContentController.add(list)
      self.web.loadFileURL(self.file, allowingReadAccessTo: self.file)
    }
  }
  required init?(coder: NSCoder) { nil }

  @objc private func done() { dismiss(animated: true) { [onClose] in onClose() } }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url else { return decisionHandler(.cancel) }
    var bare = URLComponents(url: url, resolvingAgainstBaseURL: false)
    bare?.fragment = nil
    decisionHandler(bare?.url == file || url.absoluteString == "about:blank" ? .allow : .cancel)
  }
}
