import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:http/http.dart' as http;

import '../../l10n/app_localizations.dart';

/// The robot's Wi-Fi, as GET /api/wifi reports it.
class WifiStatus {
  const WifiStatus({
    required this.mode,
    required this.state,
    required this.apSsid,
    this.apBand,
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

  /// Band of the own network while it is up: "2.4" or "5" (GHz).
  final String? apBand;
  final String? ssid;
  final String? ip;
  final List<String> saved;

  /// Why the last join failed ("Casa: senha incorreta"), if it did.
  final String? error;

  static WifiStatus fromJson(Map<String, Object?> j) => WifiStatus(
    mode: j['mode'] as String? ?? 'home',
    state: j['state'] as String? ?? 'no-wifi',
    apSsid: j['ap_ssid'] as String? ?? '',
    apBand: j['ap_band'] as String?,
    ssid: j['ssid'] as String?,
    ip: j['ip'] as String?,
    saved: [for (final s in (j['saved'] as List?) ?? const []) s as String],
    error: j['error'] as String?,
  );
}

/// A network the robot sees.
typedef WifiNetwork = ({String ssid, int signal, bool secure, String band});

/// Error from the robot's setup API.
class RobotApiError implements Exception {
  RobotApiError(this.status, [this.detail]);

  /// HTTP status of the answer.
  final int status;

  /// The robot's own explanation, if it sent one.
  final String? detail;

  /// The pairing key was refused: the app must pair again.
  bool get keyRefused => status == 401;

  /// In words for the user, in the app's language.
  String describe(AppLocalizations l) => keyRefused ? l.coreApiKeyRefused : detail ?? l.coreApiError(status);

  /// In Portuguese, for callers without a BuildContext (prefer [describe]).
  String get message => describe(lookupAppLocalizations(const Locale('pt')));

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

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final r = await _client.post(_uri(path), headers: _headers, body: jsonEncode(body)).timeout(timeout);
    return _decode(r);
  }

  Map<String, Object?> _decode(http.Response r) {
    Map<String, Object?> j = {};
    try {
      j = (jsonDecode(utf8.decode(r.bodyBytes)) as Map).cast();
    } catch (_) {}
    if (r.statusCode == 401) throw RobotApiError(401);
    if (r.statusCode >= 400) throw RobotApiError(r.statusCode, j['error'] as String?);
    return j;
  }

  Future<WifiStatus> wifi() async => WifiStatus.fromJson(await _get('/api/wifi'));

  Future<List<WifiNetwork>> scan() async {
    final j = await _get('/api/wifi/scan', timeout: const Duration(seconds: 25));
    return [
      for (final n in (j['networks'] as List?) ?? const [])
        (
          ssid: n['ssid'] as String,
          signal: (n['signal'] as num?)?.toInt() ?? 0,
          secure: n['secure'] == true,
          band: n['band'] as String? ?? '2.4',
        ),
    ];
  }

  Future<void> join(String ssid, String password) =>
      _post('/api/wifi/join', {'ssid': ssid, 'password': password});
  Future<void> setMode(String mode) => _post('/api/wifi/mode', {'mode': mode});
  Future<void> forget(String ssid) => _post('/api/wifi/forget', {'ssid': ssid});
  Future<void> rename(String name) => _post('/api/name', {'name': name});

  Future<TailscaleStatus> tailscale() async => TailscaleStatus.fromJson(await _get('/api/tailscale'));

  /// Starts the robot's login: the answer carries the link to open (or the
  /// running status when it was logged in already). The robot waits up to
  /// 15 s for Tailscale to hand the link.
  Future<TailscaleStatus> tailscaleLogin() async =>
      TailscaleStatus.fromJson(await _post('/api/tailscale/login', {}, timeout: const Duration(seconds: 25)));

  Future<void> tailscaleLogout() => _post('/api/tailscale/logout', {}, timeout: const Duration(seconds: 15));

  /// The robot's gallery (photos and recordings on its SD card).
  Future<MediaStatus> media() async => MediaStatus.fromJson(await _get('/api/media'));

  /// Takes a photo now (the robot decodes one frame: a second or two).
  Future<MediaItem> photo() async =>
      MediaItem.fromJson(await _post('/api/media/photo', {}, timeout: const Duration(seconds: 25)));

  /// Starts or stops recording; stopping answers with the saved video.
  Future<MediaItem?> record(bool on) async {
    final j = await _post('/api/media/record', {'on': on}, timeout: const Duration(seconds: 20));
    final item = j['item'];
    return item is Map ? MediaItem.fromJson(item.cast()) : null;
  }

  Uri mediaUri(String name, {bool thumb = false}) =>
      _uri('/api/media/files/$name').replace(queryParameters: thumb ? {'thumb': '1'} : null);

  /// A thumbnail (small JPEG) for the gallery grid.
  Future<Uint8List> thumbnail(String name) async {
    final r = await _client
        .get(mediaUri(name, thumb: true), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw RobotApiError(r.statusCode);
    return r.bodyBytes;
  }

  /// Downloads a photo or video into [to], reporting progress (0 to 1).
  Future<void> download(String name, File to, {void Function(double)? progress}) async {
    final req = http.Request('GET', mediaUri(name))..headers.addAll(_headers);
    final r = await _client.send(req).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw RobotApiError(r.statusCode);
    final total = r.contentLength ?? 0;
    final sink = to.openWrite();
    var got = 0;
    try {
      await for (final chunk in r.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) progress?.call(got / total);
      }
    } finally {
      await sink.close();
    }
  }

  Future<void> deleteMedia(String name) async {
    final r = await _client.delete(mediaUri(name), headers: _headers).timeout(const Duration(seconds: 10));
    _decode(r);
  }

  /// Camera quality: the current preset ("720p" or "1080p").
  Future<String> cameraQuality() async => (await _get('/api/camera'))['quality'] as String? ?? '720p';
  Future<void> setCameraQuality(String quality) =>
      _post('/api/camera', {'quality': quality}, timeout: const Duration(seconds: 15));
}

/// A photo or video on the robot.
class MediaItem {
  const MediaItem({
    required this.name,
    required this.kind,
    required this.size,
    required this.created,
    this.durationS = 0,
  });

