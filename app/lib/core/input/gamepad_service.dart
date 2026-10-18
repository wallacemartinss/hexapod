import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gamepads/gamepads.dart';

import '../control/control_state.dart';
import '../link/robot_link.dart';
import '../proto.dart' as pb;
import '../providers.dart';
import 'controller_feedback.dart';
import 'controller_platform.dart';
import 'gamepad_interpreter.dart';

/// Name of the connected gamepad, or null.
final gamepadNameProvider = NotifierProvider<GamepadName, String?>(GamepadName.new);

class GamepadName extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? name) => state = name;
}

/// The controller's light, motors and sensors (no-op off Android; tests
/// override it).
final controllerPlatformProvider = Provider<ControllerPlatform?>(
  (ref) => Platform.isAndroid ? AndroidControllerPlatform() : null,
);

/// Gamepad input + feedback while the app runs. Watched by the pilot screen.
final gamepadServiceProvider = Provider<GamepadInterpreter>((ref) {
  final platform = ref.watch(controllerPlatformProvider);
  final names = ref.read(gamepadNameProvider.notifier);
  final subs = <StreamSubscription<Object?>>[];
  String? padId;
  bool? padRumbles;

  Future<void> rumble(Rumble r) async {
    final id = padId;
    if (platform == null || id == null) return;
    padRumbles ??= await platform.hasRumble(id);
    if (padRumbles!) unawaited(platform.rumble(id, r));
  }

  final interpreter = GamepadInterpreter(ref.read(controlProvider.notifier), onRumble: rumble);

  StreamSubscription<MotionSample>? motion;
  void listenMotion() {
    if (platform == null) return;
    motion?.cancel(); // one subscription, renewed for each pad
    motion = platform.motion().listen(interpreter.onMotion);
  }

  Future<void> refresh() async {
    try {
      final pads = await Gamepads.list();
      names.set(pads.isEmpty ? null : pads.first.name);
      if (pads.isNotEmpty) {
        padId ??= pads.first.id;
        listenMotion(); // sensors belong to the pad: (re)subscribe on connect
      }
    } catch (_) {
      names.set(null); // platform without gamepad support
    }
  }

  try {
    subs.add(
      Gamepads.normalizedEvents.listen((e) {
        if (e.gamepadId != padId) {
          padId = e.gamepadId;
          padRumbles = null;
        }
        final axis = e.axis;
        final button = e.button;
        if (axis != null) interpreter.onAxis(axis, e.value);
        if (button != null) interpreter.onButton(button, e.value > 0.5);
      }),
    );
    subs.add(Gamepads.onConnected.listen((_) => refresh()));
    subs.add(
      Gamepads.onDisconnected.listen((_) {
        interpreter.disconnected();
        padId = null;
        padRumbles = null;
        refresh();
      }),
    );
  } catch (_) {
    // no plugin (tests): the interpreter still works, nothing feeds it
  }
  // After this provider is built: refresh() updates gamepadNameProvider.
  Future.microtask(refresh);

  // --- feedback on the pad: rumble patterns and the light bar ---
  ref.listen(controlProvider.select((c) => c.estop), (was, now) {
    if (now && was != true) rumble(Rumble.stop); // from the screen or the pad
  });
  ref.listen(linkStatusProvider, (prev, next) {
    if (prev?.value == LinkStatus.connected && next.value != LinkStatus.connected) {
      rumble(Rumble.linkLost);
    }
  });
  var lastObstacle = DateTime(0);
  ref.listen(telemetryProvider, (prev, next) {
    final t = next.value;
    if (t == null) return;
    if (t.state != prev?.value?.state && alarmStates.contains(t.state)) rumble(Rumble.alarm);
    final walking = ref.read(controlProvider).scheme == Scheme.walk;
    final moving = t.state == pb.State.STATE_NORMAL || t.state == pb.State.STATE_BLOCKED;
    final buzz = walking && moving && t.distancesMm.isNotEmpty ? Rumble.obstacle(t.distancesMm.first) : null;
    final now = DateTime.now();
    if (buzz != null && now.difference(lastObstacle) > const Duration(milliseconds: 200)) {
      lastObstacle = now;
      rumble(buzz);
    }
  });

  int? lastColor;
  void updateLight() {
    if (platform == null) return;
    final control = ref.read(controlProvider);
    final telemetry = ref.read(telemetryProvider).value;
    final color = lightColor(
      connected: ref.read(linkStatusProvider).value == LinkStatus.connected,
      estop: control.estop,
      state: telemetry?.state,
      scheme: control.scheme,
    );
    if (color != lastColor) {
      lastColor = color;
      unawaited(platform.setLight(color));
    }
  }

  ref.listen(controlProvider, (_, _) => updateLight());
  ref.listen(telemetryProvider, (_, _) => updateLight());
  ref.listen(linkStatusProvider, (_, _) => updateLight());
  ref.listen(gamepadNameProvider, (_, _) {
    lastColor = null; // a newly paired pad needs the color again
    updateLight();
  });

  final timer = Timer.periodic(commandRate, (_) => interpreter.tick(commandRate));
  ref.onDispose(() {
    timer.cancel();
    motion?.cancel();
    for (final s in subs) {
      s.cancel();
    }
  });
  return interpreter;
});
