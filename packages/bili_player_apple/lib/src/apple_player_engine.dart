import 'dart:async';

import 'package:bili_player/bili_player.dart';

import 'apple_player_backend.dart';
import 'apple_player_video_output.dart';

/// iOS-only playback engine. All platform semantics live in the backend.
final class ApplePlayerEngine extends SharedPlayerEngine {
  factory ApplePlayerEngine({
    void Function(PlayerDiagnosticEvent)? onDiagnostic,
  }) {
    late final ApplePlayerEngine engine;
    engine = ApplePlayerEngine._(
      onDiagnostic,
      () => ApplePlayerBackend(
        snapshot: () => engine.currentSnapshot,
        onDiagnostic: onDiagnostic,
      ),
    );
    return engine;
  }

  ApplePlayerEngine._(
    void Function(PlayerDiagnosticEvent)? onDiagnostic,
    FutureOr<PlaybackBackend> Function() createBackend,
  ) : super(
        createBackend: createBackend,
        initialVideoOutput: ApplePlayerVideoOutput(playerId: -1),
        schemes: const {'http', 'https', 'file'},
        onDiagnostic: onDiagnostic,
      );
}
