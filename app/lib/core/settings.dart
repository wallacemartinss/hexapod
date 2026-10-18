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
    this.robotAudio = false,
    this.autoHideBars = true,
    this.hideSticksWithPad = true,
    this.onboarded = false,
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

  /// Play the robot's microphone.
  final bool robotAudio;

  /// Height slider and mode bar hide while piloting; a tap brings them back.
  final bool autoHideBars;

  /// With a gamepad connected, the on-screen sticks go away (STOP stays).
  final bool hideSticksWithPad;

  /// The first-run tips were dismissed.
  final bool onboarded;

  /// URIs for an already resolved [address] (see host_resolver.dart).
  Uri wsUri(String address) => Uri(scheme: 'ws', host: address, port: port, path: '/ws');
  Uri whepUri(String address) => Uri(scheme: 'http', host: address, port: videoPort, path: '/cam/whep');
  Uri micUri(String address) => Uri(scheme: 'http', host: address, port: videoPort, path: '/mic/whep');

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
    bool? robotAudio,
    bool? autoHideBars,
    bool? hideSticksWithPad,
    bool? onboarded,
  }) => Settings(
    host: host ?? this.host,
    port: port ?? this.port,
    videoPort: videoPort ?? this.videoPort,
    deadzone: deadzone ?? this.deadzone,
    expo: expo ?? this.expo,
    maxSpeed: maxSpeed ?? this.maxSpeed,
    swapSticks: swapSticks ?? this.swapSticks,
    haptics: haptics ?? this.haptics,
    robotAudio: robotAudio ?? this.robotAudio,
    autoHideBars: autoHideBars ?? this.autoHideBars,
    hideSticksWithPad: hideSticksWithPad ?? this.hideSticksWithPad,
    onboarded: onboarded ?? this.onboarded,
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
      robotAudio: p.getBool('robotAudio') ?? d.robotAudio,
      autoHideBars: p.getBool('autoHideBars') ?? d.autoHideBars,
      hideSticksWithPad: p.getBool('hideSticksWithPad') ?? d.hideSticksWithPad,
      onboarded: p.getBool('onboarded') ?? d.onboarded,
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
    await p.setBool('robotAudio', robotAudio);
    await p.setBool('autoHideBars', autoHideBars);
    await p.setBool('hideSticksWithPad', hideSticksWithPad);
    await p.setBool('onboarded', onboarded);
  }
}
