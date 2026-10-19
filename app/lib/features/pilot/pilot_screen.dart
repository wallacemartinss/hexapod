import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/control/control_state.dart';
import '../../core/input/gamepad_service.dart';
import '../../core/link/robot_link.dart';
import '../../core/proto.dart' as pb;
import '../../core/providers.dart';
import '../../core/robots.dart';
import '../data/data_screen.dart';
import '../robots/pair_screen.dart';
import '../robots/robots_sheet.dart';
import '../settings/controller_sheet.dart';
import '../settings/settings_sheet.dart';
import '../video/robot_audio.dart';
import 'state_texts.dart';
import '../../l10n/l10n.dart';
import 'widgets/center_feedback.dart';
import 'widgets/controls.dart';
import 'widgets/floating_joystick.dart';
import 'widgets/hud.dart';

/// Robot states in which it can move under the sticks.
const _moving = {pb.State.STATE_NORMAL, pb.State.STATE_BLOCKED};

/// States worth a strong vibration when they start: the pilot may be looking
/// at the robot, not at the phone.
const _alarms = {
  pb.State.STATE_STOPPING,
  pb.State.STATE_SAFE_SIT,
  pb.State.STATE_TIPPED,
  pb.State.STATE_LOW_BATTERY,
  pb.State.STATE_ESTOP,
  pb.State.STATE_BLOCKED,
};

/// What each stick does, per scheme: (label, hint).
const _stickTexts = {
  Scheme.sit: (('Sentado', null), ('Sentado', null)),
  Scheme.pose: (('Inclinar', 'para os lados e frente/trás'), ('Torcer', 'gira o corpo no lugar')),
  Scheme.walk: (('Andar', 'frente, trás e lados'), ('Girar · olhar', 'gira e inclina a câmera')),
  Scheme.legs: (
    ('Pata esquerda', 'cima levanta · fora estica'),
    ('Pata direita', 'cima levanta · fora estica'),
  ),
};

class PilotScreen extends ConsumerStatefulWidget {
  const PilotScreen({super.key});

  @override
  ConsumerState<PilotScreen> createState() => _PilotScreenState();
}

class _PilotScreenState extends ConsumerState<PilotScreen> {
  DateTime? _lastTelemetry;
  late final Timer _clock;
  bool _wasLost = true;

  /// While the robot is lost, look for it again on the network now and then
  /// (it may have changed address or network).
  DateTime? _rediscoverAt;

  /// Height slider and mode bar stay on screen for this long after the last
  /// tap (counted down by [_clock], see [_revealBars]).
  Duration _barsLeft = _barsShownFor;
  static const _barsShownFor = Duration(seconds: 5);
  static const _tick = Duration(milliseconds: 250);

  /// Where and when the current touch started, to tell a tap from a drag.
  Offset? _downAt;
  DateTime? _downTime;

  void _revealBars() => _barsLeft = _barsShownFor;

  void _onPointerDown(PointerDownEvent e) {
    _downAt = e.position;
    _downTime = DateTime.now();
  }

  void _onPointerUp(PointerUpEvent e) {
    final at = _downAt, time = _downTime;
    if (at == null || time == null) return;
    final quick = DateTime.now().difference(time) < const Duration(milliseconds: 300);
    if (quick && (e.position - at).distance < 16) setState(_revealBars); // a tap, not a stick
  }

