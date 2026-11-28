import Flutter
import Network
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private lazy var downloads = BackgroundDownloads()
  private var downloadPhotos: DownloadPhotosHandler?
  private var deviceOrientation: DeviceOrientationHandler?
  private var windowBrightness: WindowBrightnessHandler?
  private var liveNetworkChannel: FlutterMethodChannel?
  private var appIconChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                            completionHandler: @escaping () -> Void) {
    if identifier == BackgroundDownloads.identifier {
      downloads.handleEvents(completion: completionHandler)
    } else {
      super.application(application, handleEventsForBackgroundURLSession: identifier, completionHandler: completionHandler)
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    downloads.attach(to: engineBridge.applicationRegistrar.messenger())
    downloadPhotos = DownloadPhotosHandler(messenger: engineBridge.applicationRegistrar.messenger())
    windowBrightness = WindowBrightnessHandler(messenger: engineBridge.applicationRegistrar.messenger())
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "bilisail/app_icon", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      let application = UIApplication.shared
      if call.method == "getIcon" {
        result(application.alternateIconName == "BilibiliIcon" ? "bilibili" : "bilisail")
      } else if call.method == "setIcon" {
        guard let arguments = call.arguments as? [String: Any],
              let icon = arguments["icon"] as? String,
              icon == "bilisail" || icon == "bilibili" else {
          result(FlutterError(code: "invalid_icon", message: "Unknown application icon.", details: nil))
          return
        }
        let name: String? = icon == "bilibili" ? "BilibiliIcon" : nil
        if application.alternateIconName == name { result(nil); return }
        guard application.supportsAlternateIcons else {
          result(FlutterError(code: "unsupported", message: "Alternate icons are unavailable.", details: nil))
          return
        }
        application.setAlternateIconName(name) { error in
          DispatchQueue.main.async {
            if error != nil {
              result(FlutterError(code: "icon_change_failed", message: "Cannot change the application icon.", details: nil))
            } else { result(nil) }
          }
        }
      } else { result(FlutterMethodNotImplemented) }
    }
    let network = FlutterMethodChannel(name: "dev.bilisail/live_network", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    network.setMethodCallHandler { call, result in
      guard call.method == "preferOriginal" else { result(FlutterMethodNotImplemented); return }
      let monitor = NWPathMonitor()
      var completed = false
      func finish(_ preferOriginal: Bool) {
        guard !completed else { return }
        completed = true
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        result(preferOriginal)
      }
      monitor.pathUpdateHandler = { path in finish(path.usesInterfaceType(.wifi)) }
      monitor.start(queue: .main)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(true) }
    }
    liveNetworkChannel = network
    appIconChannel = channel
    deviceOrientation = DeviceOrientationHandler(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// Bridges the shared window-brightness channel to the real display brightness.
///
/// iOS has no per-window override, so the swipe gesture changes the system
/// brightness like Control Center does. The first write snapshots the original
/// value and `reset` restores it when the player leaves.
final class WindowBrightnessHandler {
  private let channel: FlutterMethodChannel
  private var original: CGFloat?
  private var owner: Int?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "bilisail/window_brightness",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      let arguments = call.arguments as? [String: Any]
      let caller = (arguments?["owner"] as? NSNumber)?.intValue
      switch call.method {
      case "get":
        result(Double(UIScreen.main.brightness))
      case "set":
        guard let raw = arguments?["value"] as? NSNumber else {
          result(
            FlutterError(
              code: "invalid_value",
              message: "Brightness must be a number.",
              details: nil
            )
          )
          return
        }
        let value = raw.doubleValue
        guard value.isFinite else {
          result(
            FlutterError(
              code: "invalid_value",
              message: "Brightness must be finite.",
              details: nil
            )
          )
          return
        }
        if original == nil { original = UIScreen.main.brightness }
        owner = caller
        UIScreen.main.brightness = CGFloat(min(max(value, 0), 1))
        result(nil)
      case "reset":
        // A stale owner must not restore brightness owned by a newer player.
        if let caller, let owner, caller != owner {
          result(nil)
          return
        }
        if let original {
          UIScreen.main.brightness = original
          self.original = nil
          owner = nil
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
