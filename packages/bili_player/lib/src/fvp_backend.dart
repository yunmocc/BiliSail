import 'dart:async';

import 'fvp_buffer.dart';
import 'fvp_lifecycle.dart';
import 'fvp_native_player.dart';
import 'fvp_video_output.dart';
import 'native_readiness.dart';
import 'player_diagnostics.dart';
import 'playback_backend.dart';
import 'player_contract.dart';
import 'player_playback_information.dart';
import 'validated_source.dart';
import 'video_output.dart';

/// MDK commands and observations for one iOS source.
///
/// This adapter is intentionally not reusable: every open allocates a new
/// native player and texture. The previous backend is released first; if
/// native teardown exceeds its deadline the handle is explicitly orphaned,
/// never reused, and the Flutter texture is unbound before the next open.
final class FvpBackend implements PlaybackBackend {
  FvpBackend({required this.createPlayer, this.onStage})
    : instanceId = FvpLifecycle.createBackend();

  final int instanceId;
  final Future<FvpPlayerPort> Function() createPlayer;
  final void Function(NativeReadinessStage)? onStage;
  final _output = FvpVideoOutput();
  final _bufferDisplay = FvpBufferDisplay();
  final _events = StreamController<BackendEvent>.broadcast(sync: true);
  Future<FvpPlayerPort>? _creating;
  FvpPlayerPort? _player;
  StreamSubscription<FvpNativeStatus>? _subscription;
  Timer? _sampler;
  Future<void>? _disposal;
  PlaybackOperation? _preparation;
  bool _disposed = false;
  bool _nativeEnded = false;
  bool _buffering = false;
  bool _networkError = false;
  bool _live = false;
  double _volume = 0, _gain = 0;
  int _generation = 0;
  VideoDimensions? _dimensions;

  bool _current(int generation) =>
      !_disposed && generation == _generation && _player != null;

  @override
  VideoOutput get videoOutput => _output;
  @override
  Stream<BackendEvent> get events => _events.stream;
  @override
  Duration get seekTimeout => const Duration(seconds: 15);

  Duration? _position() {
    final player = _player;
    if (player == null) return null;
    return Duration(
      milliseconds: player.positionMilliseconds.clamp(0, 1 << 53),
    );
  }

  @override
  Duration? get buffered {
    final player = _player;
    final position = _position();
    if (player == null || position == null || _disposed) return null;
    final ahead = player.bufferedMilliseconds.clamp(0, 1 << 53);
    // The shared engine distinguishes an open failure from a stalled read by
    // observing a zero endpoint. MDK's endpoint is media-absolute, so report
    // zero only for an explicit native network error with no packets.
    if (ahead == 0 && _networkError) return Duration.zero;
    final end = position + Duration(milliseconds: ahead);
    final duration = _duration();
    return duration > Duration.zero && end > duration ? duration : end;
  }

  Duration _duration() {
    final player = _player;
    if (player == null || _live) return Duration.zero;
    return Duration(
      milliseconds: player.durationMilliseconds.clamp(0, 1 << 53),
    );
  }

  void _emit(BackendEvent event) {
    if (_disposed || _events.isClosed) return;
    if (event.generation != null && event.generation != _generation) return;
    _events.add(event);
  }

