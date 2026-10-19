import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/input/gamepad_service.dart';
import '../../../core/providers.dart';
import '../../../core/proto.dart' as pb;
import '../../../l10n/l10n.dart';
import 'controls.dart';

const standColor = Color(0xFF3DDC97);
const gestureColor = Color(0xFFC77DFF);

/// Icon of each gesture (in button order), shared by the buttons and the feedback.
const gestureIcons = {
  pb.Gesture.GESTURE_WAVE: Icons.waving_hand_rounded,
  pb.Gesture.GESTURE_GUARD: Icons.shield_rounded,
  pb.Gesture.GESTURE_STRIKE: Icons.flash_on_rounded,
};

/// Name of each gesture, shared by the buttons and the feedback.
String gestureLabel(AppLocalizations l, pb.Gesture g) => switch (g) {
  pb.Gesture.GESTURE_WAVE => l.pilotGestureWave,
  pb.Gesture.GESTURE_GUARD => l.pilotGestureGuard,
  pb.Gesture.GESTURE_STRIKE => l.pilotGestureStrike,
  _ => '',
};

/// Feedback in the middle of the screen for actions whose button sits under
/// the finger: the hold-to-stand progress (screen or gamepad), the stand
/// itself, and the gesture just sent. Never takes touches.
class CenterFeedback extends ConsumerStatefulWidget {
  const CenterFeedback({super.key});

  @override
  ConsumerState<CenterFeedback> createState() => _CenterFeedbackState();
}

class _CenterFeedbackState extends ConsumerState<CenterFeedback> {
  bool _stood = false;
  Timer? _stoodTimer;

  /// Gamepad just connected (name) or disconnected (''), shown for a moment.
  String? _pad;
  Timer? _padTimer;

  @override
  void dispose() {
    _stoodTimer?.cancel();
    _padTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Stand request answered by the robot: say so for a moment.
    ref.listen(controlProvider.select((c) => c.standRequested), (was, now) {
      final up = ref.read(telemetryProvider).value?.state == pb.State.STATE_NORMAL;
      if (was == true && !now && up) {
        setState(() => _stood = true);
        _stoodTimer?.cancel();
        _stoodTimer = Timer(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _stood = false);
        });
      }
    });

    ref.listen(gamepadNameProvider, (was, now) {
      if ((was == null) == (now == null)) return;
      setState(() => _pad = now ?? '');
      _padTimer?.cancel();
      _padTimer = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => _pad = null);
      });
    });

    final hold = ref.watch(standHoldProvider);
    final requested = ref.watch(controlProvider.select((c) => c.standRequested));
    final gesture = ref.watch(gestureFeedbackProvider);

    final l = context.l10n;
    final Widget? card;
    if (hold > 0) {
      card = _Card(
        key: const ValueKey('hold'),
        color: standColor,
        icon: Icons.keyboard_double_arrow_up_rounded,
        progress: hold,
        title: l.pilotStandUp,
        subtitle: l.pilotKeepHolding,
      );
    } else if (requested) {
      card = _Card(
        key: const ValueKey('standing'),
        color: standColor,
        icon: Icons.keyboard_double_arrow_up_rounded,
        progress: null, // spinning: waiting for the robot
        title: l.pilotStandingUp,
        subtitle: l.pilotStandingUpWait,
      );
    } else if (_stood) {
      card = _Card(
        key: const ValueKey('stood'),
        color: standColor,
        icon: Icons.check_rounded,
        progress: 1,
        title: l.pilotStood,
      );
    } else if (_pad != null) {
      card = _pad!.isEmpty
          ? _Card(
              key: const ValueKey('pad-off'),
              color: const Color(0xFFFFB020),
              icon: Icons.sports_esports_rounded,
              progress: 1,
              title: l.pilotPadDisconnected,
              subtitle: l.pilotPadDisconnectedText,
            )
          : _Card(
              key: const ValueKey('pad-on'),
              color: standColor,
              icon: Icons.sports_esports_rounded,
              progress: 1,
              title: l.pilotPadConnected,
              subtitle: _pad,
            );
    } else if (gesture != null && gestureIcons[gesture] != null) {
      card = _Card(
        key: ValueKey(gesture),
        color: gestureColor,
        icon: gestureIcons[gesture]!,
        progress: 1,
        title: gestureLabel(l, gesture),
      );
    } else {
      card = null;
    }

    return IgnorePointer(
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(a), child: child),
          ),
          child: card ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    super.key,
    required this.color,
    required this.icon,
    required this.progress,
    required this.title,
    this.subtitle,
  });

  final Color color;
  final IconData icon;

  /// Ring fill 0..1; null spins.
  final double? progress;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Glass(
      radius: 24,
      padding: const EdgeInsets.fromLTRB(28, 20, 28, 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 76,
            height: 76,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 6,
                  color: color,
                  backgroundColor: Colors.white12,
                ),
                Icon(icon, color: color, size: 36),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}
