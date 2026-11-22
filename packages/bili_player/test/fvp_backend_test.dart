import 'dart:async';

import 'package:bili_player/bili_player.dart';
import 'package:bili_player/src/fvp_backend.dart';
import 'package:bili_player/src/fvp_lifecycle.dart';
import 'package:bili_player/src/fvp_native_player.dart';
import 'package:bili_player/src/playback_backend.dart';
import 'package:bili_player/src/validated_source.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakePlayer implements FvpPlayerPort, FvpInformationPort {
  _FakePlayer();

  @override
  final int instanceId = 1;
  final Duration duration = const Duration(seconds: 30);
  final _statuses = StreamController<FvpNativeStatus>.broadcast(sync: true);
  @override
  Stream<FvpNativeStatus> get statuses => _statuses.stream;
  int position = 0;
  int bufferedAhead = 4000;
  bool prepared = false, playing = false;
  @override
  bool disposed = false;
  int playCalls = 0, pauseCalls = 0, disposeCalls = 0, seekCalls = 0;
  double rate = 1, volume = 100, gain = 0;
  Duration? lastSeek;
  bool pauseResult = true;
  bool videoFrame = true;
  bool audioReady = true;
  int texture = 7;
  int seekResult = 0;
  Completer<void>? disposeGate;

  @override
  int get positionMilliseconds => position;
  @override
  int get bufferedMilliseconds => bufferedAhead;
  @override
  int get durationMilliseconds => duration.inMilliseconds;

  @override
  Future<FvpMediaInfo> prepare(
    MediaTrack media,
    MediaTrack? audio,
    OpenOptions options, {
    required bool silent,
    bool isLive = false,
  }) async {
    prepared = true;
    position = options.startPosition.inMilliseconds;
    return FvpMediaInfo(
      duration: duration,
      dimensions: const VideoDimensions(1920, 1080),
      hasAudio: audio != null || !silent,
      hasVideo: true,
    );
  }

  @override
  Future<int> createTexture() async => texture;
  @override
  Future<bool> confirmVideoFrame() async => videoFrame;
  @override
  Future<bool> confirmAudio() async => audioReady;

  @override
  void play() {
    playCalls++;
    playing = true;
  }

  @override
  Future<bool> pauseAndConfirm() async {
    pauseCalls++;
    playing = false;
    return pauseResult;
  }

  @override
  void interrupt() {
    playing = false;
  }

  @override
  Future<int> seek(Duration target) async {
    seekCalls++;
    lastSeek = target;
    if (seekResult != 0) return seekResult;
    position = target.inMilliseconds;
    return position;
  }

  @override
  Future<void> cancelSeek() async {}
  @override
  void setRate(double rate) => this.rate = rate;
  @override
  void setVolume(double volume, double gainDb) {
    this.volume = volume;
    gain = gainDb;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
    await disposeGate?.future;
    await _statuses.close();
  }

  @override
  Future<PlayerPlaybackInformation?> inspectPlaybackInformation({
    required int generation,
    required double audioGainDb,
  }) async => PlayerPlaybackInformation(
    generation: generation,
    backend: 'fvp / MDK',
    audioGainDb: audioGainDb,
  );
}

MediaTrack _track(String name) => MediaTrack(
  uri: Uri.parse('https://example.com/$name'),
  requestPolicy: MediaRequestPolicy(),
);

