import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/link/robot_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('sends the key and reads the Wi-Fi state', () async {
    late http.Request seen;
    final api = RobotApi(
      '10.42.0.1',
      'KEY',
      client: MockClient((r) async {
        seen = r;
        return http.Response(
          jsonEncode({
            'mode': 'home',
            'state': 'own',
            'ssid': 'Hexapode-7F3A',
            'ip': '10.42.0.1',
            'ap_ssid': 'Hexapode-7F3A',
            'saved': ['Casa'],
            'error': 'Casa: senha incorreta',
          }),
          200,
        );
      }),
    );
    final s = await api.wifi();
    expect(seen.headers['Authorization'], 'Bearer KEY');
    expect(seen.url.toString(), 'http://10.42.0.1:8080/api/wifi');
    expect((s.state, s.apSsid, s.error), ('own', 'Hexapode-7F3A', 'Casa: senha incorreta'));
    expect(s.saved, ['Casa']);
  });

  test('join posts SSID and password as JSON', () async {
    late http.Request seen;
    final api = RobotApi(
      'r',
      'K',
      client: MockClient((r) async {
        seen = r;
        return http.Response('{"state":"connecting"}', 202);
      }),
    );
    await api.join('Café 2.4G', 'senha-certa');
    expect(seen.method, 'POST');
    expect(jsonDecode(seen.body), {'ssid': 'Café 2.4G', 'password': 'senha-certa'});
  });

  test('errors come back in words', () async {
    final refused = RobotApi('r', 'K', client: MockClient((_) async => http.Response('nope', 401)));
    await expectLater(refused.wifi(), throwsA(predicate((e) => e.toString().contains('pareie de novo'))));
    final bad = RobotApi(
      'r',
      'K',
      client: MockClient(
        (_) async => http.Response('{"error":"a senha do Wi-Fi tem de 8 a 63 caracteres"}', 400),
      ),
    );
    await expectLater(bad.join('Casa', 'x'), throwsA(predicate((e) => e.toString().contains('8 a 63'))));
  });
}
