import 'dart:async';

import 'package:flutter/services.dart';

/// Thin, non-interpreting bridge to the Swift AVPlayer host.
final class ApplePlayerChannel {
  ApplePlayerChannel(this.playerId);

  final int playerId;
  static const _methods = MethodChannel('bilisail/apple_player');

  Stream<Map<String, Object?>> get events => EventChannel(
    'bilisail/apple_player/events/$playerId',
  ).receiveBroadcastStream().map((event) {
    if (event is! Map) {
      throw StateError('Malformed native player event.');
    }
    return event.cast<String, Object?>();
  });

  Future<void> create() =>
      _methods.invokeMethod<void>('create', {'playerId': playerId});

  Future<Map<String, Object?>> open(
    Map<String, Object?> payload, {
    required Duration timeout,
  }) async {
    final result = await _methods
        .invokeMapMethod<String, Object?>('open', payload)
        .timeout(timeout);
    if (result == null) throw StateError('Native player returned no track data.');
    return result;
  }

  Future<void> play({required double rate}) => _methods.invokeMethod<void>(
    'play',
    {'playerId': playerId, 'rate': rate},
  );

  Future<void> pause() =>
      _methods.invokeMethod<void>('pause', {'playerId': playerId});

  Future<void> setRate(double rate) => _methods.invokeMethod<void>(
    'setRate',
    {'playerId': playerId, 'rate': rate},
  );

  Future<void> setVolume(double volume) => _methods.invokeMethod<void>(
    'setVolume',
    {'playerId': playerId, 'volume': volume},
  );

  Future<void> setGain(double gainDb) => _methods.invokeMethod<void>(
    'setGain',
    {'playerId': playerId, 'gainDb': gainDb},
  );

  Future<Duration> seek(Duration target, {required Duration timeout}) async {
    final value = await _methods
        .invokeMethod<double>('seek', {
          'playerId': playerId,
          'positionMs': target.inMilliseconds,
        })
        .timeout(timeout);
    return Duration(milliseconds: (value ?? target.inMilliseconds.toDouble()).round());
  }

  Future<void> cancelSeek() =>
      _methods.invokeMethod<void>('cancelSeek', {'playerId': playerId});

  Future<void> reset() =>
      _methods.invokeMethod<void>('reset', {'playerId': playerId});

  Future<void> interrupt() =>
      _methods.invokeMethod<void>('interrupt', {'playerId': playerId});

  Future<Map<String, Object?>> inspect() async {
    final result = await _methods
        .invokeMapMethod<String, Object?>('inspect', {'playerId': playerId})
        .timeout(const Duration(seconds: 3));
    return result ?? const {};
  }

  Future<Map<String, Object?>?> captureFrame() =>
      _methods.invokeMapMethod<String, Object?>('captureFrame', {
        'playerId': playerId,
      });

  Future<void> dispose() =>
      _methods.invokeMethod<void>('dispose', {'playerId': playerId});
}
