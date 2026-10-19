import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The brand palette (assets/brand/src/*.svg).
abstract final class Brand {
  static const navy = Color(0xFF0C1428); // background
  static const navyLight = Color(0xFF16284A); // glow at the center
  static const navyDeep = Color(0xFF060A14); // edges
  static const card = Color(0xFF121C34); // panels over the navy
  static const cyan = Color(0xFF3FCDF5); // the eye: accent
  static const cyanLight = Color(0xFF5FD6FF);
  static const subtitle = Color(0xFF8A9CC4);
}

/// The splash in landscape (the app only runs lying down): the brand's
/// navy with the hexagon grid, the robot and the name. It covers [child]
/// for [hold], then fades out; [child] is built from the start, so the
/// robot is already being reached behind it. The native splash (icon on
/// navy, from `make brand`) shows before this, while Flutter starts.
class BrandSplash extends StatefulWidget {
  const BrandSplash({super.key, required this.child, this.hold = const Duration(milliseconds: 1400)});

  final Widget child;
  final Duration hold;

  @override
  State<BrandSplash> createState() => _BrandSplashState();
}

class _BrandSplashState extends State<BrandSplash> {
  bool _fading = false;
  bool _gone = false;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.hold, () => setState(() => _fading = true));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_gone)
          IgnorePointer(
            ignoring: _fading,
            child: AnimatedOpacity(
              opacity: _fading ? 0 : 1,
              duration: const Duration(milliseconds: 450),
              onEnd: () => setState(() => _gone = true),
              // Over no Scaffold: Material gives the text the app's font and style.
              child: const Material(
                type: MaterialType.transparency,
                child: BrandBackdrop(child: _Logo()),
              ),
            ),
          ),
      ],
    );
  }
}

/// The brand's background: radial navy glow and the faint hexagon grid.
class BrandBackdrop extends StatelessWidget {
  const BrandBackdrop({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.1),
          radius: 1.2,
          colors: [Brand.navyLight, Brand.navy, Brand.navyDeep],
          stops: [0, 0.55, 1],
        ),
      ),
      child: CustomPaint(painter: _HexGrid(), child: child ?? const SizedBox.expand()),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // The PNG has wide transparent margins: the robot and name fill its
        // middle ~70 %.
        final side = math.min(box.maxHeight * 0.95, box.maxWidth * 0.6);
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                'assets/brand/splash_logo.png',
                width: side,
                height: side * 0.88,
                fit: BoxFit.cover,
              ),
              Text(
                'SPIDER ROBOT CONTROL',
                style: TextStyle(
                  color: Brand.subtitle,
                  fontSize: math.max(12, side * 0.035),
                  letterSpacing: side * 0.014,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Flat-topped hexagons of radius 48 (as in the SVGs), cyan at 6 %.
class _HexGrid extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const r = 48.0;
    final h = r * math.sqrt(3) / 2; // half height
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Brand.cyanLight.withValues(alpha: 0.06);
    for (var col = 0; col * r * 1.5 < size.width + r; col++) {
      final x = col * r * 1.5;
      for (var row = -1; row * 2 * h < size.height + h; row++) {
        final y = row * 2 * h + (col.isOdd ? h : 0);
        final path = Path();
        for (var k = 0; k < 6; k++) {
          final a = math.pi / 3 * k;
          final p = Offset(x + r * math.cos(a), y + r * math.sin(a));
          k == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path..close(), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
