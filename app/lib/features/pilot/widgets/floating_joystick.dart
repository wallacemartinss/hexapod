import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/control/control_state.dart';

/// A joystick that appears where the thumb lands inside its area, follows it,
/// and springs back to zero on release. Uses raw pointer events (no gesture
/// arena delay) and tracks a single finger.
class FloatingJoystick extends StatefulWidget {
  const FloatingJoystick({
    super.key,
    required this.onChanged,
    required this.label,
    this.hint,
    this.enabled = true,
    this.haptics = true,
    this.accent = const Color(0xFF3FCDF5),
    this.restAlignment = const Alignment(0, 0.45),
    this.radius = 64,
  });

  final ValueChanged<Stick> onChanged;
  final String label;

  /// Shown under the label while idle (what each axis does).
  final String? hint;
  final bool enabled;
  final bool haptics;
  final Color accent;

  /// Where the faint idle ring sits inside the area.
  final Alignment restAlignment;
  final double radius;

  @override
  State<FloatingJoystick> createState() => _FloatingJoystickState();
}

class _FloatingJoystickState extends State<FloatingJoystick> {
  int? _pointer;
  Offset? _origin;
  Offset _knob = Offset.zero;

  void _down(PointerDownEvent e, Size size) {
    if (_pointer != null || !widget.enabled) return;
    final r = widget.radius;
    // Keep the whole ring on screen even if the thumb lands at an edge.
    final origin = Offset(
      e.localPosition.dx.clamp(r, math.max(r, size.width - r)),
      e.localPosition.dy.clamp(r, math.max(r, size.height - r)),
    );
    setState(() {
      _pointer = e.pointer;
      _origin = origin;
      _knob = Offset.zero;
    });
    if (widget.haptics) HapticFeedback.selectionClick();
    _move(e.localPosition);
  }

  void _move(Offset position) {
    final origin = _origin;
    if (origin == null) return;
    var d = position - origin;
    if (d.distance > widget.radius) d = d / d.distance * widget.radius;
    setState(() => _knob = d);
    widget.onChanged(Stick(d.dx / widget.radius, -d.dy / widget.radius));
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    setState(() {
      _pointer = null;
      _origin = null;
      _knob = Offset.zero;
    });
    widget.onChanged(Stick.zero);
  }

  @override
  void didUpdateWidget(FloatingJoystick old) {
    super.didUpdateWidget(old);
    if (!widget.enabled && _pointer != null) {
      _pointer = null;
      _origin = null;
      _knob = Offset.zero;
      widget.onChanged(Stick.zero);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final active = _origin != null;
        final center = _origin ?? widget.restAlignment.alongSize(size);
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => _down(e, size),
          onPointerMove: (e) {
            if (e.pointer == _pointer) _move(e.localPosition);
          },
          onPointerUp: _up,
          onPointerCancel: _up,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _JoystickPainter(
                    center: center,
                    knob: _knob,
                    radius: widget.radius,
                    active: active,
                    enabled: widget.enabled,
                    accent: widget.accent,
                  ),
                ),
              ),
              if (!active)
                Positioned(
                  left: center.dx - 90,
                  top: center.dy + widget.radius + 8,
                  width: 180,
                  child: IgnorePointer(
                    child: Column(
                      children: [
                        Text(
                          widget.label,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: widget.enabled ? 0.85 : 0.4),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                        if (widget.hint != null)
                          Text(
                            widget.hint!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _JoystickPainter extends CustomPainter {
  _JoystickPainter({
    required this.center,
    required this.knob,
    required this.radius,
    required this.active,
    required this.enabled,
    required this.accent,
  });

  final Offset center;
  final Offset knob;
  final double radius;
  final bool active;
  final bool enabled;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final base = enabled ? accent : Colors.white;
    final ringAlpha = active ? 0.55 : (enabled ? 0.22 : 0.10);
    canvas.drawCircle(center, radius, Paint()..color = Colors.black.withValues(alpha: active ? 0.28 : 0.12));
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = base.withValues(alpha: ringAlpha),
    );
    // Cross-hair ticks help aim small corrections.
    final tick = Paint()
      ..color = Colors.white.withValues(alpha: active ? 0.35 : 0.15)
      ..strokeWidth = 2;
    for (final dir in const [Offset(1, 0), Offset(-1, 0), Offset(0, 1), Offset(0, -1)]) {
      canvas.drawLine(center + dir * (radius - 10), center + dir * (radius - 3), tick);
    }
    final k = center + knob;
    if (active && knob.distance > 2) {
      canvas.drawLine(
        center,
        k,
        Paint()
          ..color = accent.withValues(alpha: 0.35)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawCircle(k, 26, Paint()..color = base.withValues(alpha: active ? 0.9 : (enabled ? 0.35 : 0.15)));
    canvas.drawCircle(
      k,
      26,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: active ? 0.9 : 0.3),
    );
  }

  @override
  bool shouldRepaint(_JoystickPainter old) =>
      old.center != center || old.knob != knob || old.active != active || old.enabled != enabled;
}
