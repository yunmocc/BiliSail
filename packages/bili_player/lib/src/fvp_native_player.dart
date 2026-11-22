import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:fvp/fvp.dart' as fvp;
import 'package:fvp/mdk.dart' as mdk;

import 'fvp_buffer.dart';
import 'fvp_lifecycle.dart';
import 'fvp_playback_information.dart';
import 'fvp_seek.dart';
import 'fvp_video_decoders.dart';
import 'player_contract.dart';
import 'player_playback_information.dart';
import 'third_party/fvp_audio_activity.g.dart' as audio_activity;

final class FvpMediaInfo {
  const FvpMediaInfo({
    required this.duration,
    this.dimensions,
    required this.hasAudio,
    this._hasVideo,
  });
  final Duration duration;
  final VideoDimensions? dimensions;
  final bool hasAudio;
  final bool? _hasVideo;
  bool get hasVideo => _hasVideo ?? dimensions != null;
}

/// MDK uses -4/-8 for a target clamped to the known duration. Treat that as
/// the publishable end position instead of a playback failure.
bool fvpSeekIsNearEnd(Duration target, int durationMilliseconds) =>
    durationMilliseconds > 0 &&
    target.inMilliseconds >= durationMilliseconds - 500;

int normalizeFvpSeekResult({
  required int result,
  required Duration target,
  required int durationMilliseconds,
}) {
  if (result == -4 ||
      (result == -8 && fvpSeekIsNearEnd(target, durationMilliseconds))) {
    return durationMilliseconds > 0
        ? durationMilliseconds
        : target.inMilliseconds;
  }
  return result;
}

enum FvpNativeStatus {
  buffering,
  buffered,
  ended,
  audioEnded,
  invalid,
  networkError,
}

/// Small native boundary for deterministic cancellation and failure tests.
abstract interface class FvpPlayerPort {
  int get instanceId;
  Stream<FvpNativeStatus> get statuses;
  int get positionMilliseconds;
  int get bufferedMilliseconds;
  int get durationMilliseconds;
  Future<FvpMediaInfo> prepare(
    MediaTrack media,
    MediaTrack? audio,
    OpenOptions options, {
    required bool silent,
    bool isLive = false,
  });
  Future<int> createTexture();
  Future<bool> confirmVideoFrame();
  Future<bool> confirmAudio();
  void play();
  Future<bool> pauseAndConfirm();
  void interrupt();
  // Completes after the video and companion audio targets are ready.
  Future<int> seek(Duration target);
  // Retires in-flight preparation; the next seek restores this source.
  Future<void> cancelSeek();
  void setRate(double rate);
  void setVolume(double volume, double gainDb);
  Future<void> dispose();
  bool get disposed;
}

/// Optional statistics capability, independent of playback commands so test
/// adapters can be introduced without inventing native observations.
abstract interface class FvpInformationPort {
  Future<PlayerPlaybackInformation?> inspectPlaybackInformation({
    required int generation,
    required double audioGainDb,
  });
}

/// Count of frames decoded by the actual native audio pipeline, not a probe.
abstract interface class FvpAudioActivityPort {
  int get decodedAudioFrames;
}

abstract interface class FvpAudioClockPort {
  int? get audioPositionMilliseconds;
}

Future<void>? _initialization;

Future<FvpPlayerPort> createFvpNativePlayer({int? windowsAdapterIndex}) async {
  return createInProcessFvpNativePlayer(
    windowsAdapterIndex: windowsAdapterIndex,
  );
}

Future<FvpPlayerPort> createInProcessFvpNativePlayer({
  int? windowsAdapterIndex,
}) async {
  await (_initialization ??= () async {
    // Install fvp's bundled Flutter key without forwarding raw URL/header logs.
    fvp.registerWith(
      options: <String, Object>{
        'global': <String, Object>{'log': 'off'},
      },
    );
    await Future<void>.delayed(Duration.zero);
    mdk.setLogHandler((_, _) {});
    mdk.setGlobalOption('logLevel', mdk.LogLevel.off);
    mdk.setGlobalOption('videoout.clear_on_stop', 0);
  }());
  return _MdkPlayerPort(windowsAdapterIndex: windowsAdapterIndex);
}