  @override
  void initState() {
    super.initState();
    // Re-evaluate staleness even when no telemetry arrives.
    _clock = Timer.periodic(_tick, (_) => setState(() => _barsLeft -= _tick));
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(commandLoopProvider); // keeps the 20 Hz command stream alive
    ref.watch(gamepadServiceProvider); // PS5 / Bluetooth gamepad, if any
    ref.listen(telemetryProvider, (prev, next) {
      _lastTelemetry = DateTime.now();
      final before = prev?.value?.state;
      final now = next.value?.state;
      if (now != null && now != before && _alarms.contains(now) && ref.read(settingsProvider).haptics) {
        HapticFeedback.heavyImpact();
      }
      if (gasAlarmOn(next.value) && !gasAlarmOn(prev?.value) && ref.read(settingsProvider).haptics) {
        HapticFeedback.vibrate(); // gas: a long buzz, unlike any state change
      }
    });

    // A mode change (also from the PS5 pad) shows the bars again.
    ref.listen(controlProvider.select((c) => c.scheme), (_, _) => _revealBars());

    final settings = ref.watch(settingsProvider);
    final robots = ref.watch(robotsProvider);
    final media = ref.watch(mediaUrisProvider);
    final gamepad = ref.watch(gamepadNameProvider);
    final control = ref.watch(controlProvider);
    final controller = ref.read(controlProvider.notifier);
    final link = ref.watch(linkStatusProvider).value ?? LinkStatus.connecting;
    final telemetry = ref.watch(telemetryProvider).value;
    final age = _lastTelemetry == null ? null : DateTime.now().difference(_lastTelemetry!);
    final fresh = link == LinkStatus.connected && age != null && age < const Duration(seconds: 1);
    final lost = link != LinkStatus.connected || age == null || age > const Duration(seconds: 3);
    if (lost && !_wasLost && settings.haptics) HapticFeedback.vibrate(); // signal just dropped
    if (lost && robots.active != null) {
      final now = DateTime.now();
      if (_rediscoverAt == null) {
        _rediscoverAt = now.add(const Duration(seconds: 15));
      } else if (now.isAfter(_rediscoverAt!)) {
        _rediscoverAt = now.add(const Duration(seconds: 15));
        Future.microtask(() => ref.invalidate(robotAddressProvider));
      }
    } else {
      _rediscoverAt = null;
    }
    _wasLost = lost;

    final robotState = fresh ? telemetry?.state : null;
    final canMove = robotState != null && _moving.contains(robotState) && !control.estop;
    final needsStand = control.estop || (robotState != null && !_moving.contains(robotState));
    final standing = robotState != null && _moving.contains(robotState);
    final banner = robotState == null ? null : describeState(context.l10n, robotState);
    final sticksLive = canMove && control.scheme != Scheme.sit && !control.standRequested;

    // The height slider and the mode bar hide only while actually piloting;
    // anything that needs the pilot (seated, alerts, no link) keeps them on
    // screen. Seated also reports a NORMAL state, hence the scheme check. The
    // status bar on top never hides.
    final barsPinned =
        !settings.autoHideBars || lost || !canMove || control.scheme == Scheme.sit || control.standRequested;
    if (barsPinned) _revealBars(); // full time again once piloting starts
    final barsVisible = barsPinned || _barsLeft > Duration.zero;

    // A connected gamepad drives: the screen sticks step aside (STOP stays),
    // and come back the moment the pad disconnects.
    final padDriving = gamepad != null && settings.hideSticksWithPad;

    final (leftText, rightText) = _stickTexts[control.scheme]!;
    void onLeft(Stick s) =>
        settings.swapSticks ? controller.setSticks(right: s) : controller.setSticks(left: s);
    void onRight(Stick s) =>
        settings.swapSticks ? controller.setSticks(left: s) : controller.setSticks(right: s);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        child: Stack(
          children: [
            Positioned.fill(child: ref.watch(videoViewProvider)(media.video)),
            if (settings.robotAudio) RobotAudio(uri: media.mic),

            // Stick areas first: buttons drawn later win the taps.
            if (!padDriving) ...[
              Positioned(
                left: 0,
                top: 64,
                bottom: 0,
                width: MediaQuery.sizeOf(context).width / 2,
                child: FloatingJoystick(
                  restAlignment: const Alignment(-0.3, 0.05),
                  label: settings.swapSticks ? rightText.$1 : leftText.$1,
                  hint: settings.swapSticks ? rightText.$2 : leftText.$2,
                  enabled: sticksLive,
                  haptics: settings.haptics,
                  onChanged: onLeft,
                ),
              ),
              Positioned(
                right: 0,
                top: 64,
                bottom: 0,
                width: MediaQuery.sizeOf(context).width / 2,
                child: FloatingJoystick(
                  restAlignment: const Alignment(0.3, 0.05),
                  label: settings.swapSticks ? leftText.$1 : rightText.$1,
                  hint: settings.swapSticks ? leftText.$2 : rightText.$2,
                  enabled: sticksLive,
                  haptics: settings.haptics,
                  onChanged: onRight,
                ),
              ),
            ],
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Stack(
                  children: [
                    StatusBar(
                      link: link,
                      telemetry: fresh ? telemetry : null,
                      telemetryAge: age,
                      gamepad: gamepad,
                      onGamepad: () => showControllerSheet(context),
                      onData: () => showDataScreen(context),
                      audio: settings.robotAudio,
                      onAudio: () => ref
                          .read(settingsProvider.notifier)
                          .update(settings.copyWith(robotAudio: !settings.robotAudio)),
                      onSettings: () => showSettingsSheet(context),
                      onFaults: () => _showFaults(context, telemetry),
                    ),
                    // Obstacles at the top, out of the camera's center.
                    if (fresh && telemetry != null)
                      Align(
                        alignment: Alignment.topCenter,
                        child: ProximityRadar(
                          distancesMm: telemetry.distancesMm,
                          blockedMask: telemetry.blockedMask,
                        ),
                      ),
                    if (!lost)
                      Positioned(
                        top: 84,
                        left: 0,
                        right: 0,
                        child: Column(
                          children: [
                            // Gas first: it is not a robot state and can come with any.
                            if (fresh && gasAlarmOn(telemetry)) StateBanner(text: gasAlarmText(context.l10n)),
                            if (fresh &&
                                gasAlarmOn(telemetry) &&
                                banner != null &&
                                banner.severity != Severity.ok)
                              const SizedBox(height: 8),
                            if (banner != null && banner.severity != Severity.ok) StateBanner(text: banner),
                          ],
                        ),
                      ),
                    Align(
                      alignment: const Alignment(1, -0.35),
                      child: StopButton(
                        latched: control.estop || robotState == pb.State.STATE_ESTOP,
                        haptics: settings.haptics,
                        onPressed: controller.stop,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _AutoHide(
                        visible: barsVisible,
                        hiddenOffset: const Offset(-1.5, 0),
                        child: HeightSlider(
                          value: control.bodyHeight,
                          enabled: standing,
                          onChanged: controller.setBodyHeight,
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: _AutoHide(
                        visible: barsVisible,
                        hiddenOffset: const Offset(0, 1.5),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (control.scheme == Scheme.legs) ...[
                              _GestureRow(
                                enabled: canMove,
                                haptics: settings.haptics,
                                active: ref.watch(gestureFeedbackProvider),
                                onGesture: controller.gesture,
                              ),
                              const SizedBox(height: 8),
                            ],
                            _ModeRail(
                              scheme: control.scheme,
                              standing: standing || control.standRequested,
                              needsStand: needsStand,
                              haptics: settings.haptics,
                              onSit: controller.sit,
                              onStand: controller.stand,
                              onStandProgress: ref.read(standHoldProvider.notifier).set,
                              onScheme: controller.setScheme,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const CenterFeedback(), // over the camera, never over the alerts below
            if (lost)
              _ConnectionOverlay(
                target: robots.active?.name ?? settings.host,
                status: link,
                paired: robots.robots.isNotEmpty,
              ),
            if (!settings.onboarded)
              _Onboarding(
                onDone: () => ref.read(settingsProvider.notifier).update(settings.copyWith(onboarded: true)),
              ),
          ],
        ),
      ),
    );
  }

  void _showFaults(BuildContext context, pb.Telemetry? t) {
    final faults = t == null ? const <String>[] : describeFaults(context.l10n, t.faultFlags);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF15181D),
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Avisos do robô',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            for (final f in faults)
              ListTile(
                dense: true,
                leading: Icon(Icons.warning_amber_rounded, color: severityColor(Severity.warning)),
                title: Text(f, style: const TextStyle(color: Colors.white)),
              ),
          ],
        ),
      ),
    );
  }
}

/// Slides [child] off screen (and out of the way of touches) when not
/// [visible].
class _AutoHide extends StatelessWidget {
  const _AutoHide({required this.visible, required this.hiddenOffset, required this.child});

