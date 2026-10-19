import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/link/robot_api.dart';
import 'package:hexapod_app/core/link/tailnet.dart';
import 'package:hexapod_app/core/robots.dart';
import 'package:hexapod_app/features/robots/remote_access_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/app.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('tailnet addresses', () {
    expect(isTailnetAddress('100.115.230.65'), isTrue);
    expect(isTailnetAddress('100.64.0.1'), isTrue);
    expect(isTailnetAddress('100.128.0.1'), isFalse);
    expect(isTailnetAddress('10.0.0.86'), isFalse);
  });

  testWidgets('connect the robot: open the login link, then it runs and is saved', (tester) async {
    tester.view.physicalSize = const Size(2400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var state = 'needs_login';
    final posted = <String>[];
    final api = RobotApi(
      '10.0.0.86',
      'KEY',
      client: MockClient((r) async {
        if (r.method == 'POST') posted.add(r.url.path);
        if (r.url.path == '/api/tailscale/login') {
          return http.Response(
            jsonEncode({'state': 'needs_login', 'auth_url': 'https://login.tailscale.com/a/x'}),
            200,
          );
        }
        if (r.url.path == '/api/tailscale/logout') {
          state = 'needs_login';
          return http.Response('{"state":"needs_login"}', 200);
        }
        return http.Response(
          jsonEncode(
            state == 'running'
                ? {
                    'state': 'running',
                    'name': 'hexapod-k7f2',
                    'ip': '100.115.230.65',
                    'account': 'owner@example.com',
                  }
                : {'state': state},
          ),
          200,
        );
      }),
    );
    final opened = <Uri>[];
    var phoneIn = false;
    final container = ProviderContainer(
      overrides: [
        robotsProvider.overrideWith(
          () => RobotsNotifier(
            const RobotsState(
              robots: [Robot(id: 'K7F2', name: 'Aranha', token: 'KEY')],
              activeId: 'K7F2',
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(
          home: RemoteAccessScreen(
            api: () => api,
            onTailnet: () async => phoneIn,
            open: (u) async {
              opened.add(u);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Conectar o robô'), findsOneWidget);
    expect(find.text('Instalar o Tailscale'), findsOneWidget);

    await tester.tap(find.text('Conectar o robô'));
    await tester.pumpAndSettle();
    expect(posted, ['/api/tailscale/login']);
    expect(opened.single.toString(), 'https://login.tailscale.com/a/x');
    expect(find.text('Abrir o link de novo'), findsOneWidget);

    // The owner logged in in the browser, and installed Tailscale on the phone.
    state = 'running';
    phoneIn = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('No Tailscale como hexapod-k7f2'), findsOneWidget);
    expect(find.text('Este celular está no Tailscale.'), findsOneWidget);
    expect(find.textContaining('Pronto'), findsOneWidget);
    expect(container.read(robotsProvider).active?.remote, '100.115.230.65');

    await tester.tap(find.text('Desconectar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Desconectar'));
    await tester.pumpAndSettle();
    expect(posted.last, '/api/tailscale/logout');
    expect(container.read(robotsProvider).active?.remote, isNull);
    await tester.pumpWidget(const SizedBox()); // stop the poll timer
  });
}
