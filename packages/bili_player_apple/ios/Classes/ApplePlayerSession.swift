import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import UIKit

/// One source generation backed by AVPlayer. Video and external DASH audio use
/// two players so each byte-range streams independently instead of being
/// flattened into an AVMutableComposition, which stalls remote playback.
final class ApplePlayerSession: NSObject {
  let playerId: Int
  let player = AVPlayer()
  private(set) var audioPlayer: AVPlayer?
  let playerLayer: AVPlayerLayer

  private weak var host: ApplePlayerHost?
  private var generation: Int = -1
  private var sink: FlutterEventSink?
  private var itemObservers: [NSKeyValueObservation] = []
  private var audioItemObservers: [NSKeyValueObservation] = []
  private var playerObservers: [NSKeyValueObservation] = []
  private var audioPlayerObservers: [NSKeyValueObservation] = []
  private var layerObserver: NSKeyValueObservation?
  private var notificationTokens: [NSObjectProtocol] = []
  private var audioNotificationTokens: [NSObjectProtocol] = []
  private var timeObserver: Any?
  private var openTimeout: DispatchWorkItem?
  private var openResult: FlutterResult?
  private var pendingSeekResult: FlutterResult?
  private var seekGeneration = 0
  private var desiredRate: Float = 1
  private var storedGainDb: Double = 0
  private var volumeLevel: Float = 1
  private var muted = false
  private var sourceKind = "progressive"
  private var externalAudio = false
  private var audioOnly = false
  private var audioReady = false
  private var openCompleted = false
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
    configureAudioSession()
    configurePlayer(player)
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
    let muted = args["muted"] as? Bool ?? false
    let audioOnly = args["audioOnly"] as? Bool ?? false
    let startPositionMs = args["startPositionMs"] as? Int ?? 0
    let rate = args["rate"] as? Double ?? 1
    let volume = args["volume"] as? Double ?? 1
    let gainDb = args["gainDb"] as? Double ?? 0
    let timeoutMs = (args["timeoutMs"] as? NSNumber)?.doubleValue ?? 35000

    resetItem()
    self.generation = generation
    self.openResult = result
    self.muted = muted
    self.sourceKind = kind
    self.audioOnly = audioOnly
    self.externalAudio = audioURL != nil
    self.storedGainDb = gainDb
    self.desiredRate = Float(max(rate, 0.1))
    self.volumeLevel = Float(min(max(volume, 0), 1))
    self.currentAudioURL = audioURL
    self.audioReady = false
    self.openCompleted = false

    let videoMime = audioOnly ? "audio/mp4" : "video/mp4"
    let videoAsset = makeAsset(videoURL, headers: headers, mime: videoMime)
    let videoItem = AVPlayerItem(asset: videoAsset)
    configureItem(videoItem)
    observeVideoItem(videoItem)

    player.isMuted = externalAudio || muted
    player.volume = externalAudio ? 0 : volumeLevel
    player.replaceCurrentItem(with: videoItem)
    if startPositionMs > 0 {
      seekPlayers(toSeconds: Double(startPositionMs) / 1000, tolerance: 0.25)
    }

    if let audioURL {
      let audioAsset = makeAsset(audioURL, headers: headers, mime: "audio/mp4")
      let audioItem = AVPlayerItem(asset: audioAsset)
      configureItem(audioItem)
      observeAudioItem(audioItem)
      let audio = ensureAudioPlayer()
      audio.isMuted = muted
      audio.volume = volumeLevel
      audio.replaceCurrentItem(with: audioItem)
      applyAudioGain()
    }

