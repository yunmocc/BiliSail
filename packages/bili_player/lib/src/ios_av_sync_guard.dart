/// One sample of the native clocks used to keep audio and video together.
final class AvSyncSample {
  const AvSyncSample({
    this.audioPositionSeconds,
    this.videoPositionSeconds,
    this.cacheDurationSeconds,
    this.hardwareDecoding = false,
    this.pausedForCache = false,
  });

  final double? audioPositionSeconds;
  final double? videoPositionSeconds;

  /// Forward media time available in the native demuxer cache.
  final double? cacheDurationSeconds;

  /// VideoToolbox (or another hardware decoder) currently owns the video.
  final bool hardwareDecoding;

  /// mpv itself has paused the core because its cache underran.
  final bool pausedForCache;

  /// Positive values mean the audio clock is ahead of the video clock.
  double? get audioLeadSeconds {
    final audio = audioPositionSeconds;
    final video = videoPositionSeconds;
    if (audio == null || video == null) return null;
    final lead = audio - video;
    return lead.isFinite ? lead : null;
  }
}

enum AvSyncAction { none, pause, resume }

/// Keeps a hardware-decoded iOS stream's audio on the same clock as video.
///
/// mpv normally pauses both streams when its cache underruns. At rates above
/// 1x an audio output can keep running while video decoding falls behind,
/// which is audible as sound during a buffering picture. The guard pauses the
/// native player, lets the cache refill and resumes playback afterwards.
///
/// This is pure decision logic. The caller owns clocks, native property reads
/// and the pause/play commands, so the policy remains testable.
final class IosAvSyncGuard {
  IosAvSyncGuard({
    this.maxAudioLeadSeconds = 0.5,
    this.videoStallGrace = const Duration(milliseconds: 800),
    this.minimumPauseDuration = const Duration(milliseconds: 600),
    this.resumeCacheSeconds = 2.0,
    this.maxPauseDuration = const Duration(seconds: 10),
  });

  /// Video more than this far behind audio counts as desynchronized.
  final double maxAudioLeadSeconds;

  /// Audio may lead in short bursts; only a sustained stall pauses playback.
  final Duration videoStallGrace;

  /// Avoids pause/resume flapping at a cache boundary.
  final Duration minimumPauseDuration;

  /// Resume only after this much forward media time is cached.
  final double resumeCacheSeconds;

  /// A cache reading can stay unavailable; never hold playback forever.
  final Duration maxPauseDuration;

  bool _paused = false;
  Duration? _pausedAt;
  Duration? _stallStartedAt;
  double? _lastAudioSeconds;
  double? _lastVideoSeconds;

  /// Residual drift accepted when playback (re)starts. mpv's autosync corrects
  /// the audio clock after a pause; measuring from this baseline avoids a
  /// pause/resume loop around the absolute threshold.
  double? _leadBaseline;

  bool get pausedForVideo => _paused;

  void reset() {
    _paused = false;
    _pausedAt = null;
    _stallStartedAt = null;
    _lastAudioSeconds = null;
    _lastVideoSeconds = null;
    _leadBaseline = null;
  }

  AvSyncAction evaluate({
    required Duration now,
    required bool eligible,
    required AvSyncSample sample,
  }) {
    if (_paused) {
      final pausedFor = now - (_pausedAt ?? now);
      if (!eligible) {
        reset();
        return AvSyncAction.resume;
      }
      if (pausedFor < minimumPauseDuration) return AvSyncAction.none;
      final cache = sample.cacheDurationSeconds;
      final refilled =
          cache != null &&
          cache >= resumeCacheSeconds &&
          !sample.pausedForCache;
      if (refilled || pausedFor >= maxPauseDuration) {
        reset();
        return AvSyncAction.resume;
      }
      return AvSyncAction.none;
    }

    if (!eligible || !sample.hardwareDecoding) {
      _forgetProgress();
      return AvSyncAction.none;
    }

    final audio = sample.audioPositionSeconds;
    final video = sample.videoPositionSeconds;
    final previousAudio = _lastAudioSeconds;
    final previousVideo = _lastVideoSeconds;
    double? audioAdvance;
    double? videoAdvance;
    if (audio != null && previousAudio != null) {
      audioAdvance = audio - previousAudio;
    }
    if (video != null && previousVideo != null) {
      videoAdvance = video - previousVideo;
    }
    _lastAudioSeconds = audio;
    _lastVideoSeconds = video;

    // Ignore clock jumps caused by seeking, rate changes or a source switch.
    final validDelta =
        audioAdvance != null &&
        videoAdvance != null &&
        audioAdvance >= -0.5 &&
        audioAdvance <= 5 &&
        videoAdvance >= -0.5;
    // The tolerance absorbs binary rounding between two native clock reads.
    final audioRunning = (audioAdvance ?? 0) >= 0.15;
    final videoStalled = validDelta && audioRunning && videoAdvance <= 0.05;
    final stalled = videoStalled || (sample.pausedForCache && audioRunning);
    if (stalled) {
      _stallStartedAt ??= now;
    } else {
      _stallStartedAt = null;
    }

    final lead = sample.audioLeadSeconds;
    if (lead != null) _leadBaseline ??= lead;
    final drifted =
        lead != null && lead - (_leadBaseline ?? lead) >= maxAudioLeadSeconds;
    final stalledFor = _stallStartedAt == null
        ? Duration.zero
        : now - _stallStartedAt!;
    if (drifted || stalledFor >= videoStallGrace) {
      _paused = true;
      _pausedAt = now;
      _stallStartedAt = null;
      return AvSyncAction.pause;
    }
    return AvSyncAction.none;
  }

  void _forgetProgress() {
    _stallStartedAt = null;
    _lastAudioSeconds = null;
    _lastVideoSeconds = null;
  }
}
