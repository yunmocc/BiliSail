import 'dart:async';

import 'package:bili_player/bili_player.dart';

import 'fvp_backend.dart';
import 'fvp_native_player.dart';

/// MDK entrypoint. The native player runs in-process on every supported
/// platform, so no helper isolate or child process is involved.
final class FvpEngine extends SharedPlayerEngine {
  factory FvpEngine({
    void Function(PlayerDiagnosticEvent)? onDiagnostic,
    Future<FvpPlayerPort> Function()? createPlayer,
  }) {
    late final FvpEngine engine;
    NativeReadinessStage? readinessStage;
    engine = FvpEngine._(
      seekCoalescingDelay: createPlayer == null
          ? const Duration(milliseconds: 40)
          : Duration.zero,
      onDiagnostic: (event) {
        if (event.kind == PlayerDiagnosticKind.openStarted ||
            event.kind == PlayerDiagnosticKind.openReady) {
          readinessStage = null;
        }
        onDiagnostic?.call(
          PlayerDiagnosticEvent(
            kind: event.kind,
            snapshot: event.snapshot,
            readinessStage: readinessStage,
            failureKind: event.failureKind,
            nativeError: event.nativeError,
            nativeErrorCode: event.nativeErrorCode,
            stallReason: event.stallReason,
            stalledFor: event.stalledFor,
            audioPosition: event.audioPosition,
          ),
        );
      },
      createBackend: () => FvpBackend(
        createPlayer: createPlayer,
        onStage: (stage) {
          readinessStage = stage;
          onDiagnostic?.call(
            PlayerDiagnosticEvent(
              kind: PlayerDiagnosticKind.openStageChanged,
              snapshot: engine.currentSnapshot,
              readinessStage: stage,
            ),
          );
        },
      ),
    );
    return engine;
  }

  // The explicit super invocation also supplies fixed schemes, which prevents
  // forwarding these two parameters as super parameters.
  // ignore: use_super_parameters
  FvpEngine._({
    required FutureOr<PlaybackBackend> Function() createBackend,
    super.onDiagnostic,
    required Duration seekCoalescingDelay,
  }) : super(
         createBackend: createBackend,
         schemes: const {'http', 'https', 'file'},
         seekCoalescingDelay: seekCoalescingDelay,
       );

  @override
  Future<void> seek(Duration target) =>
      super.seek(target < Duration.zero ? Duration.zero : target);
}
