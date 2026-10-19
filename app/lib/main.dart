import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'core/robots.dart';
import 'core/providers.dart';
import 'core/settings.dart';
import 'features/brand/brand.dart';
import 'features/pilot/pilot_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Piloting is landscape-only and full-screen, like a drone app.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // The screen must not sleep while piloting.
  await WakelockPlus.enable().catchError((_) {});
  final settings = await Settings.load();
  final robots = await RobotsNotifier.load();
  runApp(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => SettingsNotifier(settings)),
        robotsProvider.overrideWith(() => RobotsNotifier(robots)),
      ],
      child: const HexapodApp(),
    ),
  );
}

class HexapodApp extends StatelessWidget {
  const HexapodApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Hexápode',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: Brand.cyan, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const BrandSplash(child: PilotScreen()),
    );
  }
}
