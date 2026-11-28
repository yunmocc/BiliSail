import 'package:bili_player/bili_player.dart';
import 'package:flutter_test/flutter_test.dart';

MediaTrack track({
  String uri = 'https://example.com/video',
  Map<String, String> headers = const {},
  bool isHdr = false,
}) => MediaTrack(
  uri: Uri.parse(uri),
  requestPolicy: MediaRequestPolicy(headers: headers),
  isHdr: isHdr,
);

void main() {
  test('preview buffer and live timeline rules', () {
    const requested = OpenOptions(
      startPosition: Duration(seconds: 17),
      rate: 2,
      volume: 0,
    );
    final preview = ValidatedSource.validate(
      DashVideoSource(track()),
      requested,
      1,
    );
    expect(preview.silent, true);
    expect(preview.options.maxBufferAhead, const Duration(seconds: 5));
    final live = ValidatedSource.validate(
      ManifestSource(track(), isLive: true),
      requested,
      1,
    );
    expect(live.live, true);
    expect(live.options.startPosition, Duration.zero);
    expect(live.options.rate, 1);
  });

  test('normalizes header names and preserves silent, preview and audio requirements', () {
    final paired = ValidatedSource.validate(
      DashPairSource(
        video: track(headers: {'Referer': 'same'}),
        audio: track(headers: {'referer': 'same'}),
      ),
      const OpenOptions(),
      1,
    );
    expect(paired.audio, isNotNull);
    final silent = ValidatedSource.validate(
      DashPairSource(video: track(), audio: null, isIntentionallySilent: true),
      const OpenOptions(volume: 50),
      1,
    );
    expect(silent.silent, true);
    expect(silent.requiresVideo, true);
    final audio = ValidatedSource.validate(
      ProgressiveSource(track(), isAudioOnly: true),
      const OpenOptions(),
      1,
    );
    expect(audio.audioOnly, true);
    expect(audio.requiresVideo, false);
  });

  test('unsupported transport schemes need explicit opt-in', () {
    expect(
      () => ValidatedSource.validate(
        ProgressiveSource(track(uri: 'content://provider/video')),
        const OpenOptions(),
        1,
      ),
      throwsA(isA<PlayerFailure>()),
    );
    expect(
      ValidatedSource.validate(
        ProgressiveSource(track(uri: 'content://provider/video')),
        const OpenOptions(),
        1,
        schemes: const {'content'},
      ).media.uri.scheme,
      'content',
    );
  });
}
