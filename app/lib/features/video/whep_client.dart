import 'package:http/http.dart' as http;

class WhepException implements Exception {
  WhepException(this.message);

  final String message;

  @override
  String toString() => 'WhepException: $message';
}

/// WHEP signaling (RFC 9725) with MediaMTX: POST the SDP offer, get the answer.
/// The media itself is handled by flutter_webrtc.
class WhepClient {
  WhepClient(this.endpoint, {http.Client? client}) : _http = client ?? http.Client();

  /// e.g. http://hexapod.local:8889/cam/whep
  final Uri endpoint;
  final http.Client _http;

  /// Session URL returned by the server (DELETE it to stop early).
  Uri? session;

  Future<String> exchange(String offerSdp, {Duration timeout = const Duration(seconds: 4)}) async {
    final res = await _http
        .post(endpoint, headers: {'Content-Type': 'application/sdp'}, body: offerSdp)
        .timeout(timeout);
    if (res.statusCode == 404) throw WhepException('no stream at ${endpoint.path}');
    if (res.statusCode != 201) throw WhepException('HTTP ${res.statusCode}: ${res.body.trim()}');
    final location = res.headers['location'];
    if (location != null) session = endpoint.resolve(location);
    return res.body;
  }

  Future<void> close() async {
    final s = session;
    session = null;
    if (s != null) {
      try {
        await _http.delete(s).timeout(const Duration(seconds: 1));
      } catch (_) {
        // the server times sessions out by itself
      }
    }
    _http.close();
  }
}
