// Integration test: the app's RobotLink against real hexd + hexsim binaries
// built from ../pi (needs Go). Skipped when Go is not installed.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hexapod_app/core/link/robot_link.dart';
import 'package:hexapod_app/core/proto.dart';

const _simPort = 27777;
const _httpPort = 28080;

Future<Process> _start(String exe, List<String> args) async {
  final p = await Process.start(exe, args);
  p.stdout.drain<void>();
  p.stderr.drain<void>();
  return p;
}

void main() {
  final pi = Directory('../pi').absolute.path;
  final bin = Directory.systemTemp.createTempSync('hexapod_app_test').path;
  final processes = <Process>[];
  final hasGo = Process.runSync('which', ['go']).exitCode == 0;

  setUpAll(() async {
    if (!hasGo) return;
    for (final (out, pkg) in [('hexsim', './hexsim'), ('hexd', './hexd/cmd/hexd')]) {
      final r = await Process.run('go', ['build', '-o', '$bin/$out', pkg], workingDirectory: pi);
      if (r.exitCode != 0) throw StateError('go build $pkg: ${r.stderr}');
    }
    File('$bin/hexd.yaml').writeAsStringSync('shutdown:\n  enabled: false\n');
    processes.add(
      await _start('$bin/hexsim', ['-listen', 'tcp://127.0.0.1:$_simPort', '-firmware', 'sim-app']),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    processes.add(
      await _start('$bin/hexd', [
        '-config',
        '$bin/hexd.yaml',
        '-serial',
        'tcp://127.0.0.1:$_simPort',
        '-listen',
        '127.0.0.1:$_httpPort',
      ]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });

  tearDownAll(() {
    for (final p in processes) {
      p.kill();
    }
  });

  test('connects, receives hello and telemetry, and drives the robot', () async {
    final link = RobotLink(Uri.parse('ws://127.0.0.1:$_httpPort/ws'));
    final hello = link.hello.first.timeout(const Duration(seconds: 5));
    final relaxed = link.telemetry.firstWhere((t) => t.state == State.STATE_RELAXED);
    await link.start();
    expect((await hello).firmwareVersion, 'sim-app');
    await relaxed.timeout(const Duration(seconds: 5));

    // 20 Hz like the app; hexd stamps the seq.
    final normal = link.telemetry.firstWhere((t) => t.state == State.STATE_NORMAL);
    final timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      link.send(Command()..mode = Mode.MODE_STAND);
    });
    final t = await normal.timeout(const Duration(seconds: 5));
    expect(t.lastCommandSeq, greaterThan(0));
    timer.cancel();

    // App goes silent: hexd's dead man's switch, then the robot's failsafe.
    await link.telemetry
        .firstWhere((t) => t.state == State.STATE_SAFE_SIT)
        .timeout(const Duration(seconds: 5));
    await link.close();
  }, skip: hasGo ? false : 'Go not installed');

  test('reports disconnected and retries when nothing listens', () async {
    final link = RobotLink(Uri.parse('ws://127.0.0.1:1/ws'));
    final statuses = <LinkStatus>[];
    final sub = link.status.listen(statuses.add);
    await link.start();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(statuses, contains(LinkStatus.disconnected));
    expect(statuses.where((s) => s == LinkStatus.connecting).length, greaterThan(1), reason: 'retries');
    link.send(Command()); // dropped silently while disconnected
    await sub.cancel();
    await link.close();
  });
}
