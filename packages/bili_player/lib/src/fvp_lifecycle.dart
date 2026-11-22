import 'dart:developer' as developer;

/// Process-wide counters and structured logs for the experimental FVP backend.
///
/// Native destruction is the only operation that can outlive its Dart owner on
/// iOS. These counters make an orphaned player visible in device logs without
/// exposing media URLs, headers or native error text.
final class FvpLifecycle {
  FvpLifecycle._();

  static int _nextBackend = 0;
  static int _nextPlayer = 0;
  static int _activeBackends = 0;
  static int _activePlayers = 0;
  static int _orphanedPlayers = 0;
  static int _createdBackends = 0;
  static int _disposedBackends = 0;
  static int _createdPlayers = 0;
  static int _disposedPlayers = 0;

  static int get activeBackends => _activeBackends;
  static int get activePlayers => _activePlayers;
  static int get orphanedPlayers => _orphanedPlayers;
  static int get createdBackends => _createdBackends;
  static int get disposedBackends => _disposedBackends;
  static int get createdPlayers => _createdPlayers;
  static int get disposedPlayers => _disposedPlayers;

  static int createBackend() {
    final id = ++_nextBackend;
    _createdBackends++;
    _activeBackends++;
    log('backend-create id=$id active=$_activeBackends');
    return id;
  }

  static void disposeBackendStart(int id) =>
      log('backend-dispose-start id=$id active=$_activeBackends');

  static void disposeBackendEnd(int id, Duration elapsed) {
    _activeBackends--;
    _disposedBackends++;
    log(
      'backend-dispose-end id=$id active=$_activeBackends '
      'took=${elapsed.inMilliseconds}ms',
    );
  }

  static int createPlayer() {
    final id = ++_nextPlayer;
    _createdPlayers++;
    _activePlayers++;
    log('player-create id=$id active=$_activePlayers');
    return id;
  }

  static void disposePlayerStart(int id) =>
      log('player-dispose-start id=$id active=$_activePlayers');

  static void disposePlayerEnd(
    int id,
    Duration elapsed, {
    bool orphaned = false,
  }) {
    _activePlayers--;
    _disposedPlayers++;
    if (orphaned) _orphanedPlayers++;
    log(
      'player-dispose-end id=$id active=$_activePlayers '
      'took=${elapsed.inMilliseconds}ms orphaned=$orphaned totalOrphaned=$_orphanedPlayers',
    );
  }

  static void log(String message) =>
      developer.log('fvp: $message', name: 'bilisail.fvp');
}
