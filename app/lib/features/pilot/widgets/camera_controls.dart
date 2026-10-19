import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/link/robot_api.dart';
import '../../../core/providers.dart';
import '../../../l10n/l10n.dart';
import '../../gallery/gallery_screen.dart';
import 'controls.dart';

const _rec = Color(0xFFFF5A5F);

/// Photo and record buttons under STOP. Both are saved on the robot's SD
/// card (the gallery downloads them to the phone); the recording state
/// comes from the robot (PiStatus), so it is right after a reconnect too.
class CameraControls extends ConsumerStatefulWidget {
  const CameraControls({super.key, required this.haptics});

  final bool haptics;

  @override
  ConsumerState<CameraControls> createState() => _CameraControlsState();
}

class _CameraControlsState extends ConsumerState<CameraControls> {
  bool _busy = false;
  bool? _wanted; // recording asked for, until the robot confirms

  bool get _recording => _wanted ?? ref.read(piStatusProvider).value?.status.recording ?? false;

  String _why(Object e, AppLocalizations l) => switch (e) {
    RobotApiError(status: 507) => l.pilotNoSpace,
    RobotApiError(status: 503) => l.pilotCameraFailed,
    RobotApiError() => e.describe(l),
    _ => l.pilotCameraFailed,
  };

  void _tell(String text, {bool gallery = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 3),
        action: gallery
            ? SnackBarAction(label: context.l10n.pilotSeeGallery, onPressed: () => showGalleryScreen(context))
            : null,
      ),
    );
  }

  Future<void> _photo() async {
    final api = ref.read(robotApiProvider);
    if (api == null || _busy) return;
    if (widget.haptics) HapticFeedback.mediumImpact();
    final l = context.l10n;
    setState(() => _busy = true);
    try {
      await api.photo();
      if (mounted) _tell(l.pilotPhotoSaved, gallery: true);
    } catch (e) {
      if (mounted) _tell(_why(e, l));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _record() async {
    final api = ref.read(robotApiProvider);
    if (api == null || _busy) return;
    if (widget.haptics) HapticFeedback.heavyImpact();
    final l = context.l10n;
    final on = !_recording;
    setState(() {
      _busy = true;
      _wanted = on;
    });
    try {
      await api.record(on);
      if (!on && mounted) _tell(l.pilotRecordSaved, gallery: true);
    } catch (e) {
      if (mounted) {
        setState(() => _wanted = null);
        _tell(_why(e, l));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final robotSays = ref.watch(piStatusProvider).value?.status.recording;
    // The robot's word wins once it agrees with what was asked.
    if (_wanted != null && robotSays == _wanted) _wanted = null;
    final recording = _wanted ?? robotSays ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Round(
          tooltip: l.pilotPhoto,
          onTap: _photo,
          child: _busy && _wanted == null
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.photo_camera_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(height: 10),
        _Round(
          tooltip: recording ? l.pilotStopRecording : l.pilotRecord,
          onTap: _record,
          border: recording ? _rec : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: recording ? 16 : 20,
            height: recording ? 16 : 20,
            decoration: BoxDecoration(color: _rec, borderRadius: BorderRadius.circular(recording ? 3 : 10)),
          ),
        ),
      ],
    );
  }
}

class _Round extends StatelessWidget {
  const _Round({required this.tooltip, required this.onTap, required this.child, this.border});

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;
  final Color? border;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Glass(
          padding: EdgeInsets.zero,
          radius: 24,
          child: Container(
            width: 48,
            height: 48,
            alignment: Alignment.center,
            decoration: border == null
                ? null
                : BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: border!, width: 2),
                  ),
            child: child,
          ),
        ),
      ),
    ),
  );
}

/// "● REC 1:23" for the status bar while the robot records.
class RecBadge extends StatelessWidget {
  const RecBadge(this.seconds, {super.key});

  final int seconds;

  @override
  Widget build(BuildContext context) => Glass(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(color: _rec, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          'REC ${formatClip(seconds)}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 13,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );
}
