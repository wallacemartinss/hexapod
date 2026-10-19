import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/proto.dart' as pb;
import 'package:hexapod_app/core/providers.dart';
import 'package:hexapod_app/features/follow/target_overlay.dart';

import 'helpers/app.dart';

pb.Targets _frame(List<pb.Target> targets) => pb.Targets()
  ..frameWidth = 960
  ..frameHeight = 540
  ..targets.addAll(targets);

pb.Target _marker(int id, {double x = 0.45, double distance = 1.2}) => pb.Target()
  ..trackId = id + 1
  ..markerId = id
  ..x = x
  ..y = 0.4
  ..w = 0.1
  ..h = 0.18
  ..distanceM = distance;

void main() {
  late StreamController<pb.Targets> targets;
  late StreamController<pb.FollowStatus> follow;
  late List<int> requests;

  Future<void> pumpOverlay(WidgetTester tester, {Size size = const Size(960, 540)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          targetsProvider.overrideWith((ref) => targets.stream),
          followStatusProvider.overrideWith((ref) => follow.stream),
          followRequestProvider.overrideWithValue(requests.add),
        ],
        child: testApp(home: const Scaffold(body: TargetOverlay(haptics: false))),
      ),
    );
  }

  setUp(() {
    targets = StreamController<pb.Targets>();
    follow = StreamController<pb.FollowStatus>();
    requests = [];
  });

  testWidgets('tap a target, then Follow asks the robot to lock onto it', (tester) async {
    await pumpOverlay(tester);
    targets.add(_frame([_marker(3), _marker(7, x: 0.1)]));
    await tester.pump();
    expect(find.text('Marcador 3 · 1,2 m'), findsOneWidget);
    expect(find.text('Toque num alvo para segui-lo'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('target-4')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('follow-start')));
    expect(requests, [4]);

    follow.add(
      pb.FollowStatus()
        ..state = pb.FollowState.FOLLOW_STATE_LOCKED
        ..trackId = 4,
    );
    await tester.pump();
    expect(find.text('Alvo travado: marcador 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('follow-cancel')));
    expect(requests, [4, 0]);
  });

  testWidgets('boxes land where the cropped video shows the target', (tester) async {
    // A 16:9 frame on a 2:1 screen: cover crops the top and bottom.
    await pumpOverlay(tester, size: const Size(1080, 540));
    targets.add(_frame([_marker(1, x: 0.5)]));
    await tester.pump();
    final box = tester.getRect(find.byKey(const ValueKey('target-2')));
    // scale 1080/960 = 1.125; marker 0.5..0.6 of 960 px -> 540..648 on screen, +8 margin each side.
    expect(box.left, closeTo(540 - 8, 0.5));
    expect(box.right, closeTo(648 + 8, 0.5));
  });

  testWidgets('lost target says so and still offers Cancel', (tester) async {
    await pumpOverlay(tester);
    targets.add(_frame([]));
    follow.add(
      pb.FollowStatus()
        ..state = pb.FollowState.FOLLOW_STATE_LOST
        ..trackId = 4,
    );
    await tester.pump();
    expect(find.text('Alvo fora de vista, aguardando…'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('follow-cancel')));
    expect(requests, [0]);
  });

  testWidgets('touches outside a box go through', (tester) async {
    var under = 0;
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          targetsProvider.overrideWith((ref) => targets.stream),
          followStatusProvider.overrideWith((ref) => follow.stream),
          followRequestProvider.overrideWithValue(requests.add),
        ],
        child: testApp(
          home: Stack(
            children: [
              Positioned.fill(child: GestureDetector(onTap: () => under++)),
              const Positioned.fill(child: TargetOverlay(haptics: false)),
            ],
          ),
        ),
      ),
    );
    targets.add(_frame([_marker(3)]));
    await tester.pump();
    await tester.tapAt(const Offset(50, 50));
    expect(under, 1);
  });
}
