import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import UIKit

/// One AVPlayer, its single AVPlayerLayer, and all observation for one source.
/// Created and owned by ApplePlayerHost; never exposes native errors or URLs.
final class ApplePlayerSession: NSObject {
  let playerId: Int
  let player = AVPlayer()
  let playerLayer: AVPlayerLayer

  private weak var host: ApplePlayerHost?
  private var generation: Int = -1
  private var sink: FlutterEventSink?
  private var itemObservers: [NSKeyValueObservation] = []
  private var playerObservers: [NSKeyValueObservation] = []
  private var layerObserver: NSKeyValueObservation?
  private var notificationTokens: [NSObjectProtocol] = []
  private var timeObserver: Any?
  private var openTimeout: DispatchWorkItem?
  private var openResult: FlutterResult?
  private var pendingSeekResult: FlutterResult?
  private var seekGeneration = 0
  private var desiredRate: Float = 1
  private var storedGainDb: Double = 0
  private var muted = false
  private var firstFrameSent = false
  private var lastBuffering: Bool?
  private var lastPlaying: Bool?
  private var frameOutput: AVPlayerItemVideoOutput?
  private var currentAudioURL: URL?
  private var disposed = false

  init(playerId: Int, playerLayer: AVPlayerLayer, host: ApplePlayerHost) {
    self.playerId = playerId
    self.playerLayer = playerLayer
    self.host = host
    super.init()
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = true
    if #available(iOS 13.0, *) {
      player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }
    playerLayer.player = player
    playerLayer.videoGravity = .resizeAspect
    playerLayer.backgroundColor = UIColor.black.cgColor
    addObservers()
  }

  deinit {
    teardown()
  }

  func attach(eventSink: FlutterEventSink?) {
    sink = eventSink
    if let eventSink {
      eventSink(["event": "attached", "generation": generation])
    }
  }

  func detachEventSink() {
    sink = nil
  }

  // MARK: - Commands

  func open(_ args: [String: Any], result: @escaping FlutterResult) {
    guard !disposed else {
      result(FlutterError(code: "disposed", message: "播放器已释放", details: nil))
      return
    }
    guard let generation = args["generation"] as? Int,
          let urlString = args["videoUrl"] as? String,
          let videoURL = URL(string: urlString) else {
      result(FlutterError(code: "invalidSource", message: "播放地址无效", details: nil))
      return
    }
    let kind = args["kind"] as? String ?? "progressive"
    let audioURL = (args["audioUrl"] as? String).flatMap(URL.init(string:))
    let headers = (args["headers"] as? [String: String]) ?? [:]
    let live = args["live"] as? Bool ?? false
    let muted = args["muted"] as? Bool ?? false
    let audioOnly = args["audioOnly"] as? Bool ?? false
    let videoExpected = args["videoExpected"] as? Bool ?? !audioOnly
    let startPositionMs = args["startPositionMs"] as? Int ?? 0
    let rate = args["rate"] as? Double ?? 1
    let volume = args["volume"] as? Double ?? 1
    let gainDb = args["gainDb"] as? Double ?? 0
    let bufferAheadMs = args["maxBufferAheadMs"] as? Double ?? 16000
    let timeoutMs = args["timeoutMs"] as? Double ?? 35000

    resetItem()
    self.generation = generation
    self.openResult = result
    self.muted = muted
    self.storedGainDb = gainDb
    self.desiredRate = Float(rate)
    self.currentAudioURL = audioURL
    player.isMuted = muted
    player.volume = Float(min(max(volume, 0), 1))

    let work = DispatchWorkItem { [weak self] in
      self?.failOpen(code: "nativePlayback", message: "打开播放源超时")
    }
    openTimeout = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(timeoutMs / 1000, 1),
      execute: work
    )

    buildItem(
      kind: kind,
      videoURL: videoURL,
      audioURL: audioURL,
      headers: headers,
      live: live,
      videoExpected: videoExpected,
      audioOnly: audioOnly,
      bufferAheadMs: bufferAheadMs
    ) { [weak self] result in
      guard let self, !self.disposed else { return }
      DispatchQueue.main.async {
        // A superseded open must never fail or install into the newer request.
        guard self.generation == generation, self.openResult != nil else {
          return
        }
        switch result {
        case .failure(let error):
          self.failOpen(
            code: self.errorCode(error),
            message: error.localizedDescription
          )
        case .success(let item):
          self.install(
            item: item,
            generation: generation,
            startPositionMs: startPositionMs
          )
        }
      }
    }
  }

  func play(rate: Double) {
    desiredRate = Float(max(rate, 0.1))
    player.play()
    player.rate = desiredRate
  }

  func pause() {
    player.pause()
  }

  func setRate(_ rate: Double) {
    desiredRate = Float(max(rate, 0.1))
    if player.timeControlStatus == .playing || player.rate > 0 {
      player.rate = desiredRate
    }
  }

  func setVolume(_ volume: Double) {
    player.volume = Float(min(max(volume, 0), 1))
  }

  func setGain(_ gainDb: Double) {
    storedGainDb = gainDb
    applyAudioGain()
  }

  /// AVPlayer reports indeterminate times as NaN; converting those to Int traps.
  private func safeMilliseconds(_ seconds: Double) -> Int {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int(min(seconds * 1000, Double(Int.max)))
  }

  private func currentMilliseconds() -> Int {
    safeMilliseconds(player.currentTime().seconds)
  }

  func seek(toMilliseconds value: Int, result: @escaping FlutterResult) {
    guard let item = player.currentItem else {
      result(FlutterError(code: "nativePlayback", message: "当前没有播放源", details: nil))
      return
    }
    pendingSeekResult?(FlutterError(code: "seekCancelled", message: "定位被新的定位取消", details: nil))
    pendingSeekResult = result
    seekGeneration += 1
    let token = seekGeneration
    var seconds = Double(value) / 1000
    let duration = CMTimeGetSeconds(item.duration)
    if duration.isFinite && duration > 0 {
      seconds = min(max(seconds, 0), duration)
    }
    if let range = item.seekableTimeRanges.last?.timeRangeValue {
      let start = range.start.seconds
      let end = range.end.seconds
      if end.isFinite && end > start {
        seconds = min(max(seconds, start), end)
      }
    }
    player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] finished in
      guard let self, token == self.seekGeneration else { return }
      let pending = self.pendingSeekResult
      self.pendingSeekResult = nil
      if finished {
        pending?(Double(self.currentMilliseconds()))
      } else {
        pending?(FlutterError(code: "seekCancelled", message: "定位已取消", details: nil))
      }
    }
  }

  func cancelSeek() {
    seekGeneration += 1
    pendingSeekResult?(FlutterError(code: "seekCancelled", message: "定位已取消", details: nil))
    pendingSeekResult = nil
    player.currentItem?.cancelPendingSeeks()
  }

  func interrupt() {
    player.pause()
    cancelSeek()
  }

  func inspect() -> [String: Any] {
    let item = player.currentItem
    let position = currentMilliseconds()
    let duration = validSeconds(item?.duration)
    let buffered = bufferedSeconds()
    let (width, height) = dimensions()
    let videoTrack = item?.asset.tracks(withMediaType: .video).first
    let audioTrack = item?.asset.tracks(withMediaType: .audio).first
    let accessLog = item?.accessLog()?.events.last
    let codec = videoTrack.flatMap(codecName)
    let audioCodec = audioTrack.flatMap(codecName)
    let audioInfo = audioTrack.flatMap(audioDescription)
    var info: [String: Any] = [
      "positionMs": position,
      "durationMs": safeMilliseconds(duration),
      "bufferedMs": safeMilliseconds(buffered),
      "width": width,
      "height": height,
      "hasVideo": videoTrack != nil,
      "hasAudio": audioTrack != nil,
      "rate": Double(player.rate),
      "volume": Double(player.volume),
      "isMuted": player.isMuted,
      "videoOutput": "AVPlayerLayer",
      "audioOutput": "AVPlayer",
      "hardwareDecoder": videoTrack == nil ? "" : "videotoolbox",
      "pixelFormat": videoTrack == nil ? "" : "nv12",
      "audioOutputFormat": "AVPlayer",
    ]
    if let codec { info["videoCodec"] = codec }
    if let audioCodec {
      info["audioCodec"] = audioCodec
      info["atmos"] = audioCodec == "eac3"
    }
    if let audioInfo {
      info["audioChannels"] = audioInfo.channels
      info["audioSampleRate"] = audioInfo.sampleRate
    }
    if let rate = videoTrack?.nominalFrameRate, rate > 0 {
      info["nominalFrameRate"] = Double(rate)
    }
    if let bitrate = videoTrack?.estimatedDataRate, bitrate > 0 {
      info["videoBitrate"] = Double(bitrate) / 1000
      info["videoNominalBitrate"] = Double(bitrate) / 1000
    }
    if let observed = accessLog?.observedBitrate, observed > 0 {
      info["videoBitrate"] = observed / 1000
    }
    if let raw = videoTrack?.formatDescriptions.first {
      let format = raw as! CMFormatDescription
      if let primaries = stringExtension(
        format,
        kCMFormatDescriptionExtension_ColorPrimaries
      ) {
        info["colorPrimaries"] = primaries
      }
      if let transfer = stringExtension(
        format,
        kCMFormatDescriptionExtension_TransferFunction
      ) {
        info["transferFunction"] = transfer
      }
      if let matrix = stringExtension(
        format,
        kCMFormatDescriptionExtension_YCbCrMatrix
      ) {
        info["colorMatrix"] = matrix
      }
    }
    return info
  }

  func captureFrame(result: @escaping FlutterResult) {
    guard let item = player.currentItem else {
      result(nil)
      return
    }
    let output: AVPlayerItemVideoOutput
    if let existing = frameOutput {
      output = existing
    } else {
      let created = AVPlayerItemVideoOutput(
        pixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
      )
      item.add(created)
      frameOutput = created
      output = created
    }
    let time = player.currentTime()
    guard output.hasNewPixelBuffer(forItemTime: time),
          let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    else {
      result(nil)
      return
    }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
      result(nil)
      return
    }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let rowBytes = width * 4
    var data = Data(count: rowBytes * height)
    data.withUnsafeMutableBytes { destination in
      guard let target = destination.baseAddress else { return }
      for row in 0..<height {
        memcpy(
          target.advanced(by: row * rowBytes),
          base.advanced(by: row * stride),
          rowBytes
        )
      }
    }
    result([
      "bytes": FlutterStandardTypedData(bytes: data),
      "width": width,
      "height": height,
    ])
  }

  func reset() {
    resetItem()
  }

  func teardown() {
    guard !disposed else { return }
    disposed = true
    resetItem()
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    playerObservers.forEach { $0.invalidate() }
    playerObservers.removeAll()
    layerObserver?.invalidate()
    layerObserver = nil
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    notificationTokens.removeAll()
    player.pause()
    player.replaceCurrentItem(with: nil)
    playerLayer.player = nil
    sink = nil
  }

  // MARK: - Item construction

  private func buildItem(
    kind: String,
    videoURL: URL,
    audioURL: URL?,
    headers: [String: String],
    live: Bool,
    videoExpected: Bool,
    audioOnly: Bool,
    bufferAheadMs: Double,
    completion: @escaping (Result<AVPlayerItem, Error>) -> Void
  ) {
    let videoAsset = makeAsset(
      videoURL,
      headers: headers,
      mime: audioOnly ? "audio/mp4" : "video/mp4"
    )
    let audioAsset = audioURL.map {
      makeAsset($0, headers: headers, mime: "audio/mp4")
    }
    let keys = ["playable", "duration", "tracks"]
    load(videoAsset, keys: keys) { [weak self] videoError in
      guard let self else { return }
      if let videoError {
        completion(.failure(videoError))
        return
      }
      guard kind == "dash", let audioAsset else {
        let item = AVPlayerItem(asset: videoAsset)
        self.configure(item: item, live: live, bufferAheadMs: bufferAheadMs)
        completion(.success(item))
        return
      }
      self.load(audioAsset, keys: keys) { audioError in
        if let audioError {
          completion(.failure(audioError))
          return
        }
        do {
          let composition = try self.makeComposition(
            video: videoAsset,
            audio: audioAsset
          )
          let item = AVPlayerItem(asset: composition)
          self.configure(item: item, live: live, bufferAheadMs: bufferAheadMs)
          completion(.success(item))
        } catch {
          completion(.failure(error))
        }
      }
    }
  }

  private func makeAsset(
    _ url: URL,
    headers: [String: String],
    mime: String
  ) -> AVURLAsset {
    if url.isFileURL {
      return AVURLAsset(url: url)
    }
    var options: [String: Any] = [:]
    if !headers.isEmpty {
      // TrollStore sideloading path: AVFoundation's documented header option
      // is unavailable, so use the widely deployed asset option. No request
      // data leaves this process except to the media host.
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    // Bilibili serves DASH tracks as `.m4s`, which AVFoundation does not map to
    // a container on its own. The out-of-band MIME option uses the same string
    // value as the AVFoundation constant, which is not exposed to Swift on iOS.
    let ext = url.pathExtension.lowercased()
    if ext == "m4s" || ext.isEmpty {
      options["AVURLAssetOutOfBandMIMETypeKey"] = mime
    }
    return AVURLAsset(url: url, options: options)
  }

  private func load(
    _ asset: AVAsset,
    keys: [String],
    completion: @escaping (Error?) -> Void
  ) {
    asset.loadValuesAsynchronously(forKeys: keys) {
      var firstError: Error?
      for key in keys {
        var error: NSError?
        if asset.statusOfValue(forKey: key, error: &error) == .failed {
          firstError = error ?? NSError(
            domain: "BiliSail.ApplePlayer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "媒体加载失败"]
          )
          break
        }
      }
      completion(firstError)
    }
  }

  private func makeComposition(
    video: AVAsset,
    audio: AVAsset
  ) throws -> AVMutableComposition {
    guard let videoTrack = video.tracks(withMediaType: .video).first else {
      throw NSError(
        domain: "BiliSail.ApplePlayer",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "未检测到视频轨道"]
      )
    }
    guard let audioTrack = audio.tracks(withMediaType: .audio).first else {
      throw NSError(
        domain: "BiliSail.ApplePlayer",
        code: -3,
        userInfo: [NSLocalizedDescriptionKey: "未检测到音频轨道"]
      )
    }
    let composition = AVMutableComposition()
    guard let targetVideo = composition.addMutableTrack(
      withMediaType: .video,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ), let targetAudio = composition.addMutableTrack(
      withMediaType: .audio,
      preferredTrackID: kCMPersistentTrackID_Invalid
    ) else {
      throw NSError(
        domain: "BiliSail.ApplePlayer",
        code: -4,
        userInfo: [NSLocalizedDescriptionKey: "无法创建播放合成"]
      )
    }
    let videoDuration = video.duration
    let audioDuration = audio.duration
    try targetVideo.insertTimeRange(
      CMTimeRange(start: .zero, duration: videoDuration),
      of: videoTrack,
      at: .zero
    )
    let audioRange = CMTimeRange(
      start: .zero,
      duration: CMTimeMinimum(videoDuration, audioDuration)
    )
    try targetAudio.insertTimeRange(audioRange, of: audioTrack, at: .zero)
    targetVideo.preferredTransform = videoTrack.preferredTransform
    let transformed = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
    composition.naturalSize = CGSize(
      width: abs(transformed.width),
      height: abs(transformed.height)
    )
    return composition
  }

  private func configure(item: AVPlayerItem, live: Bool, bufferAheadMs: Double) {
    item.audioTimePitchAlgorithm = .timeDomain
    if !live {
      item.preferredForwardBufferDuration = min(max(bufferAheadMs / 1000, 1), 30)
    }
  }

  private func install(
    item: AVPlayerItem,
    generation: Int,
    startPositionMs: Int
  ) {
    guard self.generation == generation else { return }
    observe(item: item)
    player.replaceCurrentItem(with: item)
    player.isMuted = muted
    player.volume = Float(min(max(player.volume, 0), 1))
    applyAudioGain()
    if startPositionMs > 0 {
      player.seek(
        to: CMTime(value: CMTimeValue(startPositionMs), timescale: 1000),
        toleranceBefore: .zero,
        toleranceAfter: .zero,
        completionHandler: { _ in }
      )
    }
    if item.status == .readyToPlay {
      finishOpen(item: item)
    } else if item.status == .failed {
      failOpen(code: errorCode(item.error), message: item.error?.localizedDescription)
    }
  }

  private func observe(item: AVPlayerItem) {
    itemObservers.forEach { $0.invalidate() }
    itemObservers = [
      item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
        guard let self else { return }
        DispatchQueue.main.async {
          if item.status == .readyToPlay {
            self.finishOpen(item: item)
          } else if item.status == .failed {
            if self.openResult != nil {
              self.failOpen(
                code: self.errorCode(item.error),
                message: item.error?.localizedDescription
              )
            } else {
              self.sendFailure(code: self.errorCode(item.error))
            }
          }
        }
      },
      item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
        guard let self else { return }
        DispatchQueue.main.async {
          if item.isPlaybackBufferEmpty {
            self.setBuffering(true)
          }
        }
      },
      item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
        guard let self else { return }
        DispatchQueue.main.async {
          self.updateBuffering()
        }
      },
      item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
        guard let self else { return }
        DispatchQueue.main.async { self.sendSample() }
      },
    ]
  }

  private func finishOpen(item: AVPlayerItem) {
    guard openResult != nil else { return }
    let (width, height) = dimensions()
    let duration = validSeconds(item.duration)
    let hasVideo = !item.asset.tracks(withMediaType: .video).isEmpty
    let hasAudio = !item.asset.tracks(withMediaType: .audio).isEmpty
    let externalAudio = currentAudioURL != nil
    let info: [String: Any] = [
      "generation": generation,
      "durationMs": safeMilliseconds(duration),
      "width": width,
      "height": height,
      "hasVideo": hasVideo,
      "hasAudio": hasAudio,
      "externalAudio": externalAudio,
      "positionMs": currentMilliseconds(),
    ]
    send([
      "event": "ready",
      "generation": generation,
      "durationMs": safeMilliseconds(duration),
      "width": width,
      "height": height,
      "hasVideo": hasVideo,
      "hasAudio": hasAudio,
    ])
    openTimeout?.cancel()
    openTimeout = nil
    let callback = openResult
    openResult = nil
    callback?(info)
    if playerLayer.isReadyForDisplay {
      markFirstFrame()
    }
  }

  private func failOpen(code: String, message: String?) {
    guard let callback = openResult else { return }
    openResult = nil
    openTimeout?.cancel()
    openTimeout = nil
    callback(FlutterError(
      code: code,
      message: message ?? "原生播放失败",
      details: nil
    ))
  }

  private func resetItem() {
    openTimeout?.cancel()
    openTimeout = nil
    if let callback = openResult {
      openResult = nil
      callback(FlutterError(code: "cancelled", message: "播放源已替换", details: nil))
    }
    pendingSeekResult?(FlutterError(code: "seekCancelled", message: "播放源已替换", details: nil))
    pendingSeekResult = nil
    seekGeneration += 1
    itemObservers.forEach { $0.invalidate() }
    itemObservers.removeAll()
    notificationTokens.forEach(NotificationCenter.default.removeObserver)
    notificationTokens.removeAll()
    firstFrameSent = false
    lastBuffering = nil
    lastPlaying = nil
    frameOutput = nil
    currentAudioURL = nil
    generation = -1
    player.pause()
    player.replaceCurrentItem(with: nil)
  }

  // MARK: - Observation

  private func addObservers() {
    playerObservers = [
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
        guard let self else { return }
        DispatchQueue.main.async {
          self.updateBuffering()
          let playing = self.player.timeControlStatus == .playing
          if self.lastPlaying != playing {
            self.lastPlaying = playing
            self.send(["event": "playing", "value": playing, "generation": self.generation])
          }
        }
      },
    ]
    layerObserver = playerLayer.observe(\.isReadyForDisplay, options: [.new, .initial]) {
      [weak self] layer, _ in
      guard let self, layer.isReadyForDisplay else { return }
      DispatchQueue.main.async { self.markFirstFrame() }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
      queue: .main
    ) { [weak self] _ in
      self?.sendSample()
    }
    let center = NotificationCenter.default
    notificationTokens.append(center.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let item = notification.object as? AVPlayerItem,
            item === self.player.currentItem else { return }
      self.send([
        "event": "ended",
        "generation": self.generation,
        "positionMs": self.currentMilliseconds(),
      ])
    })
    notificationTokens.append(center.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let item = notification.object as? AVPlayerItem,
            item === self.player.currentItem else { return }
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
      self.sendFailure(code: self.errorCode(error))
    })
    notificationTokens.append(center.addObserver(
      forName: .AVPlayerItemNewErrorLogEntry,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let item = notification.object as? AVPlayerItem,
            item === self.player.currentItem else { return }
      let event = item.errorLog()?.events.last
      let status = event?.errorStatusCode ?? 0
      // AVFoundation records transient HLS segment retries here. Only surface
      // real HTTP failures; fatal pipeline errors arrive separately.
      guard status >= 400 else { return }
      self.send([
        "event": "networkError",
        "generation": self.generation,
        "httpStatus": status,
        "positionMs": self.currentMilliseconds(),
      ])
    })
    notificationTokens.append(center.addObserver(
      forName: .AVPlayerItemPlaybackStalled,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.setBuffering(true)
    })
    notificationTokens.append(center.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
      else { return }
      self.player.pause()
    })
  }

  private func markFirstFrame() {
    guard !firstFrameSent, generation >= 0 else { return }
    firstFrameSent = true
    send(["event": "firstFrame", "generation": generation])
  }

  private func updateBuffering() {
    let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    setBuffering(waiting)
  }

  private func setBuffering(_ value: Bool) {
    guard lastBuffering != value else { return }
    lastBuffering = value
    send(["event": "buffering", "value": value, "generation": generation])
  }

  private func sendSample() {
    guard generation >= 0, sink != nil else { return }
    let (width, height) = dimensions()
    send([
      "event": "sample",
      "generation": generation,
      "positionMs": currentMilliseconds(),
      "durationMs": safeMilliseconds(validSeconds(player.currentItem?.duration)),
      "bufferedMs": safeMilliseconds(bufferedSeconds()),
      "width": width,
      "height": height,
    ])
  }

  private func sendFailure(code: String) {
    send(["event": "failure", "kind": code, "generation": generation])
  }

  private func send(_ event: [String: Any]) {
    guard let sink else { return }
    DispatchQueue.main.async {
      sink(event)
    }
  }

  // MARK: - Helpers

  private func applyAudioGain() {
    guard let item = player.currentItem else { return }
    guard storedGainDb != 0 else {
      item.audioMix = nil
      return
    }
    guard let track = item.asset.tracks(withMediaType: .audio).first else { return }
    let linear = min(max(pow(10, storedGainDb / 20), 0), 1)
    let parameters = AVMutableAudioMixInputParameters(track: track)
    parameters.setVolume(Float(linear), at: .zero)
    let mix = AVMutableAudioMix()
    mix.inputParameters = [parameters]
    item.audioMix = mix
  }

  private func dimensions() -> (Int, Int) {
    if let size = player.currentItem?.presentationSize,
       size.width > 0, size.height > 0 {
      return (Int(size.width.rounded()), Int(size.height.rounded()))
    }
    guard let track = player.currentItem?.asset.tracks(withMediaType: .video).first
    else { return (0, 0) }
    let transformed = track.naturalSize.applying(track.preferredTransform)
    let width = abs(transformed.width)
    let height = abs(transformed.height)
    guard width > 0, height > 0 else { return (0, 0) }
    return (Int(width.rounded()), Int(height.rounded()))
  }

  private func bufferedSeconds() -> Double {
    guard let item = player.currentItem else { return 0 }
    return item.loadedTimeRanges.compactMap { value -> Double? in
      let range = value.timeRangeValue
      let end = CMTimeGetSeconds(range.end)
      return end.isFinite ? end : nil
    }.max() ?? 0
  }

  private func validSeconds(_ time: CMTime?) -> Double {
    guard let time else { return 0 }
    guard time.isNumeric else { return 0 }
    let value = CMTimeGetSeconds(time)
    return value.isFinite && value > 0 ? value : 0
  }

  private func codecName(_ track: AVAssetTrack) -> String? {
    guard let raw = track.formatDescriptions.first else { return nil }
    let format = raw as! CMFormatDescription
    let code = CMFormatDescriptionGetMediaSubType(format)
    let bytes: [UInt8] = [
      UInt8((code >> 24) & 0xff),
      UInt8((code >> 16) & 0xff),
      UInt8((code >> 8) & 0xff),
      UInt8(code & 0xff),
    ]
    guard let raw = String(bytes: bytes, encoding: .ascii)?.lowercased() else {
      return nil
    }
    switch raw {
    case "hvc1", "hev1": return "hevc"
    case "avc1", "avc3": return "h264"
    case "dvh1", "dvhe": return "dolbyvision"
    case "av01": return "av1"
    case "ec-3": return "eac3"
    case "ac-3": return "ac3"
    case "mp4a": return "aac"
    default: return raw
    }
  }

  private func audioDescription(_ track: AVAssetTrack) -> (channels: Int, sampleRate: Int)? {
    guard let raw = track.formatDescriptions.first else { return nil }
    let format = raw as! CMAudioFormatDescription
    guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)
    else { return nil }
    return (
      Int(description.pointee.mChannelsPerFrame),
      Int(description.pointee.mSampleRate)
    )
  }

  private func stringExtension(
    _ format: CMFormatDescription,
    _ key: CFString
  ) -> String? {
    CMFormatDescriptionGetExtension(format, extensionKey: key) as? String
  }

  private func errorCode(_ error: Error?) -> String {
    guard let error = error as NSError? else { return "nativePlayback" }
    if error.domain == NSURLErrorDomain {
      switch error.code {
      case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
           NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost:
        return "networkRead"
      default:
        return "networkRead"
      }
    }
    if error.domain == AVFoundationErrorDomain {
      switch error.code {
      case AVError.Code.fileFormatNotRecognized.rawValue,
           AVError.Code.decoderNotFound.rawValue:
        return "invalidSource"
      default:
        return "nativePlayback"
      }
    }
    return "nativePlayback"
  }
}

extension ApplePlayerSession: FlutterStreamHandler {
  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    attach(eventSink: events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    detachEventSink()
    return nil
  }
}
