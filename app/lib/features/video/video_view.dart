import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../l10n/l10n.dart';
import 'whep_client.dart';

enum VideoStatus { connecting, playing, unavailable }

/// The one video renderer of the app, never disposed: disposing one while
/// the next initialized (the address resolving from hexapod to its IP)
/// sometimes left the new one without frames, stuck on "Connecting".
final videoRendererProvider = Provider<RTCVideoRenderer>((ref) => RTCVideoRenderer());
final _rendererReady = <RTCVideoRenderer, Future<void>>{};

/// One camera connection per WHEP endpoint, shared by every [VideoView] that
/// shows it. It lives here and not in the widget: a release build could hold
/// two VideoView states at once, each with its own connection, and the one on
/// screen was not always the one that played.
final videoSessionProvider = Provider.autoDispose.family<VideoSession, Uri>((ref, uri) {
  final session = VideoSession(uri, ref.watch(videoRendererProvider));
  ref.onDispose(session.dispose);
  return session;
});

/// The camera from MediaMTX over WebRTC (WHEP). Reconnects by itself.
class VideoSession extends ChangeNotifier {
  VideoSession(this.uri, this.renderer) {
    _rendererReady.putIfAbsent(renderer, renderer.initialize).then((_) {
      _ready = true;
      _restart(immediately: true);
    });
  }

  /// WHEP endpoint, e.g. http://hexapod.local:8889/cam/whep
  final Uri uri;
  final RTCVideoRenderer renderer;

  VideoStatus get status => _status;
  VideoStatus _status = VideoStatus.connecting;

  RTCPeerConnection? _pc;
  MediaStream? _stream; // what this session put on the shared renderer
  WhepClient? _whep;
  Timer? _retry;
  bool _disposed = false;
  bool _ready = false; // the renderer is initialized
  int _attempt = 0;

  /// Bumped by every restart: an attempt still in flight closes its own
  /// connection when it lands instead of playing next to the current one.
  int _generation = 0;

  /// One attempt per generation: [_restart] schedules it with its own number.
  Future<void> _connect(int gen) async {
    bool stale() => _disposed || gen != _generation;
    if (stale() || !_ready) return;
    RTCPeerConnection? pc;
    // The restart's teardown may run before the pc is kept, and Android keeps
    // an unclosed one playing: a dropped attempt closes its own.
    Future<void> drop() async {
      try {
        await pc?.close();
      } catch (_) {}
    }

    _set(VideoStatus.connecting);
    try {
      pc = await createPeerConnection({'iceServers': [], 'sdpSemantics': 'unified-plan'});
      if (stale()) return drop();
      _pc = pc;
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      pc.onTrack = (event) {
        if (stale()) {
          drop();
          return;
        }
        if (event.track.kind == 'video' && event.streams.isNotEmpty) {
          renderer.srcObject = _stream = event.streams.first;
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
      if (stale()) return drop();
      final whep = WhepClient(uri);
      _whep = whep;
      final answer = await whep.exchange(local!.sdp!);
      if (stale()) {
        await whep.close();
        return drop();
      }
      await pc.setRemoteDescription(RTCSessionDescription(answer, 'answer'));
      if (stale()) {
        await whep.close();
        return drop();
      }
    } catch (_) {
      if (stale()) return drop();
      _restart();
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
    final gen = ++_generation;
    _teardown();
    _set(_attempt > 1 ? VideoStatus.unavailable : VideoStatus.connecting);
    final delay = immediately ? Duration.zero : Duration(seconds: (_attempt++).clamp(1, 5));
    _retry = Timer(delay, () => _connect(gen));
  }

  void _teardown() {
    final pc = _pc;
    _pc = null;
    pc?.onConnectionState = null;
    pc?.close();
    _whep?.close();
    _whep = null;
    if (_ready && _stream != null && renderer.srcObject == _stream) renderer.srcObject = null;
    _stream = null;
  }

  void _set(VideoStatus s) {
    if (_disposed || s == _status) return;
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _retry?.cancel();
    _teardown();
    super.dispose();
  }
}

/// Full-screen camera; the controls never wait for the video.
class VideoView extends ConsumerWidget {
  const VideoView({super.key, required this.uri});

  /// WHEP endpoint, e.g. http://hexapod.local:8889/cam/whep
  final Uri uri;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(videoSessionProvider(uri));
    // The video shows once the renderer reports frames of the current
    // stream: the renderer drives this, so a missed status update can never
    // leave "Connecting" over a playing camera.
    return Stack(
      fit: StackFit.expand,
      children: [
        RTCVideoView(session.renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
        ListenableBuilder(
          listenable: Listenable.merge([session, session.renderer]),
          builder: (context, _) {
            final unavailable = session.status == VideoStatus.unavailable;
            final playing = !unavailable && session.renderer.srcObject != null && session.renderer.value.width > 0;
            if (playing) return const SizedBox.shrink();
            return Stack(
              fit: StackFit.expand,
              children: [
                const VideoPlaceholder(),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        unavailable ? Icons.videocam_off_rounded : Icons.videocam_rounded,
                        size: 40,
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        unavailable ? context.l10n.videoUnavailable : context.l10n.videoConnecting,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.25), fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
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
