import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/link/robot_wifi.dart';
import 'package:hexapod_app/core/robots.dart';
import 'package:hexapod_app/features/robots/pair_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _code = 'HXP1 7F3A ABCDEFGHJKLMNPQRSTUV';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pairing code', () {
    test('reads the QR text and what a person types', () {
      expect(parsePairingCode(_code), (id: '7F3A', token: 'ABCDEFGHJKLMNPQRSTUV'));
      expect(parsePairingCode('  hxp1   7f3a abcdefghjklmnpqrstuv \n'), (
        id: '7F3A',
        token: 'ABCDEFGHJKLMNPQRSTUV',
      ));
    });

    test('rejects anything else', () {
      for (final bad in [
        '',
        'HXP1',
        'HXP2 7F3A ABCDEFGHJKLMNPQRSTUV',
        'HXP1 7F3A SHORT',
        'HXP1 7F3 ABCDEFGHJKLMNPQRSTUV',
        'https://example.com',
      ]) {
        expect(parsePairingCode(bad), isNull, reason: bad);
      }
    });
  });

  test('own network password matches hexd', () {
    // Pinned in pi/hexd/internal/pairing/pairing_test.go (and checked in Python).
    expect(ownNetwork('7F3A', 'ABCDEFGHJKLMNPQRSTUV'), (ssid: 'Hexapode-7F3A', password: 'KCGBVTPAD3HK'));
  });

  group('my robots', () {
    test('pair, switch, forget, and survive a restart', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(robotsProvider.notifier);
      await n.pair(const Robot(id: 'AAAA', name: 'Um', token: 'T1'));
      await n.pair(const Robot(id: 'BBBB', name: 'Dois', token: 'T2'));
      expect(c.read(robotsProvider).active?.id, 'BBBB'); // the newest is driven
      await n.select('AAAA');
      await n.seenAt('AAAA', '10.0.0.86');
      final saved = await RobotsNotifier.load();
      expect(saved.robots.map((r) => r.id), ['AAAA', 'BBBB']);
      expect(saved.active?.address, '10.0.0.86');
      await n.forget('AAAA');
      expect(c.read(robotsProvider).active?.id, 'BBBB');
    });

    test('pairing again replaces the old key', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final n = c.read(robotsProvider.notifier);
      await n.pair(const Robot(id: 'AAAA', name: 'Um', token: 'OLD'));
      await n.pair(const Robot(id: 'AAAA', name: 'Um', token: 'NEW'));
      expect(c.read(robotsProvider).robots.single.token, 'NEW');
    });
  });

  group('new robot screen', () {
    Future<ProviderContainer> open(WidgetTester tester, {required bool found, bool keyOk = true}) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: PairScreen(
              camera: false,
              finder: (id, _) async =>
                  found ? (id: id, name: 'Aranha', address: '10.0.0.86', port: 8080) : null,
              keyCheck: (_, _, _) async => keyOk,
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), _code);
      await tester.tap(find.text('Parear'));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('found and accepted: saved and ready', (tester) async {
      final c = await open(tester, found: true);
      expect(find.text('Pareado!'), findsOneWidget);
      final r = c.read(robotsProvider).active!;
      expect((r.id, r.name, r.token, r.address), ('7F3A', 'Aranha', 'ABCDEFGHJKLMNPQRSTUV', '10.0.0.86'));
    });

    testWidgets('key refused: nothing saved', (tester) async {
      final c = await open(tester, found: true, keyOk: false);
      expect(find.text('O robô recusou a chave'), findsOneWidget);
      expect(c.read(robotsProvider).robots, isEmpty);
    });

    testWidgets('a new robot is reached on its own Wi-Fi', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final wifi = _FakeWifi(joinOk: true);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: PairScreen(
              camera: false,
              wifi: wifi,
              // only answers on the robot's own network
              finder: (id, address) async =>
                  address == ownNetworkAddress ? (id: id, name: 'Novo', address: address!, port: 8080) : null,
              keyCheck: (_, _, _) async => true,
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), _code);
      await tester.tap(find.text('Parear'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 7)));
      await tester.pumpAndSettle();
      expect(wifi.joined, ('Hexapode-7F3A', 'KCGBVTPAD3HK'));
      expect(find.text('Pareado!'), findsOneWidget);
      expect(c.read(robotsProvider).active?.address, ownNetworkAddress);
    });

    testWidgets('a typo is caught before searching', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: const MaterialApp(home: PairScreen(camera: false)),
        ),
      );
      await tester.enterText(find.byType(TextField), 'HXP1 7F3A');
      await tester.tap(find.text('Parear'));
      await tester.pump();
      expect(find.textContaining('Código inválido'), findsOneWidget);
    });
  });
}

class _FakeWifi implements RobotWifi {
  _FakeWifi({required this.joinOk});

  final bool joinOk;
  (String, String)? joined;

  @override
  Future<bool> join(String ssid, String password) async {
    joined = (ssid, password);
    return joinOk;
  }

  @override
  Future<void> release() async {}
}
