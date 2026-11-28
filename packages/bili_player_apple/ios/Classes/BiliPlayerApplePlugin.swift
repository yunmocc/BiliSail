import AVFoundation
import AVKit
import Flutter
import UIKit

public final class BiliPlayerApplePlugin: NSObject, FlutterPlugin {
  private let host: ApplePlayerHost

  init(host: ApplePlayerHost) {
    self.host = host
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let host = ApplePlayerHost.shared
    host.attach(messenger: registrar.messenger())
    // AVPlayer activates this session on play. Category must be playback so
    // audio continues when the app is backgrounded or the device is locked.
    _ = try? AVAudioSession.sharedInstance().setCategory(
      .playback,
      mode: .moviePlayback,
      options: [.allowAirPlay, .allowBluetoothA2DP]
    )
    let instance = BiliPlayerApplePlugin(host: host)
    let channel = FlutterMethodChannel(
      name: "bilisail/apple_player",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.register(
      ApplePlayerSurfaceFactory(host: host),
      withId: "bilisail/apple_player_surface"
    )
    let pip = FlutterMethodChannel(
      name: "bilisail/picture_in_picture",
      binaryMessenger: registrar.messenger()
    )
    pip.setMethodCallHandler { [weak host] call, result in
      host?.handlePictureInPicture(call, result: result)
    }
    host.pipChannel = pip
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    host.handle(call, result: result)
  }
}
