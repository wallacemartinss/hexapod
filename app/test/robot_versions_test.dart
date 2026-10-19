import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/proto.dart';
import 'package:hexapod_app/features/settings/settings_sheet.dart';
import 'package:hexapod_app/l10n/l10n.dart';

void main() {
  test('settings show what the robot runs', () {
    final l = lookupAppLocalizations(const Locale('pt'));
    expect(robotVersions(l, null, connected: false), 'Robô: não conectado');
    expect(robotVersions(l, null, connected: true), 'Robô: conectado, aguardando as versões…');
    final both = Hello()
      ..firmwareVersion = 'f788762'
      ..hexdVersion = 'bb34ae8'
      ..protocolVersion = 1;
    expect(
      robotVersions(l, both, connected: true),
      'Robô: firmware f788762 · ponte (Pi) bb34ae8 · protocolo 1',
    );
    // hexd up, ESP32 not introduced yet
    expect(
      robotVersions(
        l,
        Hello()
          ..hexdVersion = 'bb34ae8'
          ..protocolVersion = 1,
        connected: true,
      ),
      'Robô: firmware aguardando o ESP32 · ponte (Pi) bb34ae8 · protocolo 1',
    );
  });
}
