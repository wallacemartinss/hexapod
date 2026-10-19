import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/link/robot_link.dart';
import 'package:hexapod_app/core/proto.dart';
import 'package:hexapod_app/core/providers.dart';
import 'package:hexapod_app/core/settings.dart';
import 'package:hexapod_app/features/settings/settings_sheet.dart';
import 'package:hexapod_app/l10n/l10n.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('choosing English in the settings switches the app right away', (tester) async {
    tester.view.physicalSize = const Size(2400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => SettingsNotifier(const Settings(language: 'pt'))),
        // No robot under test.
        linkStatusProvider.overrideWith((ref) => Stream.value(LinkStatus.connecting)),
        helloProvider.overrideWith((ref) => const Stream<Hello>.empty()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) => testApp(
            // Like main.dart: the app locale follows the setting.
            locale: localeFor(ref.watch(settingsProvider).language) ?? const Locale('pt'),
            home: Scaffold(
              body: Builder(
                builder: (context) =>
                    TextButton(onPressed: () => showSettingsSheet(context), child: const Text('open')),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Ajustes'), findsOneWidget);
    expect(find.text('Idioma'), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Ajustes'), findsNothing);
    expect(container.read(settingsProvider).language, 'en');
    expect((await SharedPreferences.getInstance()).getString('language'), 'en');
  });
}
