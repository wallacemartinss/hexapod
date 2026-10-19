import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/app.dart';
import 'package:hexapod_app/core/link/discovery.dart';
import 'package:hexapod_app/core/link/robot_wifi.dart';
import 'package:hexapod_app/core/robots.dart';
import 'package:hexapod_app/features/robots/pair_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _maker = 'HXP1 7F3A ABCDEFGHJKLMNPQRSTUV';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('pairing input', () {
    test('the QR, the short code typed by hand, and the maker key', () {
      expect(parsePairingInput('HXP2 7F3A K7F2Q'), (id: '7F3A', code: 'K7F2Q', token: null));
      expect(parsePairingInput('  k7f2q \n'), (id: null, code: 'K7F2Q', token: null));
      expect(parsePairingInput(_maker), (id: '7F3A', code: null, token: 'ABCDEFGHJKLMNPQRSTUV'));
    });

    test('rejects anything else', () {
      for (final bad in [
        '',
        'K7F2',
        'K7F2QQ',
        'K0F2Q',
        'HXP2 7F3A K7F',
        'HXP3 7F3A K7F2Q',
        'https://example.com',
      ]) {
        expect(parsePairingInput(bad), isNull, reason: bad);
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
    FoundRobot robot(String address) => (id: '7F3A', name: 'Aranha', address: address, port: 8080);

    Future<ProviderContainer> open(
      WidgetTester tester,
      String typed, {
      RobotSearch? search,
      CodeTrade? trade,
      RobotWifi? wifi,
    }) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: testApp(
            home: PairScreen(
              camera: false,
              wifi: wifi,
              search: search ?? (_, _) async => [robot('10.0.0.86')],
              trade: trade ?? (_, _, code) async => code == 'K7F2Q' ? 'LONGKEY' : null,
              keyCheck: (_, _, token) async => token == 'ABCDEFGHJKLMNPQRSTUV',
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), typed);
      await tester.tap(find.text('Parear'));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 8)));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('the 5-character code is traded for the key', (tester) async {
      final c = await open(tester, 'k7f2q');
      expect(find.text('Pareado!'), findsOneWidget);
      final r = c.read(robotsProvider).active!;
      expect((r.id, r.name, r.token, r.address), ('7F3A', 'Aranha', 'LONGKEY', '10.0.0.86'));
    });

    testWidgets('a wrong code saves nothing', (tester) async {
      final c = await open(tester, 'ZZZZZ');
      expect(find.text('Código errado ou vencido'), findsOneWidget);
      expect(c.read(robotsProvider).robots, isEmpty);
    });

    testWidgets('the maker key still pairs', (tester) async {
      final c = await open(tester, _maker);
      expect(find.text('Pareado!'), findsOneWidget);
      expect(c.read(robotsProvider).active?.token, 'ABCDEFGHJKLMNPQRSTUV');
    });

    testWidgets('a new robot is reached on its open own Wi-Fi from the QR', (tester) async {
      final wifi = _FakeWifi(joinOk: true);
      final c = await open(
        tester,
        'HXP2 7F3A K7F2Q',
        wifi: wifi,
        search: (_, address) async => address == ownNetworkAddress ? [robot(address!)] : [],
      );
      expect(wifi.joined, ('Hexapode-7F3A', ''), reason: 'never paired: open network');
      expect(find.text('Pareado!'), findsOneWidget);
      expect(c.read(robotsProvider).active?.address, ownNetworkAddress);
    });

    testWidgets('a typed code without the id lets the user pick the robot network', (tester) async {
      final wifi = _FakeWifi(joinOk: true);
      await open(
        tester,
        'K7F2Q',
        wifi: wifi,
        search: (_, address) async => address == ownNetworkAddress ? [robot(address!)] : [],
      );
      expect(wifi.prefix, 'Hexapode-');
      expect(find.text('Pareado!'), findsOneWidget);
    });

    testWidgets('a typo is caught before searching', (tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: testApp(home: const PairScreen(camera: false)),
        ),
      );
      await tester.enterText(find.byType(TextField), 'K7F');
      await tester.tap(find.text('Parear'));
      await tester.pump();
      expect(find.textContaining('Digite as 5 letras'), findsOneWidget);
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

  String? prefix;

  @override
  Future<bool> joinPrefix(String prefix) async {
    this.prefix = prefix;
    return joinOk;
  }

  @override
  Future<void> release() async {}
}
