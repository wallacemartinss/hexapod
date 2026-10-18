// WHEP signaling against a real MediaMTX: run pi/mediamtx/dev-video.sh first.
// Skipped when nothing listens on 127.0.0.1:8889.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/features/video/whep_client.dart';

// A receive-only H.264 offer, as flutter_webrtc would send it (minus candidates).
const _offer =
    'v=0\r\n'
    'o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'a=group:BUNDLE 0\r\n'
    'a=msid-semantic: WMS\r\n'
    'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
    'c=IN IP4 0.0.0.0\r\n'
    'a=rtcp:9 IN IP4 0.0.0.0\r\n'
    'a=ice-ufrag:hexa\r\n'
    'a=ice-pwd:hexapodhexapodhexapod12\r\n'
    'a=fingerprint:sha-256 '
    'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99\r\n'
    'a=setup:actpass\r\n'
    'a=mid:0\r\n'
    'a=recvonly\r\n'
    'a=rtcp-mux\r\n'
    'a=rtpmap:96 H264/90000\r\n'
    'a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f\r\n';

Future<bool> _serverUp() async {
  try {
    final s = await Socket.connect('127.0.0.1', 8889, timeout: const Duration(milliseconds: 300));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  test('MediaMTX answers a WHEP offer with H.264 video', () async {
    if (!await _serverUp()) {
      markTestSkipped('run pi/mediamtx/dev-video.sh');
      return;
    }
    final whep = WhepClient(Uri.parse('http://127.0.0.1:8889/cam/whep'));
    final answer = await whep.exchange(_offer);
    expect(answer, contains('m=video'));
    expect(answer, contains('H264'));
    expect(whep.session, isNotNull);
    await whep.close();
  });

  test('a missing stream is a clear error', () async {
    if (!await _serverUp()) {
      markTestSkipped('run pi/mediamtx/dev-video.sh');
      return;
    }
    final whep = WhepClient(Uri.parse('http://127.0.0.1:8889/nope/whep'));
    await expectLater(whep.exchange(_offer), throwsA(isA<WhepException>()));
    await whep.close();
  });
}