final class _MdkPlayerPort
    implements
        FvpPlayerPort,
        FvpInformationPort,
        FvpAudioActivityPort,
        FvpAudioClockPort {
  _MdkPlayerPort({this.windowsAdapterIndex, this.audioOnly = false})
    : instanceId = FvpLifecycle.createPlayer();

  @override
  final int instanceId;
  final int? windowsAdapterIndex;
  final bool audioOnly;
  mdk.Player? _native;
  mdk.Player get _player => _native!;
  _MdkPlayerPort? _audioCompanion;
  StreamSubscription<FvpNativeStatus>? _audioSubscription;
  Pointer<Void> _audioClock = nullptr;
  Pointer<Void> _audioActivity = nullptr;
  int _durationMilliseconds = 0;
  bool _videoBuffering = false, _audioBuffering = false;
  final _playingClock = Stopwatch();
  double _rate = 1;
  int _audioReadyPosition = 0;
  bool _audioTargetReady = false;

  @override
  int? get audioPositionMilliseconds =>
      _audioCompanion?.positionMilliseconds ??
      (!_silent ? positionMilliseconds : null);
  final _interrupted = Completer<void>();
  final _statuses = StreamController<FvpNativeStatus>.broadcast(sync: true);
  StreamSubscription<Object?>? _statusSubscription;
  StreamSubscription<Object?>? _eventSubscription;
  StreamSubscription<Object?>? _stateSubscription;
  final _audioOpened = Completer<bool>();
  final _firstFrame = Completer<bool>();
  final _prepared = Completer<bool>();
  final _paused = Completer<void>();
  Future<int>? _textureCreation;
  bool _closed = false;
  bool _closing = false;
  bool _live = false;
  bool _ended = false;
  mdk.PlaybackState _observedState = mdk.PlaybackState.stopped;
  Duration _startPosition = Duration.zero;
  int? _preparedAudioPosition;
  VideoDimensions? _dimensions;
  Future<void>? _disposal;
  Completer<int>? _seekCancelled;
  Future<void>? _retiringSeek;
  bool _repreparing = false;
  int _nativeSeekRevision = 0;
  String _mediaUri = '';
  bool _silent = false;
  double? _appliedGainDb;
  mdk.AudioCodecParameters? _externalAudio;
  String? _videoDecoder;
  bool _videoDecoded = false;
  bool _audioDecoded = false;
  bool _videoRendered = false;
  VideoDimensions? _textureDimensions;

  @override
  bool get disposed => _closed;

  @override
  int get decodedAudioFrames =>
      _audioCompanion?.decodedAudioFrames ??
      audio_activity.bili_fvp_audio_frames(_audioActivity);

  void _buffering(bool value, {bool audio = false}) {
    if (audio) {
      _audioBuffering = value;
    } else {
      _videoBuffering = value;
    }
    _statuses.add(
      _audioBuffering || _videoBuffering
          ? FvpNativeStatus.buffering
          : FvpNativeStatus.buffered,
    );
  }

  void _companionStatus(FvpNativeStatus status) {
    if (_closed || _closing || _repreparing || _seekCancelled != null) return;
    switch (status) {
      case FvpNativeStatus.buffering:
        _buffering(true, audio: true);
      case FvpNativeStatus.buffered:
        _buffering(false, audio: true);
      case FvpNativeStatus.invalid ||
          FvpNativeStatus.audioEnded ||
          FvpNativeStatus.networkError:
        _statuses.add(status);
      case FvpNativeStatus.ended:
        // MDK may reset audio.position to zero as the output reaches EOS.
        // The still displayed video frame confirms a natural paired ending.
        final audioPosition = _audioCompanion?.positionMilliseconds ?? 0;
        final videoPosition = _native?.position ?? 0;
        final position = audioPosition > videoPosition
            ? audioPosition
            : videoPosition;
        if (_durationMilliseconds - position > 500) {
          _statuses.add(FvpNativeStatus.audioEnded);
        } else {
          // Natural audio EOS has no further clock ticks. Drain only the
          // paired final video frame, instead of waiting on a reset AO clock.
          _holdClock(_durationMilliseconds);
        }
    }
  }

  static bool _isNetworkError(String category, String detail) {
    final value = '$category $detail'.toLowerCase();
    if (value.contains('http') ||
        value.contains('tls') ||
        value.contains('ssl') ||
        value.contains('connection') ||
        value.contains('timed out') ||
        value.contains('timeout') ||
        value.contains('resolve') ||
        value.contains('network') ||
        value.contains('i/o error')) {
      return true;
    }
    return false;
  }

  void _initializePlayer() {
    _native = mdk.Player();
    _audioActivity = audio_activity.bili_fvp_audio_attach(_player.nativeHandle);
    if (_audioActivity == nullptr) {
      throw StateError('MDK audio activity observation unavailable');
    }
    _eventSubscription = _player.onEvent.listen((event) {
      if (_closed) return;
      if (event.category == 'decoder.video') {
        if (event.detail == 'open' && event.error < 0) {
          _videoDecoded = false;
          _videoDecoder = null;
        } else if (event.error == 0 && fvpDecoderName(event.detail) != null) {
          _videoDecoder = event.detail;
          _videoDecoded = true;
        }
      }
      if (event.category == 'decoder.audio' &&
          event.error >= 0 &&
          event.detail != 'decode error') {
        _audioDecoded = true;
      }
      if (event.category == 'decoder.audio' && !_audioOpened.isCompleted) {
        _audioOpened.complete(event.error >= 0);
      }
      if (event.error < 0 && _isNetworkError(event.category, event.detail)) {
        _statuses.add(FvpNativeStatus.networkError);
      }
      if (event.category == 'render.video' && event.detail == '1st_frame') {
        _videoRendered = event.error >= 0;
        _videoDecoded = _videoRendered;
        if (!_firstFrame.isCompleted) _firstFrame.complete(event.error >= 0);
      }
    });
    _statusSubscription = _player.onMediaStatus.listen((event) {
      if (_closed || _repreparing || _seekCancelled != null) return;
      final status = event.newValue;
      if (status.test(mdk.MediaStatus.invalid)) {
        if (!_prepared.isCompleted) _prepared.complete(false);
        _statuses.add(FvpNativeStatus.invalid);
      } else if (status.test(
        mdk.MediaStatus.buffering | mdk.MediaStatus.stalled,
      )) {
        _buffering(true);
      } else if (status.test(mdk.MediaStatus.buffered)) {
        _buffering(false);
      }
      if (status.test(mdk.MediaStatus.prepared) && !_prepared.isCompleted) {
        _prepared.complete(true);
      }
    });
    _stateSubscription = _player.onStateChanged.listen((event) {
      if (_closed) return;
      _observedState = event.newValue;
      if (_repreparing) return;
      if (event.newValue == mdk.PlaybackState.paused && !_paused.isCompleted) {
        _paused.complete();
      }
      if (event.newValue == mdk.PlaybackState.stopped &&
          event.oldValue != mdk.PlaybackState.stopped) {
        // Demux EOF can precede completion while decoded data remains buffered.
        _ended = _player.mediaStatus.test(mdk.MediaStatus.end);
        // Keep the native EOF fact even while the shared engine ignores seek
        // events. Otherwise the next pause can wait forever on an EOF player.
        if (_seekCancelled != null) return;
        if (_ended) _audioCompanion?.pause();
        _statuses.add(_ended ? FvpNativeStatus.ended : FvpNativeStatus.invalid);
      }
    });
  }

  @override
  Stream<FvpNativeStatus> get statuses => _statuses.stream;
  @override
  int get positionMilliseconds {
    if (_closed) return 0;
    final position = _native?.position ?? 0;
    // Pure audio has no presentation clock until first play. Use the native
    // prepare/seek confirmation while paused, then retire it on the first tick.
    final prepared = _preparedAudioPosition;
    if (prepared != null) {
      if (!_playingClock.isRunning ||
          position == 0 && prepared > 0 ||
          (position - prepared).abs() >
              500 + _playingClock.elapsedMilliseconds * _rate) {
        return prepared;
      }
    }
    _preparedAudioPosition = null;
    return position;
  }

  @override
  int get bufferedMilliseconds {
    if (_closed) return 0;
    final audio = _audioCompanion;
    return fvpBufferedMilliseconds(
      position: positionMilliseconds,
      buffered: _native?.buffered() ?? 0,
      audioPosition: audio?.positionMilliseconds,
      audioBuffered: audio?.bufferedMilliseconds,
    );
  }

  @override
  int get durationMilliseconds => _closed ? 0 : _durationMilliseconds;

  @override
  Future<PlayerPlaybackInformation?> inspectPlaybackInformation({
    required int generation,
    required double audioGainDb,
  }) async {
    final player = _native;
    if (_closed ||
        _closing ||
        _repreparing ||
        player == null ||
        _interrupted.isCompleted ||
        !player.mediaStatus.test(mdk.MediaStatus.loaded)) {
      return null;
    }
    return sampleFvpPlaybackInformation(
      media: player.mediaInfo,
      externalAudio: _externalAudio,
      silent: _silent,
      videoDecoded: _videoDecoded,
      audioDecoded: _audioDecoded || decodedAudioFrames > 0,
      videoRendered: _videoRendered,
      videoDecoder: _videoDecoder,
      outputDimensions: _textureDimensions,
      generation: generation,
      positionMilliseconds: positionMilliseconds,
      bufferedMilliseconds: bufferedMilliseconds,
      audioGainDb: audioGainDb,
    );
  }

  Future<T> _active<T>(Future<T> operation) => Future.any<T>([
    operation,
    _interrupted.future.then<T>((_) => throw StateError('MDK interrupted')),
  ]);

  @override
  Future<FvpMediaInfo> prepare(
    MediaTrack media,
    MediaTrack? audio,
    OpenOptions options, {
    required bool silent,
    bool isLive = false,
  }) async {
    if (audio != null) {
      // Keep a real paused audio player. Both native targets are decoded before
      // play, and video follows this player's native audio presentation clock.
      final companion = _audioCompanion = _MdkPlayerPort(audioOnly: true);
      final info = await _active(
        companion.prepare(audio, null, options, silent: false),
      );
      if (!info.hasAudio) throw StateError('No companion audio track');
      if (!await _active(companion._audioOpened.future)) {
        throw StateError('Companion audio decoder failed');
      }
      final codec = companion._player.mediaInfo.audio?.firstOrNull?.codec;
      if (codec != null) {
        _externalAudio = mdk.AudioCodecParameters()
          ..codec = codec.codec
          ..bitRate = codec.bitRate
          ..channels = codec.channels
          ..sampleRate = codec.sampleRate;
      }
      _audioSubscription = companion.statuses.listen(_companionStatus);
      if (!_audioOpened.isCompleted) _audioOpened.complete(true);
    }
    if (_interrupted.isCompleted || _closing) {
      throw StateError('MDK preparation cancelled');
    }
    _initializePlayer();
    _connectAudioClock();
    _holdClock(options.startPosition.inMilliseconds);
    _audioReadyPosition = options.startPosition.inMilliseconds;
    _player.videoDecoders = fvpVideoDecoders(
      operatingSystem: Platform.operatingSystem,
      decoding: options.videoDecoding,
      windowsAdapterIndex: windowsAdapterIndex,
    );
    _player.setProperty('subtitle', '0');
    _player.setProperty(
      'avio.headers',
      media.requestPolicy.headers.entries
          .map((entry) => '${entry.key}: ${entry.value}\r\n')
          .join(),
    );
    // The application owns bounded retries and source refreshes.
    _player.setProperty('avio.reconnect', '0');
    _player.setProperty('avio.rw_timeout', '30000000');
    _player.setBufferRange(
      min: options.maxBufferAhead.inMilliseconds.clamp(1, 1000),
      max: options.maxBufferAhead.inMilliseconds.clamp(
        1,
        OpenOptions.maximumBufferAhead.inMilliseconds,
      ),
    );
    setRate(options.rate);
    _startPosition = options.startPosition;
    // Both real pipelines prepare while paused at the user's selected volume.
    setVolume(options.volume, options.audioGainDb);
    _mediaUri = _uri(media.uri);
    _silent = silent;
    _player.media = _mediaUri;
    _player.activeSubtitleTracks = const [];
    if (_silent || _audioCompanion != null) {
      _player.activeAudioTracks = const [];
    }
    if (audioOnly) _player.activeVideoTracks = const [];
    final result = await _active(_player.prepare());
    if (_closing || _closed || result < 0) {
      throw StateError('MDK preparation failed');
    }
    if (!await _active(_prepared.future)) {
      throw StateError('MDK tracks did not prepare');
    }
    await _active(_paused.future);
    if (_closing || _closed) throw StateError('MDK preparation cancelled');
    final info = _player.mediaInfo;
    _live = isLive || _player.isLive;
    _durationMilliseconds = info.duration;
    final video = info.video?.firstOrNull;
    if ((video == null || audioOnly) && !_live) {
      // Pure audio never enters confirmVideoFrame. Confirm its resume target
      // here, while still paused, before publishing a ready source.
      final position = await _active(
        _player.seek(
          position: options.startPosition.inMilliseconds,
          flags: _preciseSeek,
        ),
      );
      if (position < 0) throw StateError('MDK audio position did not prepare');
      _preparedAudioPosition = position;
      _audioTargetReady = true;
      _audioDecoded = true;
    }
    VideoDimensions? dimensions;
    if (!audioOnly &&
        video != null &&
        video.codec.width > 0 &&
        video.codec.height > 0) {
      var width = video.codec.width;
      var height = (video.codec.height / video.codec.par).round();
      if (video.rotation % 180 == 90) (width, height) = (height, width);
      dimensions = VideoDimensions(width, height);
    }
    _dimensions = dimensions;
    return FvpMediaInfo(
      duration: _live || info.duration <= 0
          ? Duration.zero
          : Duration(milliseconds: info.duration),
      dimensions: dimensions,
      hasAudio: audio != null || (!silent && info.audio?.isNotEmpty == true),
      hasVideo: !audioOnly && info.video?.isNotEmpty == true,
    );
  }

  String _uri(Uri uri) => switch (uri.scheme) {
    'file' => uri.toFilePath(),
    _ => uri.toString(),
  };

  @override
  Future<int> createTexture() => _textureCreation = () async {
    final texture = await _player.updateTexture(
      width: _dimensions?.width,
      height: _dimensions?.height,
      fit: false,
    );
    if (!_closing && !_closed && texture >= 0) {
      _textureDimensions = _dimensions;
    }
    return texture;
  }();

  @override
  Future<bool> confirmVideoFrame() async {
    _connectAudioClock();
    _holdClock(_startPosition.inMilliseconds);
    // Live has no network seek. Decode the first already buffered target
    // while paused, without advancing the live clock to obtain a frame.
    final result = await _active(
      _player.seek(
        position: _live ? 0 : _startPosition.inMilliseconds,
        flags: _live
            ? const mdk.SeekFlag(mdk.SeekFlag.fromStart | mdk.SeekFlag.inCache)
            : _preciseSeek,
      ),
    );
    if (result < 0) return false;
    return _active(_firstFrame.future);
  }

  void _connectAudioClock() {
    if (_audioClock != nullptr) return;
    if (_audioCompanion case final companion?) {
      _audioClock = audio_activity.bili_fvp_audio_clock(
        _player.nativeHandle,
        companion._player.nativeHandle,
      );
      if (_audioClock == nullptr) {
        throw StateError('Audio master clock unavailable');
      }
    }
  }

  Future<void> _pauseAndWait() async {
    if (_native == null || _closed) return;
    _player.state = mdk.PlaybackState.paused;
    while (!_player.waitFor(mdk.PlaybackState.paused, timeout: 0)) {
      // waitFor(Stopped) can join native I/O even with a zero timeout. Keep
      // normal pause polling on Paused and use the asynchronous EOF evidence.
      if (_ended ||
          _repreparing ||
          _observedState == mdk.PlaybackState.stopped &&
              _player.mediaStatus.test(mdk.MediaStatus.end)) {
        _ended = _player.mediaStatus.test(mdk.MediaStatus.end);
        return;
      }
      await _active(Future<void>.delayed(const Duration(milliseconds: 10)));
    }
  }

  @override
  Future<bool> confirmAudio() async {
    var revision = _nativeSeekRevision;
    if (_audioCompanion case final companion?) {
      final ready = await _active(companion.confirmAudio());
      if (revision != _nativeSeekRevision || _repreparing) return false;
      _audioDecoded = ready;
      return ready;
    }
    if (!await _active(_audioOpened.future)) return false;
    if (revision != _nativeSeekRevision ||
        _repreparing ||
        _closed ||
        _closing ||
        _ended) {
      return false;
    }
    final target = positionMilliseconds;
    if (!_live &&
        _dimensions == null &&
        (!_audioTargetReady || (target - _audioReadyPosition).abs() > 100)) {
      final seeking = seek(Duration(milliseconds: target));
      revision = _nativeSeekRevision;
      if (await seeking < 0 || revision != _nativeSeekRevision) return false;
    }
    while (!_player.mediaStatus.test(mdk.MediaStatus.prepared) ||
        (!_live && _dimensions == null && !_audioTargetReady)) {
      if (_ended ||
          _closed ||
          _closing ||
          _repreparing ||
          revision != _nativeSeekRevision) {
        return false;
      }
      await _active(Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    if (revision != _nativeSeekRevision) return false;
    _audioDecoded = true;
    return true;
  }

  @override
  void play() {
    _audioCompanion?.play();
    audio_activity.bili_fvp_audio_clock_play(_audioClock);
    _playingClock
      ..reset()
      ..start();
    _native?.state = mdk.PlaybackState.playing;
  }

  void _holdClock(int position) =>
      audio_activity.bili_fvp_audio_clock_hold(_audioClock, position);

  void pause() {
    if (_dimensions == null && _native != null) {
      _preparedAudioPosition = positionMilliseconds;
    }
    _playingClock.stop();
    _audioCompanion?.pause();
    if (_seekCancelled == null) {
      _holdClock(_audioCompanion?.positionMilliseconds ?? positionMilliseconds);
    }
    // Keep EOF stopped so replay can prepare it before requesting a pause.
    if (!_closed && !_ended && !_repreparing) {
      _native?.state = mdk.PlaybackState.paused;
    }
  }

  @override
  Future<bool> pauseAndConfirm() async {
    if (_closed) return true;
    if (_closing || _ended || _repreparing) return false;
    if (_audioCompanion case final companion?) {
      if (!await companion.pauseAndConfirm()) return false;
      if (_seekCancelled == null) _holdClock(companion.positionMilliseconds);
    }
    await _pauseAndWait();
    return !_ended && !_repreparing;
  }

  @override
  void interrupt() {
    _holdClock(_audioCompanion?.positionMilliseconds ?? positionMilliseconds);
    final cancelled = _seekCancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete(-2);
    if (!_interrupted.isCompleted) _interrupted.complete();
    _audioCompanion?.interrupt();
    if (!_closed && _native != null) {
      // Clear the video source as well as retiring the audio companion.
      _native!.media = '';
      _native!.state = mdk.PlaybackState.stopped;
    }
  }

  bool _nearEnd(Duration target) =>
      fvpSeekIsNearEnd(target, _durationMilliseconds);

  bool finalResultNearEnd(int position) =>
      _durationMilliseconds > 0 && position >= _durationMilliseconds - 500;

  int _normalizeSeekResult(int result, Duration target) {
    final normalized = normalizeFvpSeekResult(
      result: result,
      target: target,
      durationMilliseconds: _durationMilliseconds,
    );
    if (normalized != result) _ended = true;
    return normalized;
  }

  @override
  Future<int> seek(Duration target) async {
    final forward = target.inMilliseconds - positionMilliseconds;
    final flags =
        !_ended &&
            !_repreparing &&
            forward > 0 &&
            forward <= bufferedMilliseconds
        ? const mdk.SeekFlag(mdk.SeekFlag.fromStart | mdk.SeekFlag.inCache)
        : _preciseSeek;
    final revision = ++_nativeSeekRevision;
    final cancelled = _seekCancelled = Completer<int>();
    // Freeze the old timeline until video acknowledges pause. Moving its master
    // to a backward target before that acknowledgement can strand an old frame.
    if (!_repreparing) {
      _holdClock(_audioCompanion?.positionMilliseconds ?? positionMilliseconds);
    }
    _audioCompanion?.pause();
    _playingClock.stop();
    _audioReadyPosition = target.inMilliseconds;
    _audioTargetReady = false;
    var reuseRetirement = _repreparing;
    int? confirmedPosition;
    bool isCancelled() =>
        cancelled.isCompleted || revision != _nativeSeekRevision;
    Future<int> restoreTarget() async {
      _repreparing = true;
      if (!reuseRetirement) {
        _retiringSeek ??= _retireSeek().whenComplete(
          () => _retiringSeek = null,
        );
      }
      await _retiringSeek;
      // A replacement reuses cancelSeek's completed teardown once. A native
      // busy/unloaded reply after prepare needs a fresh teardown of that load.
      reuseRetirement = false;
      if (isCancelled()) return -2;
      audio_activity.bili_fvp_audio_clock_seek(_audioClock);
      _player.media = _mediaUri;
      _player.activeSubtitleTracks = const [];
      if (_silent || _audioCompanion != null) {
        _player.activeAudioTracks = const [];
      }
      final result = await _active(
        _player.prepare(position: target.inMilliseconds, flags: _preciseSeek),
      );
      if (isCancelled()) return -2;
      if (result < 0) return result;
      _ended = false;
      return result;
    }

    Future<bool> pauseTarget() async {
      _player.state = mdk.PlaybackState.paused;
      while (!_player.waitFor(mdk.PlaybackState.paused, timeout: 0)) {
        if (isCancelled() || _observedState == mdk.PlaybackState.stopped) {
          return false;
        }
        await _active(Future<void>.delayed(const Duration(milliseconds: 10)));
      }
      return true;
    }

    Future<int> prepareTarget() async {
      await _retiringSeek;
      return seekFvpTarget(
        isCancelled: isCancelled,
        needsPrepare: () => _ended || _repreparing,
        prepare: restoreTarget,
        pauseAndWait: pauseTarget,
        seek: () {
          audio_activity.bili_fvp_audio_clock_seek(_audioClock);
          return _active(
            _player.seek(position: target.inMilliseconds, flags: flags),
          );
        },
      );
    }

    try {
      var result = await _active(
        Future.any([prepareTarget(), cancelled.future]),
      );
      result = _normalizeSeekResult(result, target);
      if (isCancelled()) return -2;
      if (result < 0) return result;
      final audio = _audioCompanion;
      if (result >= 0 && audio != null) {
        var audioResult = await _active(
          Future.any([
            audio.seek(Duration(milliseconds: result)),
            cancelled.future,
          ]),
        );
        if (isCancelled()) return -2;
        // Audio may reach EOF at the same clamped target. Video still owns
        // the publishable position; only a real unload/internal error fails.
        if (audioResult == -4 || audioResult == -8) {
          audioResult = result;
        } else if (audioResult == -2) {
          return -2;
        } else if (audioResult < 0) {
          return audioResult;
        }
        if ((audioResult - result).abs() > 100 && !_nearEnd(target)) {
          return -8;
        }
        if (!await _active(
          Future.any([
            audio.confirmAudio(),
            cancelled.future.then((_) => false),
          ]),
        )) {
          return isCancelled()
              ? -2
              : (finalResultNearEnd(result) ? result : -8);
        }
      }
      if (isCancelled()) return -2;
      if (result >= 0) confirmedPosition = result;
      if (result >= 0 &&
          revision == _nativeSeekRevision &&
          _dimensions == null) {
        _preparedAudioPosition = result;
        _audioTargetReady = true;
        _audioDecoded = true;
      }
      return result;
    } finally {
      if (revision == _nativeSeekRevision) {
        // Only this seek may end its clock override. A retired callback cannot
        // freeze the replacement at an old target or release its audio early.
        _holdClock(
          confirmedPosition ??
              _audioCompanion?.positionMilliseconds ??
              _audioReadyPosition,
        );
        _seekCancelled = null;
        _repreparing = false;
        if (!_closed && !_closing) {
          _audioBuffering =
              _audioCompanion?._player.mediaStatus.test(
                mdk.MediaStatus.buffering | mdk.MediaStatus.stalled,
              ) ??
              false;
          _buffering(
            _player.mediaStatus.test(
              mdk.MediaStatus.buffering | mdk.MediaStatus.stalled,
            ),
          );
        }
      }
    }
  }

  @override
  Future<void> cancelSeek() => _cancelSeek();

  Future<void> _cancelSeek({bool retire = false}) async {
    final cancelled = _seekCancelled;
    if (!retire && (cancelled == null || cancelled.isCompleted)) return;
    if (_native == null || _closed || _closing) return;
    ++_nativeSeekRevision;
    _repreparing = true;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete(-2);
    _retiringSeek ??= _retireSeek().whenComplete(() => _retiringSeek = null);
    // Stop/dispose can supersede the replacement before anyone awaits it.
    unawaited(
      _retiringSeek!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    await Future.wait([
      _retiringSeek!,
      // Shared transport cancellation retires both tracks' HTTP readers. The
      // audio demuxer must stop even if video has not reached its seek yet.
      if (_audioCompanion case final audio?) audio._cancelSeek(retire: true),
    ]);
  }

  Future<void> _retireSeek() async {
    // Changing media also aborts an in-flight prepare, whose playback state
    // can already be Stopped while its network open is still pending.
    if (_native == null) return;
    _player.media = '';
    _player.state = mdk.PlaybackState.stopped;
    while (true) {
      if (_closed || _closing || _interrupted.isCompleted) {
        throw StateError('MDK seek retirement cancelled');
      }
      if (_player.waitFor(mdk.PlaybackState.stopped, timeout: 0)) break;
      await _active(Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    // Native teardown has retired its callbacks. Drain queued Dart replies
    // before reusing fvp's single prepare-completion slot.
    await _active(Future<void>.delayed(Duration.zero));
  }

  // Preparation, backward and uncached seeks use ordinary precise demux seek.
  static const _preciseSeek = mdk.SeekFlag(mdk.SeekFlag.fromStart);

  @override
  void setRate(double rate) {
    _rate = rate;
    _audioCompanion?.setRate(rate);
    _native?.playbackRate = rate;
  }

  @override
  void setVolume(double volume, double gainDb) {
    _audioCompanion?.setVolume(volume, gainDb);
    if (_native == null) return;
    _player.volume = volume / 100;
    // Updating base volume must not rebuild an unchanged MDK audio filter.
    // Apply gain while paused, before the target timeline advances.
    if (_appliedGainDb == gainDb) return;
    _player.setProperty(
      'audio.avfilter',
      gainDb == 0 ? '' : 'volume=${gainDb}dB',
    );
    _appliedGainDb = gainDb;
  }

  void _releaseObservers(Pointer<Void> clock, Pointer<Void> activity) {
    audio_activity.bili_fvp_audio_clock_release(clock);
    // Destruction joins MDK's decoder threads. Only then can the observer's
    // opaque state be freed; unregistering alone is not a callback barrier.
    audio_activity.bili_fvp_audio_release(activity);
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    if (_closed) return;
    final watch = Stopwatch()..start();
    FvpLifecycle.disposePlayerStart(instanceId);
    _closing = true;
    interrupt();

    // A pending CreateRT must never be followed by deleting its native player.
    // Wait briefly for the normal reply; if it is still outstanding, defer the
    // native deletion until that reply arrives and never reuse the handle.
    var texturePending = false;
    try {
      await _textureCreation?.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      texturePending = true;
    } on Object {
      // Creation reported an error; the native handle is still safe to retire.
    }
    _closed = true;
    final native = _native;
    _native = null;
    final clock = _audioClock;
    final activity = _audioActivity;
    var orphaned = false;
    var observersReleased = false;
    void releaseOnce() {
      if (observersReleased) return;
      observersReleased = true;
      _releaseObservers(clock, activity);
    }

    Future<void> disposeNative() async {
      if (native == null) return;
      try {
        await native.disposeAsync();
        releaseOnce();
      } on Object {
        FvpLifecycle.log('player-dispose-error id=$instanceId');
      }
    }

    if (native != null) {
      if (texturePending && _textureCreation != null) {
        // The texture reply owns the only safe deletion point.
        orphaned = true;
        FvpLifecycle.log(
          'player-dispose-deferred id=$instanceId texture-pending',
        );
        unawaited(
          _textureCreation!.then<void>(
            (_) async {
              await disposeNative();
              FvpLifecycle.log('player-orphan-reclaimed id=$instanceId');
            },
            onError: (Object _, StackTrace _) async {
              // A failed CreateRT can no longer wrap the handle, so retire it.
              await disposeNative();
              FvpLifecycle.log('player-orphan-reclaim-failed id=$instanceId');
            },
          ),
        );
      } else {
        // Interrupt has already cleared media and stopped the pipeline. MDK
        // deletes the native player only after this future completes.
        final pending = native.disposeAsync();
        try {
          await pending.timeout(const Duration(seconds: 10));
          releaseOnce();
        } on TimeoutException {
          // iOS cannot kill an in-process native player. Never call
          // disposeAsync twice (it would double-free) and never expose this
          // handle again. Observe the pending future until teardown arrives.
          orphaned = true;
          unawaited(
            pending.then<void>(
              (_) {
                releaseOnce();
                FvpLifecycle.log('player-orphan-reclaimed id=$instanceId');
              },
              onError: (Object _, StackTrace _) {
                FvpLifecycle.log('player-orphan-reclaim-failed id=$instanceId');
              },
            ),
          );
        } on Object {
          orphaned = true;
          FvpLifecycle.log('player-dispose-error id=$instanceId');
        }
      }
    }

    // Release the companion in parallel with the primary native teardown so a
    // slow player cannot double the open deadline. The audio clock stays held
    // until both pipelines are gone.
    final companion = _audioCompanion;
    _audioCompanion = null;
    final companionDisposal = companion?.dispose();
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await companionDisposal;
    if (!orphaned) releaseOnce();
    _audioClock = nullptr;
    _audioActivity = nullptr;
    await _statusSubscription?.cancel();
    await _eventSubscription?.cancel();
    await _stateSubscription?.cancel();
    _statusSubscription = null;
    _eventSubscription = null;
    _stateSubscription = null;
    await _statuses.close();
    FvpLifecycle.disposePlayerEnd(
      instanceId,
      watch.elapsed,
      orphaned: orphaned,
    );
  }
}
