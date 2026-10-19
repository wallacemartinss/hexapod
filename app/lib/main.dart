import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'core/robots.dart';
import 'core/providers.dart';
import 'core/settings.dart';
import 'features/brand/brand.dart';
import 'features/pilot/pilot_screen.dart';
import 'l10n/l10n.dart';

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

class HexapodApp extends ConsumerWidget {
  const HexapodApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(settingsProvider.select((s) => s.language));
    return MaterialApp(
      onGenerateTitle: (context) => context.l10n.appTitle,
      debugShowCheckedModeBanner: false,
      locale: localeFor(language),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: Brand.cyan, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const BrandSplash(child: PilotScreen()),
    );
  }
}
