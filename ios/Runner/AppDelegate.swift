import Flutter
import UIKit
import UserNotifications
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let appGroup = "group.com.patricklamphier.patrickMessenger"
  private var apnsChannel: FlutterMethodChannel?
  private var apnsToken: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
    UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    application.registerForRemoteNotifications()
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.patricklamphier.patrickMessenger/apns",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "getToken":
        result(self?.apnsToken)
      case "getSharedContainerPath":
        result(
          FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroup
          )?.path
        )
      case "configureNotificationExtension":
        guard
          let values = call.arguments as? [String: Any],
          let defaults = UserDefaults(suiteName: Self.appGroup)
        else {
          result(
            FlutterError(
              code: "invalid_notification_configuration",
              message: "Notification extension configuration is invalid.",
              details: nil
            )
          )
          return
        }
        defaults.set(values["homeserver"], forKey: "homeserver")
        defaults.set(values["accessToken"], forKey: "accessToken")
        defaults.set(values["userId"], forKey: "userId")
        defaults.set(values["showPreviews"], forKey: "showPreviews")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    apnsChannel = channel

    let ocrChannel = FlutterMethodChannel(
      name: "com.patricklamphier.patrickMessenger/ocr",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    ocrChannel.setMethodCallHandler { call, result in
      guard call.method == "recognize",
            let arguments = call.arguments as? [String: Any],
            let data = arguments["bytes"] as? FlutterStandardTypedData else {
        result(FlutterMethodNotImplemented)
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
          try VNImageRequestHandler(data: data.data).perform([request])
          let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
          DispatchQueue.main.async { result(text) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(
              code: "ocr_failed",
              message: error.localizedDescription,
              details: nil
            ))
          }
        }
      }
    }
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    super.application(
      application,
      didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
    )
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    apnsToken = token
    apnsChannel?.invokeMethod("token", arguments: token)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    super.application(
      application,
      didFailToRegisterForRemoteNotificationsWithError: error
    )
    apnsChannel?.invokeMethod("error", arguments: error.localizedDescription)
  }
}
