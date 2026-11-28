import 'package:bili_player/src/ios_av_sync_guard.dart';
import 'package:flutter_test/flutter_test.dart';

AvSyncSample sample({
  double? audio,
  double? video,
  double? cache,
  bool hardware = true,
  bool pausedForCache = false,
}) => AvSyncSample(
  audioPositionSeconds: audio,
  videoPositionSeconds: video,
  cacheDurationSeconds: cache,
  hardwareDecoding: hardware,
  pausedForCache: pausedForCache,
);

AvSyncAction evaluate(
  IosAvSyncGuard guard,
  AvSyncSample value,
  Duration now, {
  bool eligible = true,
}) => guard.evaluate(now: now, eligible: eligible, sample: value);

void main() {
  test('pauses when audio drifts more than half a second ahead', () {
    final guard = IosAvSyncGuard();
    expect(
      evaluate(guard, sample(audio: 10, video: 10), Duration.zero),
      AvSyncAction.none,
    );
    expect(
      evaluate(
        guard,
        sample(audio: 10.7, video: 10),
        const Duration(milliseconds: 200),
      ),
      AvSyncAction.pause,
    );
    expect(guard.pausedForVideo, isTrue);
  });

  test('waits for a sustained video stall before pausing', () {
    final guard = IosAvSyncGuard();
    expect(
      evaluate(guard, sample(audio: 10, video: 10), Duration.zero),
      AvSyncAction.none,
    );
    // Video is frozen and audio advances, but the drift is still small.
    expect(
      evaluate(
        guard,
        sample(audio: 10.25, video: 10),
        const Duration(milliseconds: 500),
      ),
      AvSyncAction.none,
    );
    expect(
      evaluate(
        guard,
        sample(audio: 10.45, video: 10),
        const Duration(milliseconds: 1400),
      ),
      AvSyncAction.pause,
    );
  });

  test('never pauses software decoding or ineligible playback', () {
    final guard = IosAvSyncGuard();
    for (final value in [
      sample(audio: 12, video: 9, hardware: false),
      sample(audio: 9, video: 12, hardware: false),
    ]) {
      expect(
        evaluate(guard, value, const Duration(seconds: 1)),
        AvSyncAction.none,
      );
    }
    expect(
      evaluate(
        guard,
        sample(audio: 12, video: 9),
        const Duration(seconds: 2),
        eligible: false,
      ),
      AvSyncAction.none,
    );
    expect(guard.pausedForVideo, isFalse);
  });

  test('resumes only after the minimum pause and a refilled cache', () {
    final guard = IosAvSyncGuard();
    evaluate(guard, sample(audio: 10, video: 10), Duration.zero);
    evaluate(
      guard,
      sample(audio: 10.6, video: 10),
      const Duration(milliseconds: 500),
    );
    expect(guard.pausedForVideo, isTrue);
    expect(
      evaluate(
        guard,
        sample(audio: 10.6, video: 10, cache: 0.5),
        const Duration(milliseconds: 800),
      ),
      AvSyncAction.none,
    );
    expect(
      evaluate(
        guard,
        sample(audio: 10.6, video: 10, cache: 1.5),
        const Duration(milliseconds: 1200),
      ),
      AvSyncAction.none,
    );
    expect(
      evaluate(
        guard,
        sample(audio: 10.6, video: 10, cache: 2.5),
        const Duration(milliseconds: 1300),
      ),
      AvSyncAction.resume,
    );
    expect(guard.pausedForVideo, isFalse);
  });

  test('residual drift after a resume does not immediately re-pause', () {
    final guard = IosAvSyncGuard();
    evaluate(guard, sample(audio: 10, video: 10), Duration.zero);
    evaluate(
      guard,
      sample(audio: 11, video: 10),
      const Duration(milliseconds: 500),
    );
    expect(
      evaluate(
        guard,
        sample(audio: 11, video: 10, cache: 3),
        const Duration(milliseconds: 1200),
      ),
      AvSyncAction.resume,
    );
    // mpv's autosync still has to remove the old one-second lead.
    expect(
      evaluate(
        guard,
        sample(audio: 11, video: 10, cache: 3),
        const Duration(milliseconds: 1700),
      ),
      AvSyncAction.none,
    );
    expect(
      evaluate(
        guard,
        sample(audio: 11.2, video: 10, cache: 3),
        const Duration(milliseconds: 2200),
      ),
      AvSyncAction.none,
    );
    expect(
      evaluate(
        guard,
        sample(audio: 11.7, video: 10, cache: 3),
        const Duration(milliseconds: 2700),
      ),
      AvSyncAction.pause,
    );
  });

  test('does not resume while mpv still reports a cache underrun', () {
    final guard = IosAvSyncGuard();
    evaluate(guard, sample(audio: 10, video: 10), Duration.zero);
    evaluate(
      guard,
      sample(audio: 11, video: 10),
      const Duration(milliseconds: 500),
    );
    expect(
      evaluate(
        guard,
        sample(audio: 11, video: 10, cache: 8, pausedForCache: true),
        const Duration(milliseconds: 1400),
      ),
      AvSyncAction.none,
    );
  });

  test('resuming a rate change or seek releases a paused guard', () {
    final guard = IosAvSyncGuard();
    evaluate(guard, sample(audio: 10, video: 10), Duration.zero);
    evaluate(
      guard,
      sample(audio: 10.8, video: 10),
      const Duration(milliseconds: 500),
    );
    expect(guard.pausedForVideo, isTrue);
    expect(
      evaluate(
        guard,
        sample(audio: 10.8, video: 10, cache: 0),
        const Duration(seconds: 2),
        eligible: false,
      ),
      AvSyncAction.resume,
    );
    expect(guard.pausedForVideo, isFalse);
  });

  test('unavailable clocks and seeks do not look like a stall', () {
    final guard = IosAvSyncGuard();
    evaluate(guard, sample(audio: 10, video: 10), Duration.zero);
    // A backward jump is a seek, not a stalled video decoder.
    expect(
      evaluate(
        guard,
        sample(audio: 0.5, video: 0.4),
        const Duration(milliseconds: 500),
      ),
      AvSyncAction.none,
    );
    expect(
      evaluate(guard, sample(), const Duration(milliseconds: 900)),
      AvSyncAction.none,
    );
    expect(guard.pausedForVideo, isFalse);
  });

  test('a permanently unavailable cache eventually releases the guard', () {
    final guard = IosAvSyncGuard();
    evaluate(guard, sample(audio: 10, video: 10), Duration.zero);
    evaluate(
      guard,
      sample(audio: 11, video: 10),
      const Duration(milliseconds: 500),
    );
    expect(
      evaluate(
        guard,
        sample(audio: 11, video: 10),
        const Duration(seconds: 11),
      ),
      AvSyncAction.resume,
    );
  });
}
