import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gamepads/gamepads.dart';

import '../providers.dart';
import 'gamepad_interpreter.dart';

/// Name of the connected gamepad, or null.
final gamepadNameProvider = NotifierProvider<GamepadName, String?>(GamepadName.new);

class GamepadName extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? name) => state = name;
}

/// Feeds the plugin's normalized events into a [GamepadInterpreter] while the
/// app runs. Watched by the pilot screen.
final gamepadServiceProvider = Provider<GamepadInterpreter>((ref) {
  final interpreter = GamepadInterpreter(ref.read(controlProvider.notifier));
  final names = ref.read(gamepadNameProvider.notifier);
  final subs = <StreamSubscription<Object?>>[];

  Future<void> refresh() async {
    try {
      final pads = await Gamepads.list();
      names.set(pads.isEmpty ? null : pads.first.name);
    } catch (_) {
      names.set(null); // platform without gamepad support
    }
  }

  try {
    subs.add(
      Gamepads.normalizedEvents.listen((e) {
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
        refresh();
      }),
    );
  } catch (_) {
    // no plugin (tests): the interpreter still works, nothing feeds it
  }
  unawaited(refresh());

  final timer = Timer.periodic(commandRate, (_) => interpreter.tick(commandRate));
  ref.onDispose(() {
    timer.cancel();
    for (final s in subs) {
      s.cancel();
    }
  });
  return interpreter;
});
