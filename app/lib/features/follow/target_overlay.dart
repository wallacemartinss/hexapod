import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/proto.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../brand/brand.dart';

const _locked = Color(0xFFFF5A5F);

/// Asks the robot to follow a target (0: stop). A provider so tests can
/// watch the requests.
final followRequestProvider = Provider<void Function(int trackId)>(
  (ref) => ref.watch(linkProvider).followTarget,
);

/// Follow me over the video, like a drone's active track: a box on each
/// target the robot's camera sees; tap one, then Follow. The robot follows
/// only while this app stays connected, and Cancel (or leaving) stops it.
///
/// Only the boxes and the buttons take touches: the rest of the screen goes
/// through to the sticks below.
class TargetOverlay extends ConsumerStatefulWidget {
  const TargetOverlay({super.key, required this.haptics});

  final bool haptics;

  @override
  ConsumerState<TargetOverlay> createState() => _TargetOverlayState();
}

class _TargetOverlayState extends ConsumerState<TargetOverlay> {
  int? _picked; // tapped, not asked to follow yet

  void _follow(int trackId) {
    if (widget.haptics) HapticFeedback.mediumImpact();
    ref.read(followRequestProvider)(trackId);
    setState(() => _picked = null);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final frame = ref.watch(targetsProvider).value;
    final follow = ref.watch(followStatusProvider).value;
    final following = follow != null && follow.trackId != 0;
    final targets = frame?.targets ?? const <Target>[];
    if (_picked != null && !targets.any((t) => t.trackId == _picked)) _picked = null;

    return LayoutBuilder(
      builder: (context, box) {
        final children = <Widget>[];
        if (frame != null && frame.frameWidth > 0 && frame.frameHeight > 0) {
          // The video fills the screen cropped (cover): same mapping here.
          final fw = frame.frameWidth.toDouble(), fh = frame.frameHeight.toDouble();
          final scale = math.max(box.maxWidth / fw, box.maxHeight / fh);
          final dx = (box.maxWidth - fw * scale) / 2, dy = (box.maxHeight - fh * scale) / 2;
          for (final t in targets) {
            final r = Rect.fromLTWH(
              dx + t.x * fw * scale,
              dy + t.y * fh * scale,
              t.w * fw * scale,
              t.h * fh * scale,
            );
            final locked = following && follow.trackId == t.trackId;
            final picked = _picked == t.trackId;
            final color = locked ? _locked : (picked ? Colors.white : Brand.cyan);
            final label = _label(l, t);
            // At least a finger wide, whatever the marker's size on screen.
            final hit = Rect.fromCenter(
              center: r.center,
              width: math.max(r.width + 16, 56),
              height: math.max(r.height + 16, 56),
            );
            children.add(
              Positioned.fromRect(
                key: ValueKey('target-${t.trackId}'),
                rect: hit,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: following ? null : () => setState(() => _picked = picked ? null : t.trackId),
                  child: CustomPaint(painter: _Corners(color, locked ? 3 : 2)),
                ),
              ),
            );
            children.add(
              Positioned(
                left: hit.left,
                top: hit.top - 22,
                child: IgnorePointer(
                  child: _Tag(text: label, color: color),
                ),
              ),
            );
            if (picked && !following) {
              children.add(
                Positioned(
                  left: hit.center.dx - 60,
                  width: 120,
                  top: hit.bottom + 8,
                  child: FilledButton.icon(
                    key: const ValueKey('follow-start'),
                    style: FilledButton.styleFrom(backgroundColor: Brand.cyan, foregroundColor: Brand.navy),
                    onPressed: () => _follow(t.trackId),
                    icon: const Icon(Icons.my_location_rounded, size: 18),
                    label: Text(l.followStart),
                  ),
                ),
              );
            }
          }
          if (!following && targets.isNotEmpty && _picked == null) {
            children.add(
              Positioned(
                left: 0,
                right: 0,
                bottom: 96,
                child: IgnorePointer(
                  child: Center(
                    child: _Tag(text: l.followHint, color: Brand.cyan),
                  ),
                ),
              ),
            );
          }
        }
        if (following) {
          final lost = follow.state == FollowState.FOLLOW_STATE_LOST;
          final name = _lockedName(l, targets, follow.trackId);
          children.add(
            Positioned(
              left: 0,
              right: 0,
              top: 76,
              child: Center(
                child: _FollowBar(
                  text: lost
                      ? l.followLost
                      : follow.state == FollowState.FOLLOW_STATE_FOLLOWING
                      ? l.followFollowing(name)
                      : l.followLocked(name),
                  color: lost ? Colors.amber : _locked,
                  cancel: l.followCancel,
                  onCancel: () => _follow(0),
                ),
              ),
            ),
          );
        }
        return Stack(children: children);
      },
    );
  }
}

String _label(AppLocalizations l, Target t) {
  final person = t.kind == TargetKind.TARGET_KIND_PERSON;
  if (t.distanceM <= 0) return person ? l.followPerson : l.followTarget(t.markerId);
  return person ? l.followPersonDistance(t.distanceM) : l.followTargetDistance(t.markerId, t.distanceM);
}

/// The locked target's name, from the frame when it is in view.
String _lockedName(AppLocalizations l, List<Target> targets, int trackId) {
  for (final t in targets) {
    if (t.trackId == trackId) {
      return t.kind == TargetKind.TARGET_KIND_PERSON ? l.followPerson : l.followTarget(t.markerId);
    }
  }
  // Markers carry their id in the track (id + 1); people start at 1000.
  return trackId >= 1000 ? l.followPerson : l.followTarget(trackId - 1);
}

/// Four corner brackets, like a camera's focus box.
class _Corners extends CustomPainter {
  _Corners(this.color, this.width);

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final c = math.min(size.width, size.height) * 0.28;
    final w = size.width, h = size.height;
    for (final (x, y, sx, sy) in [
      (0.0, 0.0, 1.0, 1.0),
      (w, 0.0, -1.0, 1.0),
      (0.0, h, 1.0, -1.0),
      (w, h, -1.0, -1.0),
    ]) {
      canvas.drawLine(Offset(x, y), Offset(x + sx * c, y), p);
      canvas.drawLine(Offset(x, y), Offset(x, y + sy * c), p);
    }
  }

  @override
  bool shouldRepaint(_Corners old) => old.color != color || old.width != width;
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _FollowBar extends StatelessWidget {
  const _FollowBar({required this.text, required this.color, required this.cancel, required this.onCancel});

  final String text;
  final Color color;
  final String cancel;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: color.withValues(alpha: 0.8)),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.my_location_rounded, color: color, size: 18),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: const ValueKey('follow-cancel'),
            onPressed: onCancel,
            child: Text(
              cancel,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    ),
  );
}