  @override
  Future<PreparedTracks> preparePaused(
    ValidatedSource plan,
    PlaybackOperation operation,
  ) async {
    final generation = _generation = operation.generation;
    _preparation = operation;
    _bufferDisplay.reset();
    _nativeEnded = false;
    _buffering = false;
    _networkError = false;
    _live = plan.live;
    final options = plan.options;
    final sound = plan.audio;
    try {
      final creating = _creating = () async {
        final player = await createPlayer();
        if (_disposed || generation != _generation) {
          await player.dispose();
          throw const SourceSuperseded();
        }
        _player = player;
        return player;
      }();
      final player = await operation.wait(creating);
      _creating = null;
      if (!_current(generation)) throw const SourceSuperseded();
      _subscription = player.statuses.listen((status) {
        if (!_current(generation)) return;
        _status(status, generation);
      });
      onStage?.call(NativeReadinessStage.tracks);
      operation.check();
      final info = await operation.wait(
        player.prepare(
          plan.media,
          sound,
          options,
          silent: plan.silent,
          isLive: plan.live,
        ),
      );
      if (!_current(generation)) throw const SourceSuperseded();
      _gain = options.audioGainDb;
      _dimensions = info.dimensions;
      await operation.wait(setVolume(options.volume));
      if (!_current(generation)) throw const SourceSuperseded();
      _startSampling(generation);
      var position = options.startPosition;
      if (info.duration > Duration.zero && position > info.duration) {
        position = info.duration;
      }
      return PreparedTracks(
        hasVideo: info.hasVideo,
        hasAudio: info.hasAudio,
        externalAudioSelected: sound != null && info.hasAudio,
        duration: info.duration,
        position: position,
        dimensions: info.dimensions,
      );
    } on PlayerFailure {
      rethrow;
    } on StateError {
      if (_disposed || generation != _generation) {
        throw const SourceSuperseded();
      }
      throw PlayerFailure(
        PlayerFailureKind.nativePlayback,
        'fvp 无法准备此媒体源',
        generation,
      );
    }
  }

  void _status(FvpNativeStatus status, int generation) {
    if (!_current(generation)) return;
    final player = _player!;
    switch (status) {
      case FvpNativeStatus.buffering:
        _buffering = true;
      case FvpNativeStatus.buffered:
        _buffering = false;
      case FvpNativeStatus.ended:
        _nativeEnded = true;
        _emit(
          BackendEvent(
            BackendEventKind.ended,
            position: Duration(
              milliseconds: player.positionMilliseconds.clamp(0, 1 << 53),
            ),
            duration: _duration(),
            buffered: buffered,
            generation: generation,
          ),
        );
        return;
      case FvpNativeStatus.audioEnded:
        _emit(
          BackendEvent(
            BackendEventKind.failure,
            failureKind: PlayerFailureKind.videoInterrupted,
            generation: generation,
          ),
        );
        return;
      case FvpNativeStatus.networkError:
        _networkError = true;
        _emit(
          BackendEvent(BackendEventKind.networkError, generation: generation),
        );
        return;
      case FvpNativeStatus.invalid:
        _emit(
          BackendEvent(
            BackendEventKind.failure,
            failureKind: _networkError
                ? PlayerFailureKind.networkOpen
                : PlayerFailureKind.nativePlayback,
            generation: generation,
          ),
        );
        return;
    }
    _emit(
      BackendEvent(
        BackendEventKind.buffering,
        value: _buffering,
        generation: generation,
      ),
    );
  }

