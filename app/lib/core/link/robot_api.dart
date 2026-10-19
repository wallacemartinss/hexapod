import 'dart:convert';

import 'package:http/http.dart' as http;

/// The robot's Wi-Fi, as GET /api/wifi reports it.
class WifiStatus {
  const WifiStatus({
    required this.mode,
    required this.state,
    required this.apSsid,
    this.ssid,
    this.ip,
    this.saved = const [],
    this.error,
  });

  /// "home" (saved networks, own network as fallback) or "direct".
  final String mode;

  /// "own", "home", "connecting" or "no-wifi".
  final String state;
  final String apSsid;
  final String? ssid;
  final String? ip;
  final List<String> saved;

  /// Why the last join failed ("Casa: senha incorreta"), if it did.
  final String? error;

  static WifiStatus fromJson(Map<String, Object?> j) => WifiStatus(
    mode: j['mode'] as String? ?? 'home',
    state: j['state'] as String? ?? 'no-wifi',
    apSsid: j['ap_ssid'] as String? ?? '',
    ssid: j['ssid'] as String?,
    ip: j['ip'] as String?,
    saved: [for (final s in (j['saved'] as List?) ?? const []) s as String],
    error: j['error'] as String?,
  );
}

/// A network the robot sees.
typedef WifiNetwork = ({String ssid, int signal, bool secure});

/// Error from the robot, already in words for the user.
class RobotApiError implements Exception {
  RobotApiError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The robot's setup API (/api/...), always with the pairing key.
class RobotApi {
  RobotApi(this.address, this.token, {this.port = 8080, http.Client? client})
    : _client = client ?? http.Client();

  final String address;
  final String token;
  final int port;
  final http.Client _client;

  Uri _uri(String path) => Uri(scheme: 'http', host: address, port: port, path: path);
  Map<String, String> get _headers => {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  Future<Map<String, Object?>> _get(String path, {Duration timeout = const Duration(seconds: 5)}) async {
    final r = await _client.get(_uri(path), headers: _headers).timeout(timeout);
    return _decode(r);
  }

  Future<Map<String, Object?>> _post(String path, Map<String, Object?> body) async {
    final r = await _client
        .post(_uri(path), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 5));
    return _decode(r);
  }

  Map<String, Object?> _decode(http.Response r) {
    Map<String, Object?> j = {};
    try {
      j = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast();
    } catch (_) {}
    if (r.statusCode == 401) throw RobotApiError('O robô recusou a chave: pareie de novo');
    if (r.statusCode >= 400) throw RobotApiError(j['error'] as String? ?? 'Erro ${r.statusCode} no robô');
    return j;
  }

  Future<WifiStatus> wifi() async => WifiStatus.fromJson(await _get('/api/wifi'));

  Future<List<WifiNetwork>> scan() async {
    final j = await _get('/api/wifi/scan', timeout: const Duration(seconds: 25));
    return [
      for (final n in (j['networks'] as List?) ?? const [])
        (ssid: n['ssid'] as String, signal: (n['signal'] as num?)?.toInt() ?? 0, secure: n['secure'] == true),
    ];
  }

  Future<void> join(String ssid, String password) =>
      _post('/api/wifi/join', {'ssid': ssid, 'password': password});
  Future<void> setMode(String mode) => _post('/api/wifi/mode', {'mode': mode});
  Future<void> forget(String ssid) => _post('/api/wifi/forget', {'ssid': ssid});
  Future<void> rename(String name) => _post('/api/name', {'name': name});
}
