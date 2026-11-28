import AVFoundation
import Flutter
import UIKit

final class ApplePlayerSurfaceFactory: NSObject, FlutterPlatformViewFactory {
  private let host: ApplePlayerHost

  init(host: ApplePlayerHost) {
    self.host = host
  }

  func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let playerId = (args as? [String: Any])?["playerId"] as? Int ?? -1
    return ApplePlayerSurfaceView(host: host, playerId: playerId, frame: frame)
  }
}

final class ApplePlayerSurfaceView: NSObject, FlutterPlatformView {
  private let container: ApplePlayerSurfaceContainer

  init(host: ApplePlayerHost, playerId: Int, frame: CGRect) {
    container = ApplePlayerSurfaceContainer(
      frame: frame,
      videoLayer: host.layer(for: playerId)
    )
    super.init()
  }

  func view() -> UIView {
    container
  }
}

final class ApplePlayerSurfaceContainer: UIView {
  private let videoLayer: AVPlayerLayer

  init(frame: CGRect, videoLayer: AVPlayerLayer) {
    self.videoLayer = videoLayer
    super.init(frame: frame)
    backgroundColor = .black
    isUserInteractionEnabled = false
    layer.addSublayer(videoLayer)
    videoLayer.frame = bounds
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    videoLayer.frame = bounds
    CATransaction.commit()
  }

  deinit {
    if videoLayer.superlayer === layer {
      videoLayer.removeFromSuperlayer()
    }
  }
}
