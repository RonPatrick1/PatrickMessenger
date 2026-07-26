import Flutter
import UIKit
import UserNotifications

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
