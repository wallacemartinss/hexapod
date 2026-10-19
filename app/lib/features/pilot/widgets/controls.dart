import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/l10n.dart';

/// Translucent panel over the video.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.padding = const EdgeInsets.all(8), this.radius = 16});

  final Widget child;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Emergency stop: always on screen, one tap, no confirmation.
class StopButton extends StatelessWidget {
  const StopButton({super.key, required this.onPressed, this.haptics = true, this.latched = false});

  final VoidCallback onPressed;
  final bool haptics;

  /// Shows that the stop is active (the robot stays off until a stand).
  final bool latched;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: context.l10n.pilotEmergencyStop,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          if (haptics) HapticFeedback.heavyImpact();
          onPressed();
        },
        child: Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFE5383B),
            border: Border.all(color: Colors.white, width: latched ? 4 : 2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFE5383B).withValues(alpha: 0.55),
                blurRadius: latched ? 28 : 16,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            context.l10n.pilotStopButton,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 16,
              letterSpacing: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// A button that only fires after being held for [hold]; a ring shows the
/// progress. Used for actions that make the robot move on its own (standing up).
class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.onConfirmed,
    required this.label,
    required this.icon,
    this.hold = const Duration(milliseconds: 700),
    this.haptics = true,
    this.highlight = false,
    this.color = const Color(0xFF3DDC97),
    this.onProgress,
  });

  final VoidCallback onConfirmed;

  /// Hold progress 0..1, for feedback away from the finger.
  final ValueChanged<double>? onProgress;
  final String label;
  final IconData icon;
  final Duration hold;
  final bool haptics;

  /// Pulses to say "this is what you need now" (e.g. after a failsafe).
  final bool highlight;
  final Color color;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> with TickerProviderStateMixin {
  late final AnimationController _progress = AnimationController(vsync: this, duration: widget.hold)
    ..addListener(() => widget.onProgress?.call(_progress.value))
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        if (widget.haptics) HapticFeedback.heavyImpact();
        widget.onConfirmed();
        _progress.value = 0;
      }
    });
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.highlight) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(HoldButton old) {
    super.didUpdateWidget(old);
    if (widget.highlight && !_pulse.isAnimating) _pulse.repeat(reverse: true);
    if (!widget.highlight && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    if (_progress.value > 0) {
      final report = widget.onProgress;
      Future.microtask(() => report?.call(0)); // gone mid-hold: no stuck feedback
    }
    _progress.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) {
        if (widget.haptics) HapticFeedback.selectionClick();
        _progress.forward(from: 0);
      },
      onTapUp: (_) => _progress.reverse(),
      onTapCancel: () => _progress.reverse(),
      child: AnimatedBuilder(
        animation: Listenable.merge([_progress, _pulse]),
        builder: (context, _) => _RailItem(
          label: _progress.value > 0 ? context.l10n.pilotHolding : widget.label,
          icon: widget.icon,
          selected: false,
          color: widget.color,
          glow: _pulse.value,
          progress: _progress.value,
        ),
      ),
    );
  }
}

/// One entry of the bottom mode rail.
class RailButton extends StatelessWidget {
  const RailButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.haptics = true,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final bool haptics;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (haptics) HapticFeedback.selectionClick();
        onTap();
      },
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: _RailItem(label: label, icon: icon, selected: selected, color: const Color(0xFF3FCDF5)),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.label,
    required this.icon,
    required this.selected,
    required this.color,
    this.glow = 0,
    this.progress = 0,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final Color color;
  final double glow;
  final double progress;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: selected ? color.withValues(alpha: 0.22) : color.withValues(alpha: 0.10 + 0.25 * glow),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: selected ? color : Colors.transparent, width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 30,
            height: 30,
            child: CustomPaint(
              painter: progress > 0 ? _RingPainter(progress, color) : null,
              child: Icon(icon, size: 20, color: selected || glow > 0 || progress > 0 ? color : Colors.white),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: selected ? color : Colors.white.withValues(alpha: 0.9),
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.progress, this.color);

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawArc(
      Offset.zero & size,
      -math.pi / 2,
      2 * math.pi * progress,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress;
}

/// Vertical body-height slider on the screen edge.
class HeightSlider extends StatelessWidget {
  const HeightSlider({super.key, required this.value, required this.onChanged, this.enabled = true});

  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Glass(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.height, color: Colors.white70, size: 18),
          SizedBox(
            height: 150,
            width: 36, // without it the rotated slider claims the whole screen width
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9),
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(value: value, onChanged: enabled ? onChanged : null),
              ),
            ),
          ),
          Text('${(value * 100).round()}%', style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}
