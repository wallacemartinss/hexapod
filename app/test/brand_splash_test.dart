import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'helpers/app.dart';
import 'package:hexapod_app/features/brand/brand.dart';

Future<void> _loadFonts() async {
  final flutterRoot = File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final loader = FontLoader('Roboto');
  for (final f in ['Roboto-Regular.ttf', 'Roboto-Medium.ttf']) {
    final bytes = File('$flutterRoot/bin/cache/artifacts/material_fonts/$f').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  }
  await loader.load();
}

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(2400, 1080);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    testApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: const BrandSplash(child: Text('pilot')),
    ),
  );
}

void main() {
  testWidgets('the splash covers the app, then fades away', (tester) async {
    await _pump(tester);
    expect(find.byType(BrandBackdrop), findsOneWidget);
    expect(find.text('pilot'), findsOneWidget); // built underneath from the start
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(find.byType(BrandBackdrop), findsNothing);
  });

  testWidgets('landscape splash', tags: ['golden'], (tester) async {
    await _loadFonts();
    await _pump(tester);
    await tester.runAsync(
      () => precacheImage(
        const AssetImage('assets/brand/splash_logo.png'),
        tester.element(find.byType(BrandSplash)),
      ),
    );
    await tester.pump();
    await expectLater(find.byType(BrandSplash), matchesGoldenFile('goldens/splash.png'));
    await tester.pump(const Duration(seconds: 3));
  });
}
