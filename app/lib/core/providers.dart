import 'dart:async';

import 'package:flutter/widgets.dart' show Widget;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/video/video_view.dart';

import 'control/command_mapper.dart';
import 'control/control_state.dart';
import 'link/host_resolver.dart';
import 'link/robot_link.dart';
import 'proto.dart';
import 'settings.dart';

/// Commands per second, also when the sticks are idle (dead man's switch:
/// hexd and the ESP32 stop the robot when they stop arriving).
const commandRate = Duration(milliseconds: 50);

/// How long a gesture stays in the commands before returning to none.
const gesturePulse = Duration(milliseconds: 300);

final settingsProvider = NotifierProvider<SettingsNotifier, Settings>(SettingsNotifier.new);

class SettingsNotifier extends Notifier<Settings> {
  /// [initial]: the values saved on the phone (main.dart loads them).
  SettingsNotifier([this._initial]);

  final Settings? _initial;

  @override
  Settings build() => _initial ?? const Settings();

  Future<void> update(Settings s) async {
    state = s;
    await s.save();
  }
}

/// The robot's address: the configured host resolved (mDNS fallback for
/// `.local` on phones that do not resolve it). Raw host until resolved.
final robotAddressProvider = FutureProvider<String>((ref) {
  return resolveHost(ref.watch(settingsProvider.select((s) => s.host)));
});

String _address(Ref ref) =>
    ref.watch(robotAddressProvider).value ?? ref.watch(settingsProvider.select((s) => s.host));

/// The link follows the configured host: changing it reconnects.
final linkProvider = Provider<RobotLink>((ref) {
  // Only the address and port matter: other settings must not reconnect.
  final port = ref.watch(settingsProvider.select((s) => s.port));
  final uri = Uri(scheme: 'ws', host: _address(ref), port: port, path: '/ws');
  final link = RobotLink(uri);
  unawaited(link.start());
  ref.onDispose(link.close);
  return link;
});

final linkStatusProvider = StreamProvider<LinkStatus>((ref) {
  final link = ref.watch(linkProvider);
  return link.status;
});

final telemetryProvider = StreamProvider<Telemetry>((ref) => ref.watch(linkProvider).telemetry);

final helloProvider = StreamProvider<Hello>((ref) async* {
  final link = ref.watch(linkProvider);
  final last = link.lastHello;
  if (last != null) yield last;
  yield* link.hello;
});

/// One GPS position as it arrived. Not comparable on purpose: every arrival
/// notifies, even an identical position, which tells the GPS is still talking.
class GpsReading {
  GpsReading(this.position);

  final Position position;
}

final positionProvider = StreamProvider<GpsReading>((ref) async* {
  final link = ref.watch(linkProvider);
  final last = link.lastPosition;
  if (last != null) yield GpsReading(last);
  yield* link.position.map(GpsReading.new);
});

final controlProvider = NotifierProvider<ControlNotifier, ControlState>(ControlNotifier.new);

class ControlNotifier extends Notifier<ControlState> {
  Timer? _gestureTimer;

  @override
  ControlState build() {
    ref.onDispose(() => _gestureTimer?.cancel());
    return const ControlState();
  }

  /// Current intent, for input devices (gamepad) that apply the screen's rules.
  ControlState get current => state;

  void setSticks({Stick? left, Stick? right}) {
    if (state.estop) return; // stopped: sticks stay centered until a stand
    state = state.copyWith(left: left, right: right);
  }

  void releaseSticks() => state = state.copyWith(left: Stick.zero, right: Stick.zero);

  /// Changing scheme always recenters the sticks: no motion carries over.
  void setScheme(Scheme scheme) =>
      state = state.copyWith(scheme: scheme, left: Stick.zero, right: Stick.zero, standRequested: false);

  void setBodyHeight(double v) => state = state.copyWith(bodyHeight: v.clamp(0.0, 1.0));

  void setGait(Gait g) => state = state.copyWith(gait: g);

  /// Emergency stop: latched until [stand].
  void stop() => state = state.copyWith(estop: true, left: Stick.zero, right: Stick.zero);

  /// Hold-to-stand finished: clears the estop, sends MODE_STAND (which also
  /// releases the robot from a failsafe state) and leaves the robot standing.
  void stand() => state = state.copyWith(
    estop: false,
    standRequested: true,
    scheme: Scheme.pose,
    left: Stick.zero,
    right: Stick.zero,
  );

  /// The robot confirmed it is up: back to normal commands.
  void standDone() => state = state.copyWith(standRequested: false);

  void sit() => state = state.copyWith(scheme: Scheme.sit, standRequested: false);

  void gesture(Gesture g) {
    _gestureTimer?.cancel();
    state = state.copyWith(gesture: g);
    _gestureTimer = Timer(gesturePulse, () {
      state = state.copyWith(gesture: Gesture.GESTURE_UNSPECIFIED);
    });
  }
}

/// Progress (0..1) of a hold-to-stand in course, on the screen or on the
/// gamepad: the finger covers the button, so the screen center shows it.
final standHoldProvider = NotifierProvider<StandHold, double>(StandHold.new);

class StandHold extends Notifier<double> {
  @override
  double build() => 0;

  void set(double progress) {
    if (progress != state) state = progress;
  }
}

/// How long the screen shows which gesture was sent.
const gestureShown = Duration(milliseconds: 1500);

/// The gesture just sent (from the screen or the gamepad), for [gestureShown];
/// null otherwise.
final gestureFeedbackProvider = NotifierProvider<GestureFeedback, Gesture?>(GestureFeedback.new);

class GestureFeedback extends Notifier<Gesture?> {
  Timer? _timer;

  @override
  Gesture? build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(controlProvider.select((c) => c.gesture), (_, g) {
      if (g == Gesture.GESTURE_UNSPECIFIED) return;
      state = g;
      _timer?.cancel();
      _timer = Timer(gestureShown, () => state = null);
    });
    return null;
  }
}

/// Sends the current command at [commandRate] while the app runs.
final commandLoopProvider = Provider<void>((ref) {
  final link = ref.watch(linkProvider);
  final mapper = CommandMapper(ref.watch(settingsProvider.select((s) => s.shaping)));
  final timer = Timer.periodic(commandRate, (_) {
    final control = ref.read(controlProvider);
    link.send(mapper.map(control));
  });
  ref.onDispose(timer.cancel);

  // Leave the "standing up" command once the robot reports it is back.
  ref.listen(telemetryProvider, (_, next) {
    final t = next.value;
    final control = ref.read(controlProvider);
    if (control.standRequested && t != null && t.state == State.STATE_NORMAL) {
      ref.read(controlProvider.notifier).standDone();
    }
  });
});

/// Builds the camera view. Tests replace it (WebRTC needs the native plugin).
final videoViewProvider = Provider<Widget Function(Uri whep)>(
  (ref) =>
      (uri) => VideoView(uri: uri),
);

/// Camera and microphone endpoints for the resolved address.
final mediaUrisProvider = Provider<({Uri video, Uri mic})>((ref) {
  final s = ref.watch(settingsProvider);
  final address = _address(ref);
  return (video: s.whepUri(address), mic: s.micUri(address));
});
