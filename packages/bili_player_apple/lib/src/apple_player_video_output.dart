import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bili_player/bili_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'apple_player_channel.dart';

/// One AVPlayerLayer-backed Flutter surface. The native layer is owned by the
/// player session, not by this widget, so inline/fullscreen/mini can rebind it.
final class ApplePlayerVideoOutput
    implements FlutterVideoOutput, VideoFrameReadiness, NativeVideoFrameCapture {
  ApplePlayerVideoOutput({required this.playerId});

  final int playerId;
  final ValueNotifier<bool> _frameReady = ValueNotifier<bool>(false);
  ApplePlayerChannel? _channel;
  Object? _owner;
  bool _disposed = false;

  void bindChannel(ApplePlayerChannel channel) {
    _channel = channel;
  }

  bool get isAttached => _owner != null;

  void markSourceChanged() {
    if (_disposed) return;
    _frameReady.value = false;
  }

  void markFrameReady() {
    if (_disposed) return;
    _frameReady.value = true;
  }

  @override
  ValueListenable<bool> get frameReady => _frameReady;

  @override
  void attach(Object owner) {
    _owner = owner;
  }

  @override
  void updateViewport(
    Object owner, {
    required double logicalWidth,
    required double logicalHeight,
    required double devicePixelRatio,
  }) {
    // The native AVPlayerLayer uses resizeAspect inside its own view.
  }

  @override
  void detach(Object owner) {
    if (identical(_owner, owner)) _owner = null;
  }

  @override
  Widget buildVideoSurface() {
    // The engine starts with a placeholder output before a backend exists.
    // Never create a platform view for it: the real player id arrives later
    // and a keyed rebuild guarantees the native factory receives it.
    if (playerId < 0) return const ColoredBox(color: Color(0xFF000000));
    return ColoredBox(
      color: const Color(0xFF000000),
      child: UiKitView(
        key: ValueKey<int>(playerId),
        viewType: 'bilisail/apple_player_surface',
        creationParams: {'playerId': playerId},
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
    );
  }

  @override
  Future<ui.Image?>? captureNativeFrame() async {
    final channel = _channel;
    if (channel == null || _disposed) return null;
    final frame = await channel.captureFrame();
    if (frame == null || _disposed) return null;
    final bytes = frame['bytes'];
    final width = frame['width'];
    final height = frame['height'];
    if (bytes is! Uint8List || width is! int || height is! int) return null;
    if (width <= 0 || height <= 0) return null;
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromPixels(
      bytes,
      width,
      height,
      ui.PixelFormat.bgra8888,
      (image) {
        if (!completer.isCompleted) completer.complete(image);
      },
    );
    return completer.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner = null;
    _frameReady.dispose();
  }
}
