import 'fvp_backend.dart';
import 'fvp_native_player.dart';
import 'player_diagnostics.dart';
import 'shared_player_engine.dart';

/// Pinned MDK entrypoint for iOS. Playback decisions live in SharedPlayerEngine.
final class FvpEngine extends SharedPlayerEngine {
  static int _nextDiagnosticId = 0;
  factory FvpEngine({
    void Function(PlayerDiagnosticEvent)? onDiagnostic,
    Future<FvpPlayerPort> Function()? createPlayer,
  }) {
    late final FvpEngine engine;
    final diagnosticId = ++_nextDiagnosticId;
    NativeReadinessStage? readinessStage;
    void report(PlayerDiagnosticEvent event) {
      if (event.kind == PlayerDiagnosticKind.openStarted ||
          event.kind == PlayerDiagnosticKind.openReady) {
        readinessStage = null;
      }
      onDiagnostic?.call(
        event.withContext(
          playerId: diagnosticId,
          readinessStage: readinessStage,
        ),
      );
    }

    engine = FvpEngine._(
      createBackend: () => FvpBackend(
        createPlayer: createPlayer ?? (() => createFvpNativePlayer()),
        onStage: (stage) {
          readinessStage = stage;
          onDiagnostic?.call(
            PlayerDiagnosticEvent(
              kind: PlayerDiagnosticKind.openStageChanged,
              snapshot: engine.currentSnapshot,
              readinessStage: stage,
              playerId: diagnosticId,
            ),
          );
        },
      ),
      onDiagnostic: onDiagnostic == null ? null : report,
      seekCoalescingDelay: createPlayer == null
          ? const Duration(milliseconds: 40)
          : Duration.zero,
    );
    return engine;
  }

  FvpEngine._({
    required super.createBackend,
    super.onDiagnostic,
    required super.seekCoalescingDelay,
  }) : super(schemes: const {'http', 'https', 'file'});

  @override
  Future<void> seek(Duration target) =>
      super.seek(target < Duration.zero ? Duration.zero : target);
}
