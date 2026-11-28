import 'package:bili_player/bili_player.dart';

const _localVideoExtensions = {'.mp4', '.mov', '.m4v'};
const _localAudioExtensions = {'.m4a', '.mp3', '.aac', '.wav', '.flac'};
const _rejectedExtensions = {
  '.mkv',
  '.avi',
  '.flv',
  '.webm',
  '.ts',
  '.m2ts',
  '.wmv',
  '.rmvb',
};

String _extensionOf(Uri uri) {
  final path = uri.path.toLowerCase();
  final slash = path.lastIndexOf('/');
  final name = slash < 0 ? path : path.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot);
}

bool _isAv1(String? codec) {
  if (codec == null) return false;
  final normalized = codec.toLowerCase();
  return normalized == 'av1' ||
      normalized == 'av01' ||
      normalized.contains('av01.') ||
      normalized.contains('av1 ');
}

/// AVPlayer cannot demux FLV, MKV, AVI or decode AV1 on A14. Reject before
/// touching the network so the failure is deterministic and actionable.
void validateApplePlayerSource(ValidatedSource plan, int generation) {
  Never invalid(String message) =>
      throw PlayerFailure(PlayerFailureKind.invalidSource, message, generation);

  if (plan.live && plan.source is ProgressiveSource) {
    invalid('iOS 直播仅支持 HLS 线路');
  }
  if (_isAv1(plan.media.codec) || _isAv1(plan.audio?.codec)) {
    invalid('当前设备不支持 AV1，请切换到 H.264 或 HEVC');
  }

  for (final track in [plan.media, ?plan.audio]) {
    final extension = _extensionOf(track.uri);
    if (_rejectedExtensions.contains(extension)) {
      invalid('iOS 仅支持 MP4/MOV，暂不支持 ${extension.substring(1).toUpperCase()}');
    }
    if (track.uri.scheme == 'file') {
      final allowed = plan.audioOnly
          ? {..._localVideoExtensions, ..._localAudioExtensions}
          : _localVideoExtensions;
      if (!allowed.contains(extension)) {
        invalid(
          plan.audioOnly
              ? 'iOS 本地音频仅支持 M4A/MP3/AAC/WAV/FLAC'
              : 'iOS 本地视频仅支持 MP4/MOV',
        );
      }
    }
  }
}

Map<String, Object?> applePlayerOpenPayload({
  required int playerId,
  required int generation,
  required ValidatedSource plan,
}) {
  final audio = plan.audio;
  final kind = switch (plan.source) {
    DashPairSource() => 'dash',
    DashVideoSource() => 'preview',
    ManifestSource() => 'manifest',
    ProgressiveSource() => 'progressive',
  };
  final videoUrls = [plan.media.uri, ...plan.media.alternates];
  final audioUrls = audio == null
      ? const <Uri>[]
      : [audio.uri, ...audio.alternates];
  return {
    'playerId': playerId,
    'generation': generation,
    'kind': kind,
    'videoUrl': plan.media.uri.toString(),
    'videoUrls': [for (final uri in videoUrls) uri.toString()],
    if (audio != null) 'audioUrl': audio.uri.toString(),
    if (audioUrls.isNotEmpty)
      'audioUrls': [for (final uri in audioUrls) uri.toString()],
    'headers': plan.media.requestPolicy.headers,
    'startPositionMs': plan.options.startPosition.inMilliseconds,
    'rate': plan.options.rate,
    'volume': plan.options.volume / 100,
    'gainDb': plan.options.audioGainDb,
    'maxBufferAheadMs': plan.options.maxBufferAhead.inMilliseconds,
    'timeoutMs': plan.options.openTimeout.inMilliseconds,
    'live': plan.live,
    'muted': plan.silent,
    'audioOnly': plan.audioOnly,
    'videoExpected': !plan.audioOnly,
    'audioExpected': !plan.silent,
    'externalAudio': audio != null,
    'videoCodec': plan.media.codec,
    'audioCodec': audio?.codec ?? plan.media.embeddedAudioCodec,
  };
}
