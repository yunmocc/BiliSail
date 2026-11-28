import 'dart:async';

import 'package:bili_player/bili_player.dart';

import 'fvp_native_player.dart';
import 'fvp_video_output.dart';

/// MDK commands and observations for the in-process native player.
final class FvpBackend implements PlaybackBackend {
  FvpBackend({this.createPlayer, this.onStage});

  final Future<FvpPlayerPort> Function()? createPlayer;
  final void Function(NativeReadinessStage)? onStage;
  final _output = FvpVideoOutput();
  final _events = StreamController<BackendEvent>.broadcast(sync: true);
  Future<FvpPlayerPort>? _creating;
  FvpPlayerPort? _player;
  StreamSubscription<FvpNativeStatus>? _subscription;
  Timer? _sampling;
  Future<void>? _disposal;
  PlaybackOperation? _preparation;
  bool _disposed = false;
  bool _nativeEnded = false;
  bool _live = false;
  double _volume = 0, _gain = 0;
  int _durationMilliseconds = 0;

  @override
  VideoOutput get videoOutput => _output;
  @override
  Stream<BackendEvent> get events => _events.stream;
  @override
  Duration get seekTimeout => const Duration(seconds: 15);

  @override
  Duration? get buffered {
    final player = _player;
    if (_disposed || player == null) return null;
    final milliseconds =
        player.positionMilliseconds + player.bufferedMilliseconds;
    return Duration(milliseconds: milliseconds.clamp(0, 1 << 53));
  }

  @override
  Future<PreparedTracks> prepare(
    ValidatedSource plan,
    PlaybackOperation operation, {
    Future<void> Function()? onLiveLoaded,
  }) async {
    _live = plan.live;
    _preparation = operation;
    try {
      final creating = _creating =
          (createPlayer?.call() ?? createFvpNativePlayer()).then((player) {
            _player = player;
            return player;
          });
      final player = await operation.wait(creating);
      _creating = null;
      _subscription = player.statuses.listen(_onStatus);
      onStage?.call(NativeReadinessStage.tracks);
      operation.check();
      final info = await operation.wait(
        player.prepare(
          plan.media,
          plan.audio,
          plan.options,
          silent: plan.silent,
          isLive: plan.live,
        ),
      );
      _gain = plan.options.audioGainDb;
      _dimensions = info.dimensions;
      _durationMilliseconds = info.duration.inMilliseconds;
      await operation.wait(setVolume(plan.options.volume));
      if (plan.live) {
        // Live starts before confirmVideo, so register the texture first. The
        // first frame otherwise has no destination and is never observed.
        if (!plan.audioOnly && info.hasVideo) {
          final texture = await operation.wait(player.createTexture());
          if (texture < 0) throw StateError('Video output unavailable');
        }
        final live = onLiveLoaded;
        if (live != null) await operation.wait(live());
      }
      _startSampling();
      return PreparedTracks(
        hasVideo: info.hasVideo,
        hasAudio: info.hasAudio,
        externalAudioSelected: plan.audio != null && info.hasAudio,
        duration: info.duration,
        position: plan.options.startPosition,
        dimensions: info.dimensions,
      );
    } on SourceSuperseded {
      rethrow;
    } on PlayerFailure {
      rethrow;
    } on Object {
      if (_disposed) rethrow;
      throw PlayerFailure(
        PlayerFailureKind.nativePlayback,
        '播放器初始化失败，请退出播放页后重新打开',
        operation.generation,
      );
    }
  }

  void _onStatus(FvpNativeStatus status) {
    if (_disposed) return;
    if (status == FvpNativeStatus.ended) _nativeEnded = true;
    _events.add(switch (status) {
      FvpNativeStatus.buffering => const BackendEvent(
        BackendEventKind.buffering,
        value: true,
      ),
      FvpNativeStatus.buffered => const BackendEvent(
        BackendEventKind.buffering,
        value: false,
      ),
      FvpNativeStatus.ended => BackendEvent(
        BackendEventKind.ended,
        position: Duration(
          milliseconds: _player?.positionMilliseconds.clamp(0, 1 << 53) ?? 0,
        ),
      ),
      FvpNativeStatus.invalid || FvpNativeStatus.audioEnded =>
        const BackendEvent(BackendEventKind.failure),
    });
  }

