import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/proto.dart' as pb;
import 'package:hexapod_app/core/providers.dart';
import 'package:hexapod_app/features/nav/map_screen.dart';
import 'package:hexapod_app/features/nav/nav_chip.dart';

import 'helpers/app.dart';

pb.Position _here() => pb.Position()
  ..fix = true
  ..latitudeDeg = -23.5505
  ..longitudeDeg = -46.6333;

pb.NavStatus _idle() => pb.NavStatus()
  ..state = pb.NavState.NAV_STATE_IDLE
  ..homeSet = true
  ..home = (pb.GeoPoint()
    ..latitudeDeg = -23.5505
    ..longitudeDeg = -46.6333)
  ..driveEnabled = true;

void main() {
  late StreamController<pb.NavStatus> nav;
  late StreamController<GpsReading> gps;
  late List<pb.NavRequest> requests;

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          navStatusProvider.overrideWith((ref) => nav.stream),
          positionProvider.overrideWith((ref) => gps.stream),
          navRequestProvider.overrideWithValue(requests.add),
        ],
        child: testApp(home: home),
      ),
    );
  }

  // flutter_map tells a tap from a double tap: give it time to decide.
  Future<void> tapMap(WidgetTester tester, Offset at) async {
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 400));
  }

  setUp(() {
    nav = StreamController<pb.NavStatus>();
    gps = StreamController<GpsReading>();
    requests = [];
  });

  testWidgets('tap the map, then Go here sends the point', (tester) async {
    await pump(tester, const MapScreen(tiles: false));
    gps.add(GpsReading(_here()));
    nav.add(_idle());
    await tester.pump();
    await tester.pump();
    expect(find.text('Sem missão'), findsOneWidget);
    expect(find.text('Ir até aqui'), findsNothing);

    await tapMap(tester, const Offset(700, 200));
    await tester.tap(find.text('Ir até aqui'));
    expect(requests.single.action, pb.NavAction.NAV_ACTION_GO_TO);
    final p = requests.single.points.single;
    expect(p.latitudeDeg, greaterThan(-23.5505)); // up on a north-up map
    expect(p.longitudeDeg, greaterThan(-46.6333)); // right = east
  });

  testWidgets('a fence of three corners is drawn and saved', (tester) async {
    await pump(tester, const MapScreen(tiles: false));
    gps.add(GpsReading(_here()));
    nav.add(_idle());
    await tester.pump();
    await tester.tap(find.text('Cerca'));
    await tester.pump();
    expect(find.text('Toque no mapa para marcar os cantos da cerca'), findsOneWidget);
    for (final at in const [Offset(300, 150), Offset(650, 150), Offset(480, 380)]) {
      await tapMap(tester, at);
    }
    await tester.tap(find.text('Salvar'));
    expect(requests.single.action, pb.NavAction.NAV_ACTION_SET_FENCE);
    expect(requests.single.points, hasLength(3));
  });

  testWidgets('a refused request says why', (tester) async {
    await pump(tester, const MapScreen(tiles: false));
    nav.add(_idle()..homeSet = false);
    await tester.pump();
    await tester.tap(find.text('Voltar para casa'));
    expect(requests.single.action, pb.NavAction.NAV_ACTION_GO_HOME);
    nav.add(
      _idle()
        ..homeSet = false
        ..refused = pb.NavRefusal.NAV_REFUSAL_NO_HOME,
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('A casa ainda não foi marcada'), findsOneWidget);
  });

  testWidgets('during a mission: what it does, Cancel, and a note when driving is off', (tester) async {
    await pump(tester, const MapScreen(tiles: false));
    gps.add(GpsReading(_here()));
    nav.add(
      _idle()
        ..mission = pb.NavAction.NAV_ACTION_GO_HOME
        ..state = pb.NavState.NAV_STATE_DRIVING
        ..distanceM = 12
        ..target = _idle().home
        ..driveEnabled = false,
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Voltando para casa · A caminho · 12 m'), findsOneWidget);
    expect(find.textContaining('nav.drive'), findsOneWidget);
    await tester.tap(find.text('Cancelar missão'));
    expect(requests.single.action, pb.NavAction.NAV_ACTION_STOP);
  });

  testWidgets('the pilot screen chip: resume after a lost link, go home on a low battery', (tester) async {
    await pump(tester, const Scaffold(body: Center(child: NavChip())));
    nav.add(_idle());
    await tester.pump();
    await tester.pump();
    expect(find.byType(TextButton), findsNothing); // nothing to say

    nav.add(_idle()..resumable = true);
    await tester.pump();
    await tester.pump();
    expect(find.text('Missão interrompida (conexão perdida)'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Continuar missão'));
    expect(requests.last.action, pb.NavAction.NAV_ACTION_RESUME);

    nav.add(_idle()..batteryLow = true);
    await tester.pump();
    await tester.pump();
    expect(find.text('Bateria baixa: voltar para casa?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Voltar para casa'));
    expect(requests.last.action, pb.NavAction.NAV_ACTION_GO_HOME);
  });
}