    let work = DispatchWorkItem { [weak self] in
      self?.failOpen(code: "nativePlayback", message: "打开播放源超时")
    }
    openTimeout = work
    let effectiveTimeout = kind == "manifest" ? min(timeoutMs, 15000) : timeoutMs
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(effectiveTimeout / 1000, 1),
      execute: work
    )

    if videoItem.status == .readyToPlay {
      finishOpen(item: videoItem)
    } else if videoItem.status == .failed {
      failOpen(code: errorCode(videoItem.error), message: videoItem.error?.localizedDescription)
    }
  }

  func play(rate: Double) {
    desiredRate = Float(max(rate, 0.1))
    player.play()
    player.rate = desiredRate
    guard externalAudio, let audio = audioPlayer else { return }
    if audio.currentItem?.status == .readyToPlay {
      alignAudio(to: player.currentTime().seconds)
    }
    audio.play()
    audio.rate = desiredRate
  }

  func pause() {
    player.pause()
    audioPlayer?.pause()
  }

  func setRate(_ rate: Double) {
    desiredRate = Float(max(rate, 0.1))
    if player.timeControlStatus == .playing || player.rate > 0 {
      player.rate = desiredRate
    }
    if let audio = audioPlayer,
       audio.timeControlStatus == .playing || audio.rate > 0 {
      audio.rate = desiredRate
    }
  }

  func setVolume(_ volume: Double) {
    volumeLevel = Float(min(max(volume, 0), 1))
    if externalAudio, let audio = audioPlayer {
      audio.volume = volumeLevel
      player.volume = 0
    } else {
      player.volume = volumeLevel
    }
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
      result(FlutterError(code: "nativePlayback", message: "播放器未就绪", details: nil))
      return
    }
    cancelSeek()
    let duration = validSeconds(item.duration)
    var seconds = Double(value) / 1000
    if duration > 0 {
      seconds = min(max(seconds, 0), duration)
    }
    let target = CMTime(seconds: seconds, preferredTimescale: 600)
    let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
    seekGeneration += 1
    let token = seekGeneration
    pendingSeekResult = result

    // The video seek owns the response so dragging stays responsive; audio is
    // seeked in parallel and the drift corrector re-aligns it moments later.
    player.seek(
      to: target,
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    ) { _ in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.seekGeneration == token else { return }
        let callback = self.pendingSeekResult
        self.pendingSeekResult = nil
        callback?(seconds)
      }
    }
    if externalAudio,
       let audio = audioPlayer,
       audio.currentItem?.status == .readyToPlay {
      audio.seek(
        to: target,
        toleranceBefore: tolerance,
        toleranceAfter: tolerance,
        completionHandler: { _ in }
      )
    }
  }

  func cancelSeek() {
    seekGeneration += 1
    player.currentItem?.cancelPendingSeeks()
    audioPlayer?.currentItem?.cancelPendingSeeks()
    if let pending = pendingSeekResult {
      pendingSeekResult = nil
      pending(FlutterError(code: "seekCancelled", message: "跳转已取消", details: nil))
    }
  }

  func interrupt() {
    pause()
    cancelSeek()
  }

  func reset() {
    resetItem()
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

  func inspect() -> [String: Any] {
    let videoItem = player.currentItem
    let audioItem = externalAudio ? audioPlayer?.currentItem : videoItem
    let position = currentMilliseconds()
    let duration = validSeconds(videoItem?.duration)
    let buffered = bufferedSeconds()
    let (width, height) = dimensions()
    let videoTrack = audioOnly ? nil : videoItem?.asset.tracks(withMediaType: .video).first
    let audioTrack = audioItem?.asset.tracks(withMediaType: .audio).first
    let accessLog = videoItem?.accessLog()?.events.last
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
      "volume": Double(volumeLevel),
      "isMuted": muted,
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
    if let bitrate = audioTrack?.estimatedDataRate, bitrate > 0 {
      info["audioBitrate"] = Double(bitrate) / 1000
      info["audioNominalBitrate"] = Double(bitrate) / 1000
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

  // MARK: - Item setup

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [])
  }

  private func configurePlayer(_ player: AVPlayer) {    player.actionAtItemEnd = .pause
    // Start as soon as the first range is playable; buffering is surfaced to
    // the UI so the user never waits for a large forward buffer to fill.
    player.automaticallyWaitsToMinimizeStalling = false
    if #available(iOS 13.0, *) {
      player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }
  }

  private func configureItem(_ item: AVPlayerItem) {
    item.audioTimePitchAlgorithm = .timeDomain
    item.preferredForwardBufferDuration = 0
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
      // is unavailable, so use the widely deployed asset option.
      options["AVURLAssetHTTPHeaderFieldsKey"] = headers
    }
    // Bilibili serves DASH tracks as `.m4s`, which AVFoundation does not map
    // to a container on its own. The out-of-band MIME option uses the same
    // string value as the AVFoundation constant, which is not exposed to Swift
    // on iOS.
    let ext = url.pathExtension.lowercased()
    if ext == "m4s" || ext.isEmpty {
      options["AVURLAssetOutOfBandMIMETypeKey"] = mime
    }
    return AVURLAsset(url: url, options: options)
  }

  private func ensureAudioPlayer() -> AVPlayer {
    if let audioPlayer { return audioPlayer }
    let audio = AVPlayer()
    configurePlayer(audio)
    audioPlayer = audio
    audioPlayerObservers = [
      audio.observe(\.timeControlStatus, options: [.new]) { _, _ in },
    ]
    return audio
  }

  private func observeVideoItem(_ item: AVPlayerItem) {
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
      item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
        guard let self else { return }
        DispatchQueue.main.async { self.updateBuffering() }
      },
      item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
        guard let self else { return }
        DispatchQueue.main.async { self.sendSample() }
      },
    ]
  }

  private func observeAudioItem(_ item: AVPlayerItem) {
    audioItemObservers.forEach { $0.invalidate() }
    audioItemObservers = [
      item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
        guard let self else { return }
        DispatchQueue.main.async {
          if item.status == .readyToPlay {
            self.audioDidBecomeReady()
          } else if item.status == .failed {
            self.sendFailure(code: self.errorCode(item.error))
          }
        }
      },
    ]
  }

  private func audioDidBecomeReady() {
    audioReady = true
    applyAudioGain()
    guard let audio = audioPlayer else { return }
    if player.timeControlStatus == .playing || player.rate > 0 {
      alignAudio(to: player.currentTime().seconds)
      audio.play()
      audio.rate = desiredRate
    }
  }

  private func finishOpen(item: AVPlayerItem) {
    guard openResult != nil, !openCompleted else { return }
    openCompleted = true
    let (width, height) = dimensions()
    let duration = validSeconds(item.duration)
    let audioTracks = item.asset.tracks(withMediaType: .audio)
    // Tracks can lag behind readyToPlay for HLS. The source contract already
    // says whether video/audio is expected, so do not reject a valid stream.
    let hasVideo = !audioOnly
    let hasAudio = audioOnly || externalAudio || !audioTracks.isEmpty
      || sourceKind == "manifest"
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
    audioItemObservers.forEach { $0.invalidate() }
    audioItemObservers.removeAll()
    notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    notificationTokens.removeAll()
    audioNotificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    audioNotificationTokens.removeAll()
    externalAudio = false
    audioOnly = false
    sourceKind = "progressive"
    audioReady = false
    openCompleted = false
    firstFrameSent = false
    lastBuffering = nil
    lastPlaying = nil
    frameOutput = nil
    currentAudioURL = nil
    generation = -1
    player.pause()
    player.replaceCurrentItem(with: nil)
    audioPlayer?.pause()
    audioPlayer?.replaceCurrentItem(with: nil)
  }

  // MARK: - Observation

  private func addObservers() {
    playerObservers = [
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
        guard let self else { return }
        DispatchQueue.main.async {
          self.updateBuffering()
          let playing = self.player.timeControlStatus == .playing
          if !playing {
            // Keep the audio clock with the video clock: never let sound run
            // while the picture is waiting for data.
            self.audioPlayer?.pause()
          }
          if self.lastPlaying != playing {
            self.lastPlaying = playing
            self.send(["event": "playing", "value": playing, "generation": self.generation])
          }
          if playing { self.syncAudio() }
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
      guard let self else { return }
      self.sendSample()
      self.syncAudio()
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
      self.audioPlayer?.pause()
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
      self.pause()
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
    if Thread.isMainThread {
      sink(event)
    } else {
      DispatchQueue.main.async { sink(event) }
    }
  }

  // MARK: - Audio/video synchronisation

  private func seekPlayers(toSeconds seconds: Double, tolerance: Double) {
    guard seconds > 0 else { return }
    let target = CMTime(seconds: seconds, preferredTimescale: 600)
    let tol = CMTime(seconds: tolerance, preferredTimescale: 600)
    player.seek(
      to: target,
      toleranceBefore: tol,
      toleranceAfter: tol,
      completionHandler: { _ in }
    )
    if externalAudio,
       let audio = audioPlayer,
       audio.currentItem?.status == .readyToPlay {
      audio.seek(
        to: target,
        toleranceBefore: tol,
        toleranceAfter: tol,
        completionHandler: { _ in }
      )
    }
  }

  /// Starts the external audio player at the video clock position.
  private func alignAudio(to videoSeconds: Double) {
    guard externalAudio,
          let audio = audioPlayer,
          audio.currentItem?.status == .readyToPlay,
          videoSeconds.isFinite,
          videoSeconds > 0 else { return }
    let audioSeconds = audio.currentTime().seconds
    guard !audioSeconds.isFinite || abs(audioSeconds - videoSeconds) > 0.12 else { return }
    audio.seek(
      to: CMTime(seconds: videoSeconds, preferredTimescale: 600),
      toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
      toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600),
      completionHandler: { _ in }
    )
  }

  /// The video player is the clock. Audio is nudged by a few percent or seeks
  /// only when drift becomes noticeable.
  private func syncAudio() {
    guard externalAudio,
          let audio = audioPlayer,
          audioReady,
          audio.currentItem?.status == .readyToPlay else { return }
    let videoStatus = player.timeControlStatus
    if videoStatus != .playing {
      if audio.rate != 0 { audio.pause() }
      return
    }
    if audio.timeControlStatus != .playing {
      if audio.timeControlStatus == .waitingToPlayAtSpecifiedRate {
        // Do not seek a stream that is still filling its first buffer.
        audio.play()
        audio.rate = desiredRate
        return
      }
      alignAudio(to: player.currentTime().seconds)
      audio.play()
      audio.rate = desiredRate
      return
    }
    let videoSeconds = player.currentTime().seconds
    let audioSeconds = audio.currentTime().seconds
    guard videoSeconds.isFinite, audioSeconds.isFinite else { return }
    let drift = videoSeconds - audioSeconds
    if abs(drift) > 0.6 {
      alignAudio(to: videoSeconds)
      audio.rate = desiredRate
    } else if abs(drift) > 0.08 {
      audio.rate = desiredRate + (drift > 0 ? 0.02 : -0.02)
    } else if abs(audio.rate - desiredRate) > 0.001 {
      audio.rate = desiredRate
    }
  }

  // MARK: - Helpers

  private func applyAudioGain() {
    let target = externalAudio ? audioPlayer?.currentItem : player.currentItem
    guard let item = target else { return }
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
    var end = bufferedEnd(player.currentItem)
    if externalAudio {
      let audioEnd = bufferedEnd(audioPlayer?.currentItem)
      if audioEnd > 0 {
        end = end > 0 ? min(end, audioEnd) : audioEnd
      }
    }
    return end
  }

  private func bufferedEnd(_ item: AVPlayerItem?) -> Double {
    guard let item else { return 0 }
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
      return "networkRead"
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
    audioPlayerObservers.forEach { $0.invalidate() }
    audioPlayerObservers.removeAll()
    layerObserver?.invalidate()
    layerObserver = nil
    audioPlayer = nil
    playerLayer.player = nil
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
