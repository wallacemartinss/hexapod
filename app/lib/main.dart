import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'core/settings.dart';
import 'features/pilot/pilot_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Piloting is landscape-only and full-screen, like a drone app.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  final settings = await Settings.load();
  runApp(
    ProviderScope(
      overrides: [settingsProvider.overrideWith(() => SettingsNotifier(settings))],
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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4FD1FF), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const PilotScreen(),
    );
  }
}
