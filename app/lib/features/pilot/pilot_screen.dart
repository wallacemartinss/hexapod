import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/control/control_state.dart';
import '../../core/link/robot_link.dart';
import '../../core/proto.dart' as pb;
import '../../core/providers.dart';
import '../settings/settings_sheet.dart';
import 'state_texts.dart';
import 'widgets/controls.dart';
import 'widgets/floating_joystick.dart';
import 'widgets/hud.dart';

/// Robot states in which it can move under the sticks.
const _moving = {pb.State.STATE_NORMAL, pb.State.STATE_BLOCKED};

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

  @override
  void initState() {
    super.initState();
    // Re-evaluate staleness even when no telemetry arrives.
    _clock = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(commandLoopProvider); // keeps the 20 Hz command stream alive
    ref.listen(telemetryProvider, (_, _) => _lastTelemetry = DateTime.now());

    final settings = ref.watch(settingsProvider);
    final control = ref.watch(controlProvider);
    final controller = ref.read(controlProvider.notifier);
    final link = ref.watch(linkStatusProvider).value ?? LinkStatus.connecting;
    final telemetry = ref.watch(telemetryProvider).value;
    final age = _lastTelemetry == null ? null : DateTime.now().difference(_lastTelemetry!);
    final fresh = link == LinkStatus.connected && age != null && age < const Duration(seconds: 1);
    final lost = link != LinkStatus.connected || age == null || age > const Duration(seconds: 3);

    final robotState = fresh ? telemetry?.state : null;
    final canMove = robotState != null && _moving.contains(robotState) && !control.estop;
    final needsStand = control.estop || (robotState != null && !_moving.contains(robotState));
    final standing = robotState != null && _moving.contains(robotState);
    final banner = robotState == null ? null : describeState(robotState);
    final sticksLive = canMove && control.scheme != Scheme.sit && !control.standRequested;

    final (leftText, rightText) = _stickTexts[control.scheme]!;
    void onLeft(Stick s) =>
        settings.swapSticks ? controller.setSticks(right: s) : controller.setSticks(left: s);
    void onRight(Stick s) =>
        settings.swapSticks ? controller.setSticks(left: s) : controller.setSticks(right: s);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: ref.watch(videoViewProvider)(settings.whepUri)),

          // Stick areas first: buttons drawn later win the taps.
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

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Stack(
                children: [
                  StatusBar(
                    link: link,
                    telemetry: fresh ? telemetry : null,
                    telemetryAge: age,
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
                  if (banner != null && banner.severity != Severity.ok && !lost)
                    Positioned(
                      top: 84,
                      left: 0,
                      right: 0,
                      child: Center(child: StateBanner(text: banner)),
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
                    child: HeightSlider(
                      value: control.bodyHeight,
                      enabled: standing,
                      onChanged: controller.setBodyHeight,
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (control.scheme == Scheme.legs) ...[
                          _GestureRow(
                            enabled: canMove,
                            haptics: settings.haptics,
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
                          onScheme: controller.setScheme,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (lost) _ConnectionOverlay(host: settings.host, status: link),
        ],
      ),
    );
  }

  void _showFaults(BuildContext context, pb.Telemetry? t) {
    final faults = t == null ? const <String>[] : describeFaults(t.faultFlags);
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

class _ModeRail extends StatelessWidget {
  const _ModeRail({
    required this.scheme,
    required this.standing,
    required this.needsStand,
    required this.haptics,
    required this.onSit,
    required this.onStand,
    required this.onScheme,
  });

  final Scheme scheme;
  final bool standing;
  final bool needsStand;
  final bool haptics;
  final VoidCallback onSit;
  final VoidCallback onStand;
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
  const _GestureRow({required this.enabled, required this.haptics, required this.onGesture});

  final bool enabled;
  final bool haptics;
  final ValueChanged<pb.Gesture> onGesture;

  @override
  Widget build(BuildContext context) {
    Widget item(String label, IconData icon, pb.Gesture g) => Padding(
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
          child: Glass(
            radius: 14,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        item('Acenar', Icons.waving_hand_rounded, pb.Gesture.GESTURE_WAVE),
        item('Guarda', Icons.shield_rounded, pb.Gesture.GESTURE_GUARD),
        item('Golpe', Icons.flash_on_rounded, pb.Gesture.GESTURE_STRIKE),
      ],
    );
  }
}

class _ConnectionOverlay extends StatelessWidget {
  const _ConnectionOverlay({required this.host, required this.status});

  final String host;
  final LinkStatus status;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.45),
        alignment: Alignment.center,
        child: Glass(
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5)),
              const SizedBox(height: 14),
              const Text(
                'Sem conexão com o robô',
                style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                status == LinkStatus.connected
                    ? 'Conectado ao hexd, aguardando o ESP32…'
                    : 'Procurando $host…',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: () => showSettingsSheet(context),
                icon: const Icon(Icons.tune_rounded),
                label: const Text('Ajustes de conexão'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
