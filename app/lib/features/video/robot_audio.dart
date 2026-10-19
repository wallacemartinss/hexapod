import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'whep_client.dart';

/// Plays the robot's microphone (MediaMTX `mic` path, Opus over WHEP) while
/// mounted. Invisible; WebRTC routes remote audio to the speaker by itself.
class RobotAudio extends StatefulWidget {
  const RobotAudio({super.key, required this.uri});

  /// e.g. http://hexapod.local:8889/mic/whep
  final Uri uri;

  @override
  State<RobotAudio> createState() => _RobotAudioState();
}

class _RobotAudioState extends State<RobotAudio> {
  RTCPeerConnection? _pc;
  WhepClient? _whep;
  Timer? _retry;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    try {
      final pc = await createPeerConnection({'iceServers': [], 'sdpSemantics': 'unified-plan'});
      _pc = pc;
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      pc.onConnectionState = (s) {
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          _restart();
        }
      };
      await pc.setLocalDescription(await pc.createOffer());
      await Future<void>.delayed(const Duration(milliseconds: 500)); // gather LAN candidates
      final whep = WhepClient(widget.uri);
      _whep = whep;
      final answer = await whep.exchange((await pc.getLocalDescription())!.sdp!);
      await pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
    } catch (_) {
      _restart();
    }
  }

  void _restart() {
    if (_disposed) return;
    _teardown();
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 3), _connect);
  }

  void _teardown() {
    _pc?.onConnectionState = null;
    _pc?.close();
    _pc = null;
    _whep?.close();
    _whep = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _teardown();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
