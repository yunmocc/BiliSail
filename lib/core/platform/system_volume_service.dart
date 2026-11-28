import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Drives the real device output volume. iOS has no per-app volume API, so the
/// platform side moves the system slider exactly like the hardware buttons.
class SystemVolumeService {
  static const _channel = MethodChannel('bilisail/system_volume');

  bool get isNative => Platform.isIOS;

  Future<double> read() async {
    final value = await _channel
        .invokeMethod<double>('get')
        .timeout(const Duration(seconds: 2));
    if (value == null || !value.isFinite || value < 0 || value > 1) {
      throw const FormatException('Invalid system volume');
    }
    return value;
  }

  Future<void> set(double value) {
    if (!value.isFinite) throw const FormatException('Invalid system volume');
    return _channel
        .invokeMethod<void>('set', {'value': value.clamp(0.0, 1.0)})
        .timeout(const Duration(seconds: 2));
  }
}