  final bool visible;
  final Offset hiddenOffset;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const duration = Duration(milliseconds: 250);
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : hiddenOffset,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(opacity: visible ? 1 : 0, duration: duration, child: child),
      ),
    );
  }
}

class _ModeRail extends StatelessWidget {
  const _ModeRail({
    required this.scheme,
    required this.standing,
    required this.needsStand,
    required this.haptics,
    required this.onSit,
    required this.onStand,
    required this.onStandProgress,
    required this.onScheme,
  });

  final Scheme scheme;
  final bool standing;
  final bool needsStand;
  final bool haptics;
  final VoidCallback onSit;
  final VoidCallback onStand;
  final ValueChanged<double> onStandProgress;
  final ValueChanged<Scheme> onScheme;

  @override
  Widget build(BuildContext context) {
    // Pose / walk / legs only once the robot is up: a tap must never make it
    // stand on its own (that takes the hold button).
    final upModes = scheme != Scheme.sit;
    void select(Scheme s) {
      if (!upModes) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('Segure LEVANTAR primeiro'),
              duration: Duration(milliseconds: 1500),
              behavior: SnackBarBehavior.floating,
              width: 260,
            ),
          );
        return;
      }
      onScheme(s);
    }

    return Glass(
      padding: const EdgeInsets.all(6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          RailButton(
            label: 'Sentar',
            icon: Icons.airline_seat_recline_normal_rounded,
            selected: scheme == Scheme.sit,
            haptics: haptics,
            onTap: onSit,
          ),
          const SizedBox(width: 6),
          HoldButton(
            label: 'Levantar',
            icon: Icons.keyboard_double_arrow_up_rounded,
            haptics: haptics,
            highlight: needsStand,
            onConfirmed: onStand,
            onProgress: onStandProgress,
          ),
          const SizedBox(width: 6),
          RailButton(
            label: 'Pose',
            icon: Icons.threed_rotation_rounded,
            selected: scheme == Scheme.pose,
            enabled: upModes,
            haptics: haptics,
            onTap: () => select(Scheme.pose),
          ),
          const SizedBox(width: 6),
          RailButton(
            label: 'Andar',
            icon: Icons.directions_walk_rounded,
            selected: scheme == Scheme.walk,
            enabled: upModes,
            haptics: haptics,
            onTap: () => select(Scheme.walk),
          ),
          const SizedBox(width: 6),
          RailButton(
            label: 'Patas',
            icon: Icons.back_hand_rounded,
            selected: scheme == Scheme.legs,
            enabled: upModes,
            haptics: haptics,
            onTap: () => select(Scheme.legs),
          ),
        ],
      ),
    );
  }
}

