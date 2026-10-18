import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/link/robot_link.dart';
import '../../../core/proto.dart' as pb;
import '../state_texts.dart';
import 'controls.dart';

/// Top bar: link quality, robot state, battery, faults and settings.
class StatusBar extends StatelessWidget {
  const StatusBar({
    super.key,
    required this.link,
    required this.telemetry,
    required this.telemetryAge,
    required this.onSettings,
    required this.onFaults,
    this.gamepad,
    this.onGamepad,
    this.audio = false,
    this.onAudio,
  });

  final LinkStatus link;
  final pb.Telemetry? telemetry;

  /// Time since the last Telemetry (null if none yet).
  final Duration? telemetryAge;
  final VoidCallback onSettings;
  final VoidCallback onFaults;

  /// Name of the connected gamepad, if any.
  final String? gamepad;

  /// Opens the external controller sheet.
  final VoidCallback? onGamepad;
  final bool audio;
  final VoidCallback? onAudio;

  @override
  Widget build(BuildContext context) {
    final t = telemetry;
    final stale = telemetryAge == null || telemetryAge! > const Duration(seconds: 1);
    final (linkText, linkColor) = switch (link) {
      LinkStatus.connected when !stale => ('Conectado', severityColor(Severity.ok)),
      LinkStatus.connected => ('Sinal fraco', severityColor(Severity.warning)),
      LinkStatus.connecting => ('Conectando…', severityColor(Severity.info)),
      LinkStatus.disconnected => ('Sem conexão', severityColor(Severity.danger)),
    };
    final state = t != null && !stale ? describeState(t.state) : null;
    final faults = t == null ? const <String>[] : describeFaults(t.faultFlags);
    final volts = t?.batteryVoltageV ?? 0;

    return Row(
      children: [
        Glass(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Dot(linkColor),
              const SizedBox(width: 8),
              Text(
                linkText,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
              ),
              if (state != null) ...[
                Container(
                  width: 1,
                  height: 16,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  color: Colors.white24,
                ),
                Text(
                  state.label,
                  style: TextStyle(
                    color: severityColor(state.severity),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),
        const Spacer(),
        if (faults.isNotEmpty) ...[
          GestureDetector(
            onTap: onFaults,
            child: Glass(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: severityColor(Severity.warning)),
                  const SizedBox(width: 4),
                  Text(
                    '${faults.length}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Glass(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BatteryIcon(volts > 0 ? batteryPercent(volts) : null),
              const SizedBox(width: 6),
              Text(
                volts > 0 ? '${batteryPercent(volts)}%  ${volts.toStringAsFixed(1)} V' : '—',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (gamepad != null || onGamepad != null) ...[
          GestureDetector(
            onTap: onGamepad,
            child: Tooltip(
              message: gamepad ?? 'Controle externo',
              child: Glass(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.sports_esports_rounded,
                  color: gamepad != null ? severityColor(Severity.ok) : Colors.white54,
                  size: 20,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        if (onAudio != null) ...[
          GestureDetector(
            onTap: onAudio,
            child: Glass(
              padding: const EdgeInsets.all(8),
              child: Icon(
                audio ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                color: audio ? Colors.white : Colors.white54,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        GestureDetector(
          onTap: onSettings,
          child: const Glass(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.tune_rounded, color: Colors.white, size: 20),
          ),
        ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 10,
    height: 10,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 6)],
    ),
  );
}

class _BatteryIcon extends StatelessWidget {
  const _BatteryIcon(this.percent);

  final int? percent;

  @override
  Widget build(BuildContext context) {
    final p = percent;
    final color = p == null
        ? Colors.white54
        : p <= 15
        ? severityColor(Severity.danger)
        : p <= 35
        ? severityColor(Severity.warning)
        : severityColor(Severity.ok);
    final icon = p == null
        ? Icons.battery_unknown_rounded
        : p > 80
        ? Icons.battery_full_rounded
        : p > 50
        ? Icons.battery_5_bar_rounded
        : p > 25
        ? Icons.battery_3_bar_rounded
        : Icons.battery_1_bar_rounded;
    return Transform.rotate(
      angle: math.pi / 2,
      child: Icon(icon, color: color, size: 20),
    );
  }
}

/// Explains a non-normal state and what to do, under the top bar.
class StateBanner extends StatelessWidget {
  const StateBanner({super.key, required this.text});

  final StateText text;

  @override
  Widget build(BuildContext context) {
    final color = severityColor(text.severity);
    return Glass(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            text.severity == Severity.danger ? Icons.error_rounded : Icons.info_rounded,
            color: color,
            size: 22,
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (text.detail != null)
                  Text(text.detail!, style: const TextStyle(color: Colors.white, fontSize: 13)),
                if (text.action != null)
                  Text(
                    text.action!,
                    style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Top-down proximity view of the 4 VL53L0X (front, right, rear, left).
class ProximityRadar extends StatelessWidget {
  const ProximityRadar({super.key, required this.distancesMm, required this.blockedMask});

  final List<int> distancesMm;
  final int blockedMask;

  @override
  Widget build(BuildContext context) {
    final front = distancesMm.isNotEmpty ? distancesMm[0] : 0;
    return Glass(
      radius: 14,
      padding: const EdgeInsets.fromLTRB(10, 4, 12, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CustomPaint(painter: _RadarPainter(distancesMm, blockedMask)),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('frente', style: TextStyle(color: Colors.white54, fontSize: 10)),
              Text(
                front > 0 ? _fmt(front) : '—',
                style: TextStyle(
                  color: _RadarPainter.colorFor(front, blockedMask & 1 != 0),
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(int mm) =>
      mm >= 1000 ? '${(mm / 1000).toStringAsFixed(1)} m' : '${(mm / 10).round()} cm';
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.d, this.blocked);

  final List<int> d;
  final int blocked;

  static Color colorFor(int mm, bool isBlocked) {
    if (mm <= 0) return Colors.white24;
    if (isBlocked || mm < 150) return severityColor(Severity.danger);
    if (mm < 300) return const Color(0xFFFF8A3D);
    if (mm < 600) return severityColor(Severity.warning);
    return severityColor(Severity.ok);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    // Body (hexagon) seen from above.
    final body = Path();
    for (var i = 0; i < 6; i++) {
      final a = math.pi / 6 + i * math.pi / 3;
      final p = c + Offset(math.cos(a), math.sin(a)) * size.width * 0.16;
      i == 0 ? body.moveTo(p.dx, p.dy) : body.lineTo(p.dx, p.dy);
    }
    body.close();
    canvas.drawPath(body, Paint()..color = Colors.white70);
    // Arcs: front is up on screen.
    const angles = [-math.pi / 2, 0.0, math.pi / 2, math.pi]; // front, right, rear, left
    for (var i = 0; i < 4; i++) {
      final mm = i < d.length ? d[i] : 0;
      final isBlocked = blocked & (1 << i) != 0;
      final color = colorFor(mm, isBlocked);
      // Closer obstacle -> arc nearer the body.
      final reach = size.width / 2 - 3;
      final r = mm <= 0 ? reach : reach * (0.5 + 0.5 * mm.clamp(0, 1000) / 1000);
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        angles[i] - 0.5,
        1.0,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = isBlocked ? 4 : 3
          ..strokeCap = StrokeCap.round
          ..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RadarPainter old) => true;
}
