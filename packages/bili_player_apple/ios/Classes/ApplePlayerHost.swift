import AVFoundation
import AVKit
import Flutter
import UIKit

/// Owns one AVPlayer session and one AVPlayerLayer per Dart player id.
/// Platform views only re-parent the layer; they never create a second player.
final class ApplePlayerHost: NSObject {
  static let shared = ApplePlayerHost()

  private var messenger: FlutterBinaryMessenger?
  private var sessions: [Int: ApplePlayerSession] = [:]
  private var layers: [Int: AVPlayerLayer] = [:]
  private var eventChannels: [Int: FlutterEventChannel] = [:]
  private var pipController: AVPictureInPictureController?
  private var pipDelegate: ApplePictureInPictureDelegate?
  var pipChannel: FlutterMethodChannel?

  func attach(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let playerId = args["playerId"] as? Int
    else {
      result(FlutterError(
        code: "invalidArguments",
        message: "缺少 playerId",
        details: nil
      ))
      return
    }
    switch call.method {
    case "create":
      _ = ensureSession(playerId)
      result(nil)
    case "open":
      guard let session = ensureSession(playerId) else {
        result(FlutterError(code: "nativePlayback", message: "播放器未初始化", details: nil))
        return
      }
      session.open(args, result: result)
    case "play":
      session(playerId)?.play(rate: args["rate"] as? Double ?? 1)
      result(nil)
    case "pause":
      session(playerId)?.pause()
      result(nil)
    case "setRate":
      session(playerId)?.setRate(args["rate"] as? Double ?? 1)
      result(nil)
    case "setVolume":
      session(playerId)?.setVolume(args["volume"] as? Double ?? 1)
      result(nil)
    case "setGain":
      session(playerId)?.setGain(args["gainDb"] as? Double ?? 0)
      result(nil)
    case "seek":
      guard let session = session(playerId) else {
        result(FlutterError(code: "nativePlayback", message: "播放器未初始化", details: nil))
        return
      }
      session.seek(toMilliseconds: args["positionMs"] as? Int ?? 0, result: result)
    case "cancelSeek":
      session(playerId)?.cancelSeek()
      result(nil)
    case "reset":
      session(playerId)?.reset()
      result(nil)
    case "interrupt":
      session(playerId)?.interrupt()
      result(nil)
    case "inspect":
      result(session(playerId)?.inspect() ?? [:])
    case "captureFrame":
      guard let session = session(playerId) else {
        result(nil)
        return
      }
      session.captureFrame(result: result)
    case "dispose":
      disposeSession(playerId)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func layer(for playerId: Int) -> AVPlayerLayer {
    if let layer = layers[playerId] { return layer }
    let layer = AVPlayerLayer()
    layer.videoGravity = .resizeAspect
    layer.backgroundColor = UIColor.black.cgColor
    layers[playerId] = layer
    return layer
  }

  func session(_ playerId: Int) -> ApplePlayerSession? {
    sessions[playerId]
  }

  @discardableResult
  private func ensureSession(_ playerId: Int) -> ApplePlayerSession? {
    if let session = sessions[playerId] { return session }
    guard let messenger else { return nil }
    let layer = layer(for: playerId)
    let session = ApplePlayerSession(
      playerId: playerId,
      playerLayer: layer,
      host: self
    )
    sessions[playerId] = session
    let channel = FlutterEventChannel(
      name: "bilisail/apple_player/events/\(playerId)",
      binaryMessenger: messenger
    )
    channel.setStreamHandler(session)
    eventChannels[playerId] = channel
    return session
  }

  private func disposeSession(_ playerId: Int) {
    eventChannels[playerId]?.setStreamHandler(nil)
    eventChannels.removeValue(forKey: playerId)
    if let session = sessions.removeValue(forKey: playerId) {
      session.teardown()
    }
    if let layer = layers.removeValue(forKey: playerId) {
      if let pip = pipController, pip.playerLayer === layer {
        pip.stopPictureInPicture()
        pipController = nil
        pipDelegate = nil
      }
      layer.player = nil
      layer.removeFromSuperlayer()
    }
  }

  private func visibleLayer() -> AVPlayerLayer? {
    // Card previews can own small attached layers too. Prefer the largest
    // attached player layer so PiP always follows the full-screen player.
    let attached = layers.values.filter { $0.superlayer != nil && $0.player != nil }
    if let largest = attached.max(by: {
      $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
    }) {
      return largest
    }
    return layers.values.first { $0.superlayer != nil }
  }

  func handlePictureInPicture(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "isSupported":
      result(AVPictureInPictureController.isPictureInPictureSupported())
    case "enter":
      guard let layer = visibleLayer(), layer.superlayer != nil else {
        result(false)
        return
      }
      if pipController == nil || pipController?.playerLayer !== layer {
        pipController?.stopPictureInPicture()
        let controller = AVPictureInPictureController(playerLayer: layer)
        let delegate = ApplePictureInPictureDelegate(host: self)
        controller?.delegate = delegate
        pipController = controller
        pipDelegate = delegate
      }
      if #available(iOS 14.2, *) {
        pipController?.canStartPictureInPictureAutomaticallyFromInline = true
      }
      // `isPictureInPicturePossible` can remain false for a short moment after
      // the controller is created. The delegate reports the real outcome, so
      // acknowledge the request here instead of failing a valid transition.
      pipController?.startPictureInPicture()
      result(true)
    case "exit":
      pipController?.stopPictureInPicture()
      result(nil)
    case "isActive":
      result(pipController?.isPictureInPictureActive ?? false)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  fileprivate func notifyPictureInPicture(_ active: Bool) {
    pipChannel?.invokeMethod("changed", arguments: active)
  }
}

private final class ApplePictureInPictureDelegate: NSObject,
  AVPictureInPictureControllerDelegate {
  weak var host: ApplePlayerHost?

  init(host: ApplePlayerHost) {
    self.host = host
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    host?.notifyPictureInPicture(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    host?.notifyPictureInPicture(false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    host?.notifyPictureInPicture(false)
  }
}
