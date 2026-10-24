import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../l10n/l10n.dart';
import 'whep_client.dart';

enum VideoStatus { connecting, playing, unavailable }

/// Full-screen camera from MediaMTX over WebRTC (WHEP). Reconnects by itself;
/// the controls never wait for the video.
class VideoView extends StatefulWidget {
  const VideoView({super.key, required this.uri});

  /// WHEP endpoint, e.g. http://hexapod.local:8889/cam/whep
  final Uri uri;

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> {
  final _renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  WhepClient? _whep;
  Timer? _retry;
  VideoStatus _status = VideoStatus.connecting;
  bool _disposed = false;
  int _attempt = 0;

  /// Bumped by every restart: an older attempt still in flight (the robot's
  /// address changed mid-connect) closes its own connection when it lands,
  /// instead of playing, unseen, next to the current one.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) => _connect());
  }

  @override
  void didUpdateWidget(VideoView old) {
    super.didUpdateWidget(old);
    if (old.uri != widget.uri) _restart(immediately: true);
  }

  Future<void> _connect() async {
    if (_disposed) return;
    final gen = _generation;
    bool stale() => _disposed || gen != _generation;
    _set(VideoStatus.connecting);
    RTCPeerConnection? pc;
    try {
      pc = await createPeerConnection({'iceServers': [], 'sdpSemantics': 'unified-plan'});
      if (stale()) {
        await pc.close();
        return;
      }
      _pc = pc;
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      pc.onTrack = (event) {
        if (stale()) return;
        if (event.track.kind == 'video' && event.streams.isNotEmpty) {
          _renderer.srcObject = event.streams.first;
          _attempt = 0;
          _set(VideoStatus.playing);
        }
      };
      pc.onConnectionState = (state) {
        if (stale()) return;
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _restart();
        }
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await _iceGathered(pc);
      final local = await pc.getLocalDescription();
      if (stale()) return; // the restart closed this pc
      final whep = WhepClient(widget.uri);
      _whep = whep;
      final answer = await whep.exchange(local!.sdp!);
      if (stale()) {
        await whep.close();
        return;
      }
      await pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
    } catch (_) {
      if (!stale()) _restart();
    }
  }

  /// WHEP without trickle: send the offer with all candidates (fast on a LAN).
  Future<void> _iceGathered(RTCPeerConnection pc) async {
    if (pc.iceGatheringState == RTCIceGatheringState.RTCIceGatheringStateComplete) return;
    final done = Completer<void>();
    pc.onIceGatheringState = (s) {
      if (s == RTCIceGatheringState.RTCIceGatheringStateComplete && !done.isCompleted) done.complete();
    };
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  void _restart({bool immediately = false}) {
    if (_disposed) return;
    _retry?.cancel();
    _generation++;
    _teardown();
    _set(_attempt > 1 ? VideoStatus.unavailable : VideoStatus.connecting);
    final delay = immediately ? Duration.zero : Duration(seconds: (_attempt++).clamp(1, 5));
    _retry = Timer(delay, _connect);
  }

  void _teardown() {
    final pc = _pc;
    _pc = null;
    pc?.onConnectionState = null;
    pc?.close();
    _whep?.close();
    _whep = null;
    _renderer.srcObject = null;
  }

  void _set(VideoStatus s) {
    if (!_disposed && mounted && s != _status) setState(() => _status = s);
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _retry?.cancel();
    _teardown();
    _renderer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const VideoPlaceholder(),
        if (_status == VideoStatus.playing)
          RTCVideoView(_renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
        if (_status != VideoStatus.playing)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _status == VideoStatus.connecting ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                  size: 40,
                  color: Colors.white.withValues(alpha: 0.18),
                ),
                const SizedBox(height: 6),
                Text(
                  _status == VideoStatus.connecting
                      ? context.l10n.videoConnecting
                      : context.l10n.videoUnavailable,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 13),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Background behind (or instead of) the video.
class VideoPlaceholder extends StatelessWidget {
  const VideoPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.2),
          radius: 1.2,
          colors: [Color(0xFF1C2430), Color(0xFF07090C)],
        ),
      ),
    );
  }
}
