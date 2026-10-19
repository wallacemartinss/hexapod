import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/link/robot_api.dart';
import 'package:hexapod_app/core/providers.dart';
import 'package:hexapod_app/features/gallery/gallery_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers/app.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAADCAIAAAA7ljmRAAAAEElEQVR4nGPQqDgBRww4OQBBxhDhzXmo9QAAAABJRU5ErkJggg==',
);

void main() {
  test('clip and size labels', () {
    expect(formatClip(7), '0:07');
    expect(formatClip(754), '12:34');
    expect(formatClip(3725), '1:02:05');
    expect(formatBytes(850 * 1024), '850 KB');
    expect(formatBytes(5 * 1024 * 1024 + 300000), '5.3 MB');
  });

  testWidgets('list, save to the phone, delete, change the quality', (tester) async {
    tester.view.physicalSize = const Size(2400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final items = [
      {
        'name': 'video-20261019-092000.mp4',
        'kind': 'video',
        'size': 5242880,
        'created': '2026-10-19T09:20:00-03:00',
        'duration_s': 34,
      },
      {
        'name': 'photo-20261019-091500.jpg',
        'kind': 'photo',
        'size': 420000,
        'created': '2026-10-19T09:15:00-03:00',
      },
    ];
    var quality = '720p';
    final calls = <String>[];
    final api = RobotApi(
      '10.42.0.1',
      'KEY',
      client: MockClient.streaming((r, body) async {
        calls.add('${r.method} ${r.url.path}${r.url.hasQuery ? '?${r.url.query}' : ''}');
        http.StreamedResponse json(Object v) =>
            http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(v))), 200);
        switch ((r.method, r.url.path)) {
          case ('GET', '/api/media'):
            return json({'recording': false, 'free_mb': 30720, 'items': items});
          case ('GET', '/api/camera'):
            return json({'quality': quality});
          case ('POST', '/api/camera'):
            quality = jsonDecode(utf8.decode(await body.toBytes()))['quality'] as String;
            return json({'quality': quality});
          case ('DELETE', final p):
            items.removeWhere((i) => p.endsWith(i['name']! as String));
            return json({'deleted': p});
          case ('GET', _) when r.url.queryParameters['thumb'] == '1':
            return http.StreamedResponse(Stream.value(_png), 200);
          case ('GET', final p) when p.startsWith('/api/media/files/'):
            return http.StreamedResponse(
              Stream.value(utf8.encode('FILE ${p.split('/').last}')),
              200,
              contentLength: 30,
            );
        }
        return http.StreamedResponse(const Stream.empty(), 404);
      }),
    );
    final saved = <(String, bool)>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [robotApiProvider.overrideWithValue(api)],
        child: testApp(
          home: GalleryScreen(
            saver: (file, {required video}) async => saved.add((file.readAsStringSync(), video)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 itens · 30.0 GB livres no robô'), findsOneWidget);
    expect(find.text('0:34'), findsOneWidget); // the video's length
    expect(calls, contains('GET /api/media/files/photo-20261019-091500.jpg?thumb=1'));

    // Select both, save them to the phone.
    await tester.longPress(find.text('0:34'));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.photo_rounded));
    await tester.pump();
    expect(find.text('2 selecionados'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byTooltip('Salvar no celular'));
      for (var i = 0; i < 20 && saved.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
    expect(saved, [('FILE video-20261019-092000.mp4', true), ('FILE photo-20261019-091500.jpg', false)]);
    expect(find.textContaining('2 salvos na galeria do celular'), findsOneWidget);
    expect(Directory.systemTemp.listSync().where((f) => f.path.endsWith('20261019-092000.mp4')), isEmpty);

    // Delete the photo.
    await tester.longPress(find.byIcon(Icons.photo_rounded));
    await tester.pump();
    await tester.tap(find.byTooltip('Apagar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Apagar'));
    await tester.pumpAndSettle();
    expect(calls, contains('DELETE /api/media/files/photo-20261019-091500.jpg'));
    expect(find.text('1 item · 30.0 GB livres no robô'), findsOneWidget);

    // 1080p.
    await tester.tap(find.text('1080p'));
    await tester.pumpAndSettle();
    expect(quality, '1080p');
    await tester.pumpWidget(const SizedBox()); // stop the poll
  });
}
