import 'dart:async';

import 'package:bili_player/bili_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the display awake while a video surface is on screen.
///
/// iOS applies the system auto-lock timer to any app that does not opt out, so
/// a video watched without touching the screen turns the panel off after the
/// interval configured in Settings. media-kit's `Video` widget opts out on its
/// own, but the native texture output - the default backend on iOS - paints a
/// bare `Texture` and never reaches that widget, so nothing disables the idle
/// timer on that path and playback goes dark.
///
/// Holding the lock here covers both backends because every surface, including
/// the fullscreen route, the mini player and the card preview, is composed
/// through the adapter below.
///
/// The holder count matters: entering fullscreen mounts a second surface before
/// the page underneath detaches, and releasing on the first dispose would drop
/// the request exactly while the video is still playing.
class ScreenWakelock extends StatefulWidget {
  const ScreenWakelock({super.key, required this.child});

  final Widget child;

  static int _holders = 0;

  static void _acquire() {
    if (_holders++ > 0) return;
    unawaited(WakelockPlus.enable().catchError(_ignoreWakelockFailure));
  }

  static void _release() {
    if (_holders == 0) return;
    if (--_holders > 0) return;
    unawaited(WakelockPlus.disable().catchError(_ignoreWakelockFailure));
  }

  static void _ignoreWakelockFailure(Object error) {
    // A platform without the plugin must not break playback; the screen simply
    // keeps its system timing.
    debugPrint('Screen wakelock unavailable: ${error.runtimeType}');
  }

  @override
  State<ScreenWakelock> createState() => _ScreenWakelockState();
}

class _ScreenWakelockState extends State<ScreenWakelock> {
  @override
  void initState() {
    super.initState();
    ScreenWakelock._acquire();
  }

  @override
  void dispose() {
    ScreenWakelock._release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Composes the video surface and holds the display awake while it is mounted.
final class WakelockVideoCompositionAdapter
    implements VideoCompositionAdapter {
  const WakelockVideoCompositionAdapter(this.inner);

  final VideoCompositionAdapter inner;

  @override
  Widget buildVideoSurface(BuildContext context, VideoOutput output) =>
      ScreenWakelock(child: inner.buildVideoSurface(context, output));

  @override
  Widget compose(BuildContext context, {required List<Widget> layers}) =>
      inner.compose(context, layers: layers);
}
