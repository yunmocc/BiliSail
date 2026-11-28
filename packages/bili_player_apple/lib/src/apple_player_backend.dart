import 'dart:async';

import 'package:bili_player/bili_player.dart';
import 'package:flutter/services.dart';

import 'apple_player_channel.dart';
import 'apple_player_source.dart';
import 'apple_player_video_output.dart';

/// AVPlayer implementation of the package-private playback contract.
final class ApplePlayerBackend
    implements PlaybackBackend, ReusablePlaybackBackend {
  factory ApplePlayerBackend({
    required PlaybackSnapshot Function() snapshot,
    void Function(PlayerDiagnosticEvent)? onDiagnostic,
  }) {
    final playerId = _nextPlayerId++;
    final output = ApplePlayerVideoOutput(playerId: playerId);
    final channel = ApplePlayerChannel(playerId);
    output.bindChannel(channel);
    return ApplePlayerBackend._(
      playerId,
      channel,
      videoOutput: output,
      snapshot: snapshot,
      onDiagnostic: onDiagnostic,
    );
  }

  ApplePlayerBackend._(
    this.playerId,
    this._channel, {
    required this.videoOutput,
    required this.snapshot,
    required this.onDiagnostic,
  }) {
    _initial = _initialize();
  }

  static int _nextPlayerId = 1;

  final int playerId;

  @override
  final ApplePlayerVideoOutput videoOutput;
  final PlaybackSnapshot Function() snapshot;
  final void Function(PlayerDiagnosticEvent)? onDiagnostic;
  final ApplePlayerChannel _channel;
  final _events = StreamController<BackendEvent>.broadcast(sync: true);
  late final Future<void> _initial;
  StreamSubscription<Map<String, Object?>>? _subscription;
  Future<void>? _disposal;
  bool _disposed = false;
  int _generation = 0;
  VideoDimensions? _dimensions;
  bool _hasVideo = false;
  bool _hasAudio = false;
  Duration _duration = Duration.zero;
  Duration? _buffered;
  Completer<void>? _firstFrame;
  bool _framePresented = false;
  double _rate = 1;
  double _gainDb = 0;

  @override
  Stream<BackendEvent> get events => _events.stream;

  @override
  Duration get seekTimeout => const Duration(seconds: 15);

  @override
  Duration? get buffered => _buffered;

  Future<void> _initialize() async {
    await _channel.create();
    _subscription = _channel.events.listen(
      _onEvent,
      onError: (Object error, StackTrace _) => _onStreamError(error),
    );
  }

  void _emit(BackendEvent event) {
    if (!_disposed && !_events.isClosed) _events.add(event);
  }

  void _diagnose(PlayerDiagnosticKind kind, {PlayerFailureKind? failureKind}) {
    onDiagnostic?.call(
      PlayerDiagnosticEvent(
        kind: kind,
        snapshot: snapshot(),
        failureKind: failureKind,
      ),
    );
  }

  @override
  Future<PreparedTracks> prepare(
    ValidatedSource plan,
    PlaybackOperation operation, {
    Future<void> Function()? onLiveLoaded,
  }) async {
    if (_disposed) {
      throw PlayerFailure(
        PlayerFailureKind.disposed,
        '播放器已释放',
        operation.generation,
      );
    }
    validateApplePlayerSource(plan, operation.generation);
    try {
      await operation.wait(_initial);
      _generation = operation.generation;
      _dimensions = null;
      _hasVideo = false;
      _hasAudio = false;
      _duration = Duration.zero;
      _buffered = null;
      _framePresented = false;
      _firstFrame = Completer<void>();
      videoOutput.markSourceChanged();
      _rate = plan.options.rate;
      _gainDb = plan.options.audioGainDb;
      final payload = applePlayerOpenPayload(
        playerId: playerId,
        generation: operation.generation,
        plan: plan,
      );
      final result = await operation.wait(
        _channel.open(payload, timeout: operation.remaining),
      );
      _duration = Duration(
        milliseconds: (result['durationMs'] as num?)?.round() ?? 0,
      );
      _hasVideo = result['hasVideo'] == true;
      _hasAudio = result['hasAudio'] == true;
      final width = (result['width'] as num?)?.round() ?? 0;
      final height = (result['height'] as num?)?.round() ?? 0;
      _dimensions = width > 0 && height > 0
          ? VideoDimensions(width, height)
          : null;
      if (plan.live) await onLiveLoaded?.call();
      operation.check();
      return PreparedTracks(
        hasVideo: _hasVideo,
        hasAudio: _hasAudio,
        externalAudioSelected: result['externalAudio'] == true,
        duration: _duration,
        position: plan.options.startPosition,
        dimensions: _dimensions,
      );
    } on PlayerFailure {
      rethrow;
    } on TimeoutException {
      throw PlayerFailure(
        PlayerFailureKind.nativePlayback,
        '打开播放源超时',
        operation.generation,
      );
    } on PlatformException catch (error) {
      throw PlayerFailure(
        _kindFromCode(error.code),
        error.message ?? '原生播放失败',
        operation.generation,
      );
    }
  }

  @override
  Future<VideoDimensions?> confirmVideo(PlaybackOperation operation) async {
    operation.check();
    return _dimensions;
  }

  @override
  Future<void> confirmAudio(PlaybackOperation operation) async {
    operation.check();
    if (!_hasAudio) {
      throw PlayerFailure(
        PlayerFailureKind.invalidSource,
        '未检测到音频轨道',
        operation.generation,
      );
    }
  }

  @override
  Future<void> confirmPresentation(PlaybackOperation operation) async {
    operation.check();
    if (!_hasVideo || !videoOutput.isAttached) return;
    final firstFrame = _firstFrame;
    if (firstFrame == null || _framePresented) return;
    try {
      await operation.wait(
        firstFrame.future,
        timeout: const Duration(seconds: 3),
      );
    } on TimeoutException {
      // A paused or offscreen item may not produce a frame. Dimensions are
      // already authoritative; never fail an otherwise valid open for this.
    }
  }

  @override
  Future<void> play() async {
    if (_disposed) return;
    await _channel.play(rate: _rate);
  }

  @override
  Future<bool> pauseAndWait() async {
    if (_disposed) return false;
    await _channel.pause();
    return true;
  }

  @override
  Future<void> setRate(double rate) async {
    if (_disposed) return;
    _rate = rate;
    await _channel.setRate(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (_disposed) return;
    await _channel.setVolume(volume / 100);
  }

  @override
  Future<void> setGainDb(double gainDb) async {
    if (_disposed) return;
    _gainDb = gainDb;
    await _channel.setGain(gainDb);
  }

  @override
  Future<Duration> seekTo(Duration target, PlaybackOperation operation) async {
    if (_disposed) {
      throw PlayerFailure(
        PlayerFailureKind.disposed,
        '播放器已释放',
        operation.generation,
      );
    }
    _buffered = null;
    try {
      return await operation.wait(
        _channel.seek(target, timeout: operation.remaining),
      );
    } on PlatformException catch (error) {
      if (error.code == 'seekCancelled') {
        throw const SourceSuperseded();
      }
      throw PlayerFailure(
        _kindFromCode(error.code),
        error.message ?? '定位失败',
        operation.generation,
      );
    }
  }

  @override
  Future<void> cancelSeek() async {
    if (_disposed) return;
    await _channel.cancelSeek();
  }

  @override
  void interrupt() {
    if (_disposed) return;
    unawaited(
      _channel.interrupt().catchError((Object _) {
        // Disposal remains the final barrier.
      }),
    );
  }

  @override
  Future<PlayerPlaybackInformation?> inspectPlaybackInformation(
    int generation,
  ) async {
    if (_disposed) return null;
    final Map<String, Object?> info;
    try {
      info = await _channel.inspect();
    } on Object {
      return null;
    }
    final position = Duration(
      milliseconds: (info['positionMs'] as num?)?.round() ?? 0,
    );
    final dimensions = _dimensions;
    final hasVideo = info['hasVideo'] == true;
    final hasAudio = info['hasAudio'] == true;
    return PlayerPlaybackInformation(
      generation: generation,
      backend: 'AVPlayer',
      diagnostics: PlayerDiagnostics(
        generation: generation,
        position: position,
        hasDecodedVideo: hasVideo,
        hasDecodedAudio: hasAudio,
        hasVideoOutput: videoOutput.isAttached,
        outputWidth: dimensions?.width,
        outputHeight: dimensions?.height,
        videoWidth: dimensions?.width,
        videoHeight: dimensions?.height,
        audioChannels: (info['audioChannels'] as num?)?.toInt(),
        audioSampleRate: (info['audioSampleRate'] as num?)?.toInt(),
        videoCodec: _safeString(info['videoCodec']),
        audioCodec: _safeString(info['audioCodec']),
      ),
      hardwareDecoder: hasVideo ? 'videotoolbox' : null,
      videoCodec: _safeString(info['videoCodec']),
      audioCodec: _safeString(info['audioCodec']),
      atmosSource: info['atmos'] == true,
      audioOutputFormat: _safeString(info['audioOutputFormat']),
      sourceFps: (info['nominalFrameRate'] as num?)?.toDouble(),
      outputFps: (info['nominalFrameRate'] as num?)?.toDouble(),
      videoBitrate: (info['videoBitrate'] as num?)?.toDouble(),
      audioBitrate: (info['audioBitrate'] as num?)?.toDouble(),
      videoNominalBitrate: (info['videoNominalBitrate'] as num?)?.toDouble(),
      audioNominalBitrate: (info['audioNominalBitrate'] as num?)?.toDouble(),
      pixelFormat: _safeString(info['pixelFormat']),
      colorPrimaries: _safeString(info['colorPrimaries']),
      transferFunction: _safeString(info['transferFunction']),
      colorMatrix: _safeString(info['colorMatrix']),
      videoOutput: 'AVPlayerLayer',
      audioOutput: 'AVPlayer',
      avSyncSeconds: (info['avSyncSeconds'] as num?)?.toDouble(),
      audioGainDb: _gainDb,
    );
  }

  @override
  bool canReuse(ValidatedSource plan) => !_disposed;

  @override
  Future<void> resetForNextSource(PlaybackOperation operation) async {
    if (_disposed) return;
    try {
      await operation.wait(_channel.reset());
    } on Object {
      // The next prepare will surface a native failure if the host is gone.
    }
    _generation = -1;
    _dimensions = null;
    _hasVideo = false;
    _hasAudio = false;
    _duration = Duration.zero;
    _buffered = null;
    _framePresented = false;
    _firstFrame = null;
    videoOutput.markSourceChanged();
  }

  @override
  Future<void> dispose() {
    final existing = _disposal;
    if (existing != null) return existing;
    return _disposal = _release();
  }

  Future<void> _release() async {
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel.dispose();
    } on Object {
      // The native host may already be gone during app teardown.
    }
    await _events.close();
    videoOutput.dispose();
  }

  void _onEvent(Map<String, Object?> event) {
    if (_disposed) return;
    final generation = (event['generation'] as num?)?.toInt();
    if (generation != null && generation != _generation) return;
    switch (event['event']) {
      case 'ready':
        _applyReady(event);
      case 'sample':
        _applySample(event);
      case 'buffering':
        _emit(
          BackendEvent(
            BackendEventKind.buffering,
            value: event['value'] == true,
          ),
        );
      case 'playing':
        _emit(
          BackendEvent(BackendEventKind.playing, value: event['value'] == true),
        );
      case 'firstFrame':
        _framePresented = true;
        videoOutput.markFrameReady();
        final firstFrame = _firstFrame;
        if (firstFrame != null && !firstFrame.isCompleted) {
          firstFrame.complete();
        }
      case 'ended':
        _emit(
          BackendEvent(
            BackendEventKind.ended,
            position: _durationOf(event, 'positionMs'),
          ),
        );
      case 'networkError':
        _diagnose(
          PlayerDiagnosticKind.nativeError,
          failureKind: PlayerFailureKind.networkRead,
        );
        _emit(
          BackendEvent(
            BackendEventKind.networkError,
            position: _durationOf(event, 'positionMs'),
          ),
        );
      case 'failure':
        final kind = _kindFromCode(_safeString(event['kind']));
        _diagnose(PlayerDiagnosticKind.failed, failureKind: kind);
        _emit(BackendEvent(BackendEventKind.failure, failureKind: kind));
    }
  }

  void _applyReady(Map<String, Object?> event) {
    _duration = _durationOf(event, 'durationMs') ?? _duration;
    final width = (event['width'] as num?)?.round() ?? 0;
    final height = (event['height'] as num?)?.round() ?? 0;
    if (width > 0 && height > 0) {
      _dimensions = VideoDimensions(width, height);
    }
    _hasVideo = event['hasVideo'] == true;
    _hasAudio = event['hasAudio'] == true;
    if (_framePresented) videoOutput.markFrameReady();
  }

  void _applySample(Map<String, Object?> event) {
    final position = _durationOf(event, 'positionMs');
    final duration = _durationOf(event, 'durationMs');
    final buffered = _durationOf(event, 'bufferedMs');
    if (duration != null && duration > Duration.zero) _duration = duration;
    if (buffered != null) _buffered = buffered;
    final width = (event['width'] as num?)?.round() ?? 0;
    final height = (event['height'] as num?)?.round() ?? 0;
    if (width > 0 && height > 0) {
      _dimensions = VideoDimensions(width, height);
    }
    _emit(
      BackendEvent(
        BackendEventKind.sample,
        position: position,
        duration: _duration,
        buffered: _buffered,
        dimensions: _dimensions,
      ),
    );
  }

  void _onStreamError(Object error) {
    if (_disposed) return;
    final kind = error is PlatformException
        ? _kindFromCode(error.code)
        : PlayerFailureKind.nativePlayback;
    _diagnose(PlayerDiagnosticKind.nativeError, failureKind: kind);
    _emit(BackendEvent(BackendEventKind.failure, failureKind: kind));
  }

  static Duration? _durationOf(Map<String, Object?> event, String key) {
    final value = event[key];
    return value is num ? Duration(milliseconds: value.round()) : null;
  }

  static String? _safeString(Object? value) {
    if (value is! String) return null;
    return RegExp(r'^[A-Za-z0-9._-]{1,32}$').hasMatch(value) ? value : null;
  }

  static PlayerFailureKind _kindFromCode(String? code) => switch (code) {
    'invalidSource' || 'unsupportedFormat' => PlayerFailureKind.invalidSource,
    'unsupportedHeaders' => PlayerFailureKind.unsupportedHeaders,
    'unsupportedVideoColor' => PlayerFailureKind.unsupportedVideoColor,
    'networkOpen' => PlayerFailureKind.networkOpen,
    'networkRead' => PlayerFailureKind.networkRead,
    'liveReadTerminated' => PlayerFailureKind.liveReadTerminated,
    'videoInterrupted' => PlayerFailureKind.videoInterrupted,
    'disposed' => PlayerFailureKind.disposed,
    _ => PlayerFailureKind.nativePlayback,
  };
}