DashPairSource _pair() =>
    DashPairSource(video: _track('v'), audio: _track('a'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'open, play, seek, rate, volume and gain use the SDK contract',
    () async {
      final player = _FakePlayer();
      final engine = FvpEngine(createPlayer: () async => player);
      final snapshots = <PlaybackSnapshot>[];
      engine.snapshots.listen(snapshots.add);
      await engine.open(_pair(), const OpenOptions(play: true, rate: 1.5));
      expect(player.prepared, isTrue);
      expect(player.playCalls, 1);
      expect(player.rate, 1.5);
      expect(engine.currentSnapshot.phase, PlaybackPhase.playing);
      expect(
        engine.currentSnapshot.videoDimensions,
        const VideoDimensions(1920, 1080),
      );

      await engine.pause();
      expect(player.pauseCalls, greaterThanOrEqualTo(1));
      expect(engine.currentSnapshot.phase, PlaybackPhase.paused);

      await engine.seek(const Duration(seconds: 5));
      expect(player.lastSeek, const Duration(seconds: 5));
      expect(engine.currentSnapshot.position, const Duration(seconds: 5));

      await engine.setRate(2);
      expect(player.rate, 2);
      await engine.setVolume(40);
      expect(player.volume, 40);
      await engine.setAudioGain(-3);
      expect(player.gain, closeTo(-3, 0.01));
      expect(snapshots, isNotEmpty);
      await engine.dispose();
      expect(player.disposeCalls, 1);
    },
  );

  test(
    'status events update the shared timeline with generation tags',
    () async {
      final player = _FakePlayer();
      final backend = FvpBackend(createPlayer: () async => player);
      final events = <BackendEvent>[];
      backend.events.listen(events.add);
      final operation = PlaybackOperation(7, const Duration(seconds: 5));
      final plan = ValidatedSource.validate(_pair(), const OpenOptions(), 7);
      final tracks = await backend.preparePaused(plan, operation);
      expect(tracks.hasVideo, isTrue);
      expect(tracks.hasAudio, isTrue);
      expect(tracks.externalAudioSelected, isTrue);
      player.position = 1200;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final sample = events.lastWhere(
        (event) => event.kind == BackendEventKind.sample,
      );
      expect(sample.generation, 7);
      expect(sample.position, const Duration(milliseconds: 1200));
      player._statuses.add(FvpNativeStatus.buffering);
      await Future<void>.delayed(Duration.zero);
      final buffering = events.lastWhere(
        (event) => event.kind == BackendEventKind.buffering,
      );
      expect(buffering.value, isTrue);
      expect(buffering.generation, 7);
      await backend.dispose();
      expect(player.disposeCalls, 1);
    },
  );

  test(
    'dispose is single-flight, backgrounded and clears the texture',
    () async {
      final player = _FakePlayer();
      final backend = FvpBackend(createPlayer: () async => player);
      final operation = PlaybackOperation(1, const Duration(seconds: 5));
      final plan = ValidatedSource.validate(_pair(), const OpenOptions(), 1);
      await backend.preparePaused(plan, operation);
      final gate = player.disposeGate = Completer<void>();
      final first = backend.dispose();
      final second = backend.dispose();
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(player.disposed, isTrue);
      expect(player.disposeCalls, 1);
      gate.complete();
      await first;
      expect(
        FvpLifecycle.activeBackends,
        lessThan(FvpLifecycle.createdBackends),
      );
    },
  );

  test(
    'failed native preparation rejects the open without leaking a player',
    () async {
      final player = _FakePlayer()..videoFrame = false;
      final engine = FvpEngine(createPlayer: () async => player);
      await expectLater(
        engine.open(_pair(), const OpenOptions(play: true)),
        throwsA(isA<PlayerFailure>()),
      );
      await engine.dispose();
      expect(player.disposeCalls, 1);
      expect(FvpLifecycle.activePlayers, 0);
    },
  );

  test('ended and invalid statuses become terminal failures', () async {
    final player = _FakePlayer();
    final engine = FvpEngine(createPlayer: () async => player);
    await engine.open(_pair(), const OpenOptions(play: true));
    player.position = player.duration.inMilliseconds;
    player._statuses.add(FvpNativeStatus.ended);
    await Future<void>.delayed(Duration.zero);
    expect(engine.currentSnapshot.phase, PlaybackPhase.ended);
    await engine.dispose();

    final failing = _FakePlayer();
    final failingEngine = FvpEngine(createPlayer: () async => failing);
    final failures = <PlayerFailure>[];
    failingEngine.failures.listen(failures.add);
    await failingEngine.open(_pair(), const OpenOptions(play: true));
    failing._statuses.add(FvpNativeStatus.invalid);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(failures, isNotEmpty);
    await failingEngine.dispose();
  });
  test(
    'a native network error becomes networkOpen for the invalid status',
    () async {
      final player = _FakePlayer();
      final backend = FvpBackend(createPlayer: () async => player);
      final events = <BackendEvent>[];
      backend.events.listen(events.add);
      final operation = PlaybackOperation(3, const Duration(seconds: 5));
      final plan = ValidatedSource.validate(_pair(), const OpenOptions(), 3);
      await backend.preparePaused(plan, operation);
      player._statuses.add(FvpNativeStatus.networkError);
      player._statuses.add(FvpNativeStatus.invalid);
      await Future<void>.delayed(Duration.zero);
      expect(
        events.where((event) => event.kind == BackendEventKind.networkError),
        isNotEmpty,
      );
      final failure = events.lastWhere(
        (event) => event.kind == BackendEventKind.failure,
      );
      expect(failure.failureKind, PlayerFailureKind.networkOpen);
      expect(failure.generation, 3);
      await backend.dispose();
    },
  );
  test('cancelled seeks do not fail the session', () async {
    final player = _FakePlayer();
    final engine = FvpEngine(createPlayer: () async => player);
    await engine.open(_pair(), const OpenOptions(play: true));
    player.seekResult = -2;
    await engine.seek(const Duration(seconds: 5));
    expect(player.seekCalls, 1);
    expect(engine.currentSnapshot.phase, PlaybackPhase.playing);
    await engine.dispose();
  });

  test('MDK end-of-stream seek codes are accepted only near the duration', () {
    const duration = 30000;
    expect(
      normalizeFvpSeekResult(
        result: -8,
        target: const Duration(milliseconds: 30000),
        durationMilliseconds: duration,
      ),
      30000,
    );
    expect(
      normalizeFvpSeekResult(
        result: -8,
        target: const Duration(milliseconds: 10000),
        durationMilliseconds: duration,
      ),
      -8,
    );
    expect(
      normalizeFvpSeekResult(
        result: -4,
        target: const Duration(milliseconds: 10000),
        durationMilliseconds: duration,
      ),
      30000,
    );
    expect(
      normalizeFvpSeekResult(
        result: -2,
        target: const Duration(milliseconds: 30000),
        durationMilliseconds: duration,
      ),
      -2,
    );
  });
  test(
    'a zero packet endpoint is exposed only after a network error',
    () async {
      final player = _FakePlayer();
      final backend = FvpBackend(createPlayer: () async => player);
      final operation = PlaybackOperation(9, const Duration(seconds: 5));
      final plan = ValidatedSource.validate(_pair(), const OpenOptions(), 9);
      await backend.preparePaused(plan, operation);
      player.position = 4000;
      player.bufferedAhead = 0;
      expect(backend.buffered, const Duration(milliseconds: 4000));
      player._statuses.add(FvpNativeStatus.networkError);
      await Future<void>.delayed(Duration.zero);
      expect(backend.buffered, Duration.zero);
      await backend.dispose();
    },
  );
}
