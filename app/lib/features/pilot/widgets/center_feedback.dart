import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/proto.dart' as pb;
import 'controls.dart';

const standColor = Color(0xFF3DDC97);
const gestureColor = Color(0xFFC77DFF);

/// Name and icon of each gesture, shared by the buttons and the feedback.
const gestureTexts = {
  pb.Gesture.GESTURE_WAVE: ('Acenar', Icons.waving_hand_rounded),
  pb.Gesture.GESTURE_GUARD: ('Guarda', Icons.shield_rounded),
  pb.Gesture.GESTURE_STRIKE: ('Golpe', Icons.flash_on_rounded),
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

  @override
  void dispose() {
    _stoodTimer?.cancel();
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

    final hold = ref.watch(standHoldProvider);
    final requested = ref.watch(controlProvider.select((c) => c.standRequested));
    final gesture = ref.watch(gestureFeedbackProvider);

    final Widget? card;
    if (hold > 0) {
      card = _Card(
        key: const ValueKey('hold'),
        color: standColor,
        icon: Icons.keyboard_double_arrow_up_rounded,
        progress: hold,
        title: 'Levantar',
        subtitle: 'Continue segurando',
      );
    } else if (requested) {
      card = const _Card(
        key: ValueKey('standing'),
        color: standColor,
        icon: Icons.keyboard_double_arrow_up_rounded,
        progress: null, // spinning: waiting for the robot
        title: 'Levantando…',
        subtitle: 'Aguarde o robô ficar em pé',
      );
    } else if (_stood) {
      card = const _Card(
        key: ValueKey('stood'),
        color: standColor,
        icon: Icons.check_rounded,
        progress: 1,
        title: 'Em pé',
      );
    } else if (gesture != null && gestureTexts[gesture] != null) {
      final (label, icon) = gestureTexts[gesture]!;
      card = _Card(key: ValueKey(gesture), color: gestureColor, icon: icon, progress: 1, title: label);
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
