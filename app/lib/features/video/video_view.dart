import 'package:flutter/material.dart';

/// Full-screen camera. Milestone 6.1: placeholder; 6.2 plays the MediaMTX
/// WHEP stream at [uri] with flutter_webrtc.
class VideoView extends StatelessWidget {
  const VideoView({super.key, required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.2,
          colors: [Color(0xFF1C2430), Color(0xFF07090C)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off_rounded, size: 40, color: Colors.white.withValues(alpha: 0.18)),
            const SizedBox(height: 6),
            Text(
              'Câmera indisponível',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