  void _startSampling() {
    _sampling ??= Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _emitSample(),
    );
  }

  void _emitSample() {
    final player = _player;
    if (_disposed || player == null) return;
    _events.add(
      BackendEvent(
        BackendEventKind.sample,
        position: Duration(
          milliseconds: player.positionMilliseconds.clamp(0, 1 << 53),
        ),
        duration: _live || _durationMilliseconds <= 0
            ? Duration.zero
            : Duration(milliseconds: _durationMilliseconds),
        buffered: buffered,
        dimensions: _dimensions,
      ),
    );
  }

  VideoDimensions? _dimensions;

  @override
  Future<VideoDimensions?> confirmVideo(PlaybackOperation operation) async {
    final player = _player!;
    onStage?.call(NativeReadinessStage.videoOutput);
    operation.check();
    final texture = await operation.wait(player.createTexture());
    if (texture < 0) throw StateError('Video output unavailable');
    // The prepared scalar dimensions are owned by the player, not the probe.
    final dimensions = _dimensions;
    if (dimensions == null) throw StateError('Video did not decode');
    _output.bind(texture, dimensions);
    onStage?.call(NativeReadinessStage.videoDecode);
    operation.check();
    if (!await operation.wait(player.confirmVideoFrame())) {
      throw StateError('Video did not render');
    }
    return dimensions;
  }

  @override
  Future<void> confirmAudio(PlaybackOperation operation) async {
    onStage?.call(NativeReadinessStage.externalAudio);
    operation.check();
    if (!await operation.wait(_player!.confirmAudio())) {
      throw StateError('Audio did not decode');
    }
  }

  @override
  Future<void> confirmPresentation(PlaybackOperation operation) =>
      operation.wait(_output.confirmFrame());
  @override
  Future<void> play() async => _player?.play();

  @override
  Future<bool> pauseAndWait() async {
    final player = _player;
    if (player is FvpPauseConfirmationPort) {
      return (player as FvpPauseConfirmationPort).pauseAndConfirm();
    }
    await player?.pauseAndWait();
    // MDK keeps EOF stopped for replay; its pause request cannot acknowledge
    // that a surviving external audio pipe has stopped too.
    return !_nativeEnded;
  }

  @override
  Future<void> setRate(double rate) async => _player?.setRate(rate);

  Future<void> _applyVolume() async => _player?.setVolume(_volume, _gain);

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    await _applyVolume();
  }

  @override
  Future<void> setGainDb(double gainDb) async {
    _gain = gainDb;
    await _applyVolume();
  }

  @override
  Future<Duration> seekTo(Duration target, PlaybackOperation operation) async {
    final position = await operation.wait(_player!.seek(target));
    if (position < 0) {
      throw PlayerFailure(
        PlayerFailureKind.nativePlayback,
        '定位失败，请重试',
        operation.generation,
      );
    }
    _nativeEnded = false;
    return Duration(milliseconds: position);
  }

  @override
  Future<void> cancelSeek() async => await _player?.cancelSeek();
  @override
  void interrupt() {
    _preparation?.cancel();
    _player?.interrupt();
  }

  @override
  Future<PlayerPlaybackInformation?> inspectPlaybackInformation(
    int generation,
  ) async {
    final player = _player;
    if (player is FvpInformationPort) {
      return (player as FvpInformationPort).inspectPlaybackInformation(
        generation: generation,
        audioGainDb: _gain,
      );
    }
    return PlayerPlaybackInformation(
      generation: generation,
      backend: 'fvp / MDK',
      audioGainDb: _gain,
    );
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    interrupt();
    _disposed = true;
    _sampling?.cancel();
    _sampling = null;
    _output.clear();
    await _subscription?.cancel();
    _subscription = null;
    final creating = _creating;
    if (creating != null) {
      try {
        await creating;
      } on Object {
        /* No native resource was returned. */
      }
    }
    if (_player case final player?) {
      await player.dispose().timeout(const Duration(seconds: 10));
    }
    _player = null;
    _output.dispose();
    await _events.close();
  }
}
