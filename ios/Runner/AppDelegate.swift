import Flutter
import Photos
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

    let mediaSaveChannel = FlutterMethodChannel(
      name: "com.patricklamphier.patrickMessenger/media_save",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    mediaSaveChannel.setMethodCallHandler { call, result in
      guard (call.method == "saveImage" || call.method == "saveVideo"),
            let arguments = call.arguments as? [String: Any],
            let name = arguments["name"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      if call.method == "saveVideo" {
        guard let sourcePath = arguments["path"] as? String else {
          result(FlutterError(
            code: "invalid_video",
            message: "The video file is invalid.",
            details: nil
          ))
          return
        }
        Self.saveMediaToPhotos(
          data: nil,
          fileURL: URL(fileURLWithPath: sourcePath),
          name: name,
          resourceType: .video,
          result: result
        )
      } else {
        guard let typedData = arguments["bytes"] as? FlutterStandardTypedData else {
          result(FlutterError(
            code: "invalid_picture",
            message: "The picture is invalid.",
            details: nil
          ))
          return
        }
        Self.saveMediaToPhotos(
          data: typedData.data,
          fileURL: nil,
          name: name,
          resourceType: .photo,
          result: result
        )
      }
    }
  }

  private static func saveMediaToPhotos(
    data: Data?,
    fileURL: URL?,
    name: String,
    resourceType: PHAssetResourceType,
    result: @escaping FlutterResult
  ) {
    let save: (PHAuthorizationStatus) -> Void = { status in
      let allowed: Bool
      if #available(iOS 14, *) {
        allowed = status == .authorized || status == .limited
      } else {
        allowed = status == .authorized
      }
      guard allowed else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "photo_permission_denied",
            message: "Photo library permission was denied.",
            details: nil
          ))
        }
        return
      }

      PHPhotoLibrary.shared().performChanges {
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = (name as NSString).lastPathComponent
        if let fileURL {
          request.addResource(with: resourceType, fileURL: fileURL, options: options)
        } else if let data {
          request.addResource(with: resourceType, data: data, options: options)
        }
      } completionHandler: { success, error in
        DispatchQueue.main.async {
          if success {
            result(nil)
          } else {
            result(FlutterError(
              code: "media_save_failed",
              message: error?.localizedDescription ?? "The media file could not be saved.",
              details: nil
            ))
          }
        }
      }
    }

    if #available(iOS 14, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: save)
    } else {
      PHPhotoLibrary.requestAuthorization(save)
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