  void _startSampling(int generation) {
    _sampler?.cancel();
    _sampler = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!_current(generation) || _disposed) return;
      final player = _player!;
      // A stale native callback can still report an old position while a seek
      // is being prepared. The shared engine ignores samples while seeking.
      final position = Duration(
        milliseconds: player.positionMilliseconds.clamp(0, 1 << 53),
      );
      if (player.bufferedMilliseconds > 0) _networkError = false;
      final raw = buffered;
      final display = raw == null
          ? null
          : _bufferDisplay.update(
              position: position,
              buffered: raw,
              buffering: _buffering,
            );
      _emit(
        BackendEvent(
          BackendEventKind.sample,
          position: position,
          duration: _duration(),
          buffered: display ?? raw,
          dimensions: _dimensions,
          generation: generation,
        ),
      );
    });
  }

  @override
  Future<VideoDimensions?> confirmVideo(PlaybackOperation operation) async {
    final player = _player!;
    final generation = _generation;
    onStage?.call(NativeReadinessStage.videoOutput);
    operation.check();
    final texture = await operation.wait(player.createTexture());
    if (!_current(generation)) throw const SourceSuperseded();
    if (texture < 0) throw StateError('Video output unavailable');
    final dimensions = _dimensions;
    if (dimensions == null) throw StateError('Video did not decode');
    _output.bind(texture, dimensions);
    FvpLifecycle.log(
      'backend-bind id=$instanceId generation=$generation texture=$texture',
    );
    onStage?.call(NativeReadinessStage.videoDecode);
    operation.check();
    if (!await operation.wait(player.confirmVideoFrame())) {
      throw StateError('Video did not render');
    }
    if (!_current(generation)) throw const SourceSuperseded();
    return dimensions;
  }

  @override
  Future<void> confirmAudio(PlaybackOperation operation) async {
    final player = _player!;
    final generation = _generation;
    onStage?.call(NativeReadinessStage.externalAudio);
    operation.check();
    if (!await operation.wait(player.confirmAudio())) {
      throw StateError('Audio did not decode');
    }
    if (!_current(generation)) throw const SourceSuperseded();
  }

  @override
  Future<void> confirmPresentation(PlaybackOperation operation) =>
      operation.wait(_output.confirmFrame());

  @override
  Future<void> play() async {
    final player = _player;
    if (player == null || _disposed) return;
    _nativeEnded = false;
    player.play();
  }

  @override
  Future<bool> pauseAndWait() async {
    final player = _player;
    if (player == null) return true;
    final paused = await player.pauseAndConfirm();
    // MDK keeps EOF stopped for replay; its pause request cannot acknowledge
    // that a surviving external audio pipe has stopped too.
    return paused && !_nativeEnded;
  }

  @override
  Future<void> setRate(double rate) async {
    final player = _player;
    if (player == null || _disposed) return;
    player.setRate(rate);
  }

  Future<void> _applyVolume() async {
    _player?.setVolume(_volume, _gain);
  }

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
    final player = _player!;
    final generation = _generation;
    _bufferDisplay.reset();
    try {
      final position = await operation.wait(player.seek(target));
      if (!_current(generation)) throw const SourceSuperseded();
      // -2 is the SDK's cancelled/retired seek slot, not a playback failure.
      if (position == -2) throw const SourceSuperseded();
      if (position < 0) throw StateError('MDK seek failed');
      _nativeEnded = false;
      return Duration(milliseconds: position);
    } on PlayerFailure {
      rethrow;
    } on StateError {
      if (_disposed || generation != _generation) {
        throw const SourceSuperseded();
      }
      throw PlayerFailure(
        PlayerFailureKind.nativePlayback,
        'fvp 无法完成跳转',
        generation,
      );
    }
  }

  @override
  Future<void> cancelSeek() async => await _player?.cancelSeek();

  @override
  void interrupt() {
    _bufferDisplay.reset();
    _sampler?.cancel();
    _sampler = null;
    _preparation?.cancel();
    _player?.interrupt();
  }

  @override
  Future<PlayerPlaybackInformation?> inspectPlaybackInformation(
    int generation,
  ) async {
    final player = _player;
    if (_disposed || player == null || generation != _generation) return null;
    final information = switch (player) {
      FvpInformationPort port => await port.inspectPlaybackInformation(
        generation: generation,
        audioGainDb: _gain,
      ),
      _ => PlayerPlaybackInformation(
        generation: generation,
        backend: 'fvp / MDK',
        audioGainDb: _gain,
      ),
    };
    if (_disposed || generation != _generation || !identical(player, _player)) {
      return null;
    }
    return information;
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    final watch = Stopwatch()..start();
    FvpLifecycle.disposeBackendStart(instanceId);
    _disposed = true;
    _generation++;
    _preparation?.cancel();
    _sampler?.cancel();
    _sampler = null;
    // Unbind the Flutter texture before any native teardown can wait. The
    // texture is never registered again for a later session.
    _output.clear();
    FvpLifecycle.log('backend-unbind id=$instanceId generation=$_generation');
    await _subscription?.cancel();
    _subscription = null;
    final creating = _creating;
    if (creating != null) {
      try {
        await creating;
      } on Object {
        // No native resource was returned.
      }
      _creating = null;
    }
    final player = _player;
    _player = null;
    if (player != null) {
      try {
        await player.dispose();
      } on Object {
        // The backend remains released; the orphan counter records uncertainty.
      }
    }
    _output.dispose();
    if (!_events.isClosed) await _events.close();
    FvpLifecycle.disposeBackendEnd(instanceId, watch.elapsed);
  }
}
