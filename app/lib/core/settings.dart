import 'package:shared_preferences/shared_preferences.dart';

import 'control/command_mapper.dart';

/// User settings, persisted on the phone.
class Settings {
  const Settings({
    this.host = 'hexapod.local',
    this.port = 8080,
    this.videoPort = 8889,
    this.deadzone = 0.08,
    this.expo = 0.35,
    this.maxSpeed = 1.0,
    this.swapSticks = false,
    this.haptics = true,
  });

  final String host;
  final int port;
  final int videoPort;
  final double deadzone;
  final double expo;
  final double maxSpeed;

  /// Left-handed: the left stick turns, the right one walks.
  final bool swapSticks;
  final bool haptics;

  Uri get wsUri => Uri(scheme: 'ws', host: host, port: port, path: '/ws');
  Uri get whepUri => Uri(scheme: 'http', host: host, port: videoPort, path: '/cam/whep');
  StickShaping get shaping => StickShaping(deadzone: deadzone, expo: expo, maxSpeed: maxSpeed);

  Settings copyWith({
    String? host,
    int? port,
    int? videoPort,
    double? deadzone,
    double? expo,
    double? maxSpeed,
    bool? swapSticks,
    bool? haptics,
  }) => Settings(
    host: host ?? this.host,
    port: port ?? this.port,
    videoPort: videoPort ?? this.videoPort,
    deadzone: deadzone ?? this.deadzone,
    expo: expo ?? this.expo,
    maxSpeed: maxSpeed ?? this.maxSpeed,
    swapSticks: swapSticks ?? this.swapSticks,
    haptics: haptics ?? this.haptics,
  );

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    const d = Settings();
    return Settings(
      host: p.getString('host') ?? d.host,
      port: p.getInt('port') ?? d.port,
      videoPort: p.getInt('videoPort') ?? d.videoPort,
      deadzone: p.getDouble('deadzone') ?? d.deadzone,
      expo: p.getDouble('expo') ?? d.expo,
      maxSpeed: p.getDouble('maxSpeed') ?? d.maxSpeed,
      swapSticks: p.getBool('swapSticks') ?? d.swapSticks,
      haptics: p.getBool('haptics') ?? d.haptics,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('host', host);
    await p.setInt('port', port);
    await p.setInt('videoPort', videoPort);
    await p.setDouble('deadzone', deadzone);
    await p.setDouble('expo', expo);
    await p.setDouble('maxSpeed', maxSpeed);
    await p.setBool('swapSticks', swapSticks);
    await p.setBool('haptics', haptics);
  }
}