  final String name;
  final String kind; // "photo" or "video"
  final int size; // bytes
  final DateTime created;
  final int durationS;

  bool get isVideo => kind == 'video';

  static MediaItem fromJson(Map<String, Object?> j) => MediaItem(
    name: j['name'] as String,
    kind: j['kind'] as String? ?? 'photo',
    size: (j['size'] as num?)?.toInt() ?? 0,
    created: DateTime.tryParse(j['created'] as String? ?? '')?.toLocal() ?? DateTime.now(),
    durationS: (j['duration_s'] as num?)?.toInt() ?? 0,
  );
}

/// GET /api/media: the gallery and the recorder.
class MediaStatus {
  const MediaStatus({
    required this.recording,
    required this.recordingS,
    required this.freeMb,
    required this.items,
  });

  final bool recording;
  final int recordingS;
  final int freeMb;
  final List<MediaItem> items;

  static MediaStatus fromJson(Map<String, Object?> j) => MediaStatus(
    recording: j['recording'] == true,
    recordingS: (j['recording_s'] as num?)?.toInt() ?? 0,
    freeMb: (j['free_mb'] as num?)?.toInt() ?? 0,
    items: [for (final i in (j['items'] as List?) ?? const []) MediaItem.fromJson((i as Map).cast())],
  );
}

/// The robot on the owner's tailnet (GET /api/tailscale).
class TailscaleStatus {
  const TailscaleStatus({required this.state, this.authUrl, this.name, this.dnsName, this.ip, this.account});

  /// "running", "needs_login", "starting", "off" or "absent" (not installed).
  final String state;
  final String? authUrl;
  final String? name;
  final String? dnsName;
  final String? ip;
  final String? account;

  bool get running => state == 'running';

  static TailscaleStatus fromJson(Map<String, Object?> j) => TailscaleStatus(
    state: (j['state'] as String?) ?? 'absent',
    authUrl: j['auth_url'] as String?,
    name: j['name'] as String?,
    dnsName: j['dns_name'] as String?,
    ip: j['ip'] as String?,
    account: j['account'] as String?,
  );
}