class _GestureRow extends StatelessWidget {
  const _GestureRow({
    required this.enabled,
    required this.haptics,
    required this.active,
    required this.onGesture,
  });

  final bool enabled;
  final bool haptics;

  /// The gesture just sent, highlighted for a moment.
  final pb.Gesture? active;
  final ValueChanged<pb.Gesture> onGesture;

  @override
  Widget build(BuildContext context) {
    Widget item(pb.Gesture g) {
      final (label, icon) = gestureTexts[g]!;
      final on = g == active;
      final color = on ? gestureColor : Colors.white;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: GestureDetector(
          onTap: enabled
              ? () {
                  if (haptics) HapticFeedback.mediumImpact();
                  onGesture(g);
                }
              : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: on ? gestureColor : Colors.transparent, width: 2),
              ),
              child: Glass(
                radius: 12,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: color, size: 18),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [for (final g in gestureTexts.keys) item(g)]);
  }
}

class _ConnectionOverlay extends StatelessWidget {
  const _ConnectionOverlay({required this.target, required this.status, required this.paired});

  /// What is being looked for: the paired robot's name, or the manual host.
  final String target;
  final LinkStatus status;

  /// At least one robot is paired.
  final bool paired;

  @override
  Widget build(BuildContext context) {
    final (Widget icon, String title, String text, String primary, VoidCallback onPrimary) = switch ((
      paired,
      status,
    )) {
      (false, _) => (
        const Icon(Icons.qr_code_2_rounded, size: 40, color: Color(0xFF3FCDF5)),
        'Nenhum robô pareado',
        'Ligue o robô: quando nenhum app está conectado, a tela dele mostra um QR.',
        'Parear um robô',
        () => showPairScreen(context),
      ),
      (_, LinkStatus.unauthorized) => (
        const Icon(Icons.key_off_rounded, size: 40, color: Color(0xFFFF5A5F)),
        'O robô recusou a chave',
        'A chave de pareamento mudou. Escaneie de novo o QR da tela do robô.',
        'Parear de novo',
        () => showPairScreen(context),
      ),
      _ => (
        const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5)),
        'Sem conexão com o robô',
        status == LinkStatus.connected ? 'Conectado, aguardando o ESP32…' : 'Procurando $target na rede…',
        'Meus robôs',
        () => showRobotsSheet(context),
      ),
    };
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.45),
        alignment: Alignment.center,
        child: Glass(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(height: 14),
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton(onPressed: onPrimary, child: Text(primary)),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: () => showSettingsSheet(context),
                      icon: const Icon(Icons.tune_rounded),
                      label: const Text('Ajustes'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// First-run tips: the few things a new pilot must know.
class _Onboarding extends StatelessWidget {
  const _Onboarding({required this.onDone});

  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    Widget tip(IconData icon, Color color, String title, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
                Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    );
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.6),
        alignment: Alignment.center,
        child: Glass(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
          child: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Antes de pilotar',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                tip(
                  Icons.back_hand_rounded,
                  const Color(0xFFE5383B),
                  'PARAR',
                  'Um toque corta a força dos servos na hora. No controle PS5: bolinha.',
                ),
                tip(
                  Icons.keyboard_double_arrow_up_rounded,
                  const Color(0xFF3DDC97),
                  'Segure LEVANTAR',
                  'O robô só se levanta se você segurar o botão. Também é assim que ele volta depois de um alerta.',
                ),
                tip(
                  Icons.radio_button_checked_rounded,
                  const Color(0xFF3FCDF5),
                  'Joysticks flutuantes',
                  'Toque em qualquer lugar de cada metade da tela: o joystick nasce sob o seu polegar. As barras somem enquanto você pilota; um toque rápido traz de volta.',
                ),
                tip(
                  Icons.sports_esports_rounded,
                  Colors.white,
                  'Controle PS5',
                  'Pareie no Bluetooth do celular: sticks andam, xis, quadrado e triângulo trocam o modo, L2/R2 mudam a altura.',
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(onPressed: onDone, child: const Text('Entendi')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
