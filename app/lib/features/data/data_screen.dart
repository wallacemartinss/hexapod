import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/link/robot_link.dart';
import '../../core/proto.dart' as pb;
import '../../core/providers.dart';
import '../pilot/state_texts.dart';
import 'telemetry_log.dart';

const _bg = Color(0xFF0E1013);
const _card = Color(0xFF171A1F);
const _accent = Color(0xFF4FD1FF);

Future<void> showDataScreen(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DataScreen()));

/// Everything the robot reports, in tabs. Sensors not fitted yet say so
/// instead of showing zeros. Commands keep flowing underneath (the pilot
/// screen stays alive), so STOP is at hand here too.
class DataScreen extends ConsumerStatefulWidget {
  const DataScreen({super.key});

  @override
  ConsumerState<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends ConsumerState<DataScreen> {
  final _log = TelemetryLog();
  // package:clock, so tests with simulated time get real-looking charts.
  final _start = clock.now();
  Duration get _elapsed => clock.now().difference(_start);
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    final now = ref.read(telemetryProvider).value;
    if (now != null) _log.add(_elapsed, now);
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(telemetryProvider, (_, next) {
      final t = next.value;
      if (t != null) _log.add(_elapsed, t);
    });
    final link = ref.watch(linkStatusProvider).value ?? LinkStatus.connecting;
    final hello = ref.watch(helloProvider).value;
    final t = _log.last;
    final now = _elapsed;

    const tabs = [
      (Icons.dashboard_rounded, 'Resumo'),
      (Icons.explore_rounded, 'Orientação'),
      (Icons.radar_rounded, 'Distância'),
      (Icons.thermostat_rounded, 'Ambiente'),
      (Icons.pest_control_rounded, 'Pernas'),
      (Icons.memory_rounded, 'Sistema'),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          foregroundColor: Colors.white,
          title: const Text('Dados do robô'),
          actions: [
            if (t != null) _StateChip(t.state),
            const SizedBox(width: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE5383B),
                foregroundColor: Colors.white,
              ),
              onPressed: ref.read(controlProvider.notifier).stop,
              child: const Text('PARAR', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 16),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: _accent,
            unselectedLabelColor: Colors.white60,
            indicatorColor: _accent,
            tabs: [
              for (final (icon, label) in tabs)
                Tab(child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)])),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: t == null
              ? Center(
                  child: Text(
                    link == LinkStatus.connected ? 'Aguardando dados do robô…' : 'Sem conexão com o robô',
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                )
              : TabBarView(
                  children: [
                    _SummaryTab(t, _log, now),
                    _OrientationTab(t, _log, now),
                    _DistanceTab(t),
                    _EnvironmentTab(t),
                    _LegsTab(t),
                    _SystemTab(t, _log, now, hello),
                  ],
                ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- tabs ---

class _SummaryTab extends StatelessWidget {
  const _SummaryTab(this.t, this.log, this.now);

  final pb.Telemetry t;
  final TelemetryLog log;
  final Duration now;

  @override
  Widget build(BuildContext context) {
    final state = describeState(t.state);
    final faults = [
      if (t.gasAlarm && Part.gas.presentIn(t)) 'GÁS OU FUMAÇA DETECTADO',
      for (final (bit, text) in faultTexts)
        if (t.faultFlags & bit != 0) text,
    ];
    return _Grid([
      _Card(
        icon: Icons.smart_toy_rounded,
        title: 'Estado',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              state.label,
              style: TextStyle(
                color: severityColor(state.severity),
                fontSize: 26,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            _Row('Modo', _modeName(t.mode)),
            _Row('Marcha', _gaitName(t.gait)),
            _Row('Ligado há', formatUptime(t.uptimeMs)),
          ],
        ),
      ),
      if (Part.power.presentIn(t))
        _Card(
          icon: Icons.battery_full_rounded,
          title: 'Bateria',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Big('${batteryPercent(t.batteryVoltageV)}', '%'),
              _Row('Tensão', '${t.batteryVoltageV.toStringAsFixed(2)} V'),
              _Row('Por célula', '${(t.batteryVoltageV / 3).toStringAsFixed(2)} V'),
              _Row('Corrente', '${t.batteryCurrentA.toStringAsFixed(2)} A'),
              const _Note('A corrente só vale com o shunt certo no INA226.'),
            ],
          ),
        )
      else
        const _Absent(Part.power),
      _Card(
        icon: Icons.wifi_rounded,
        title: 'Link com o robô',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Big(log.rateHz(now).toStringAsFixed(0), 'Hz'),
            const _Note('Telemetria esperada: 10 Hz'),
            _Row('Recebidas', '${log.received}'),
            _Row('Perdidas', '${log.lost}'),
            _Row('Último comando aceito', '#${t.lastCommandSeq}'),
          ],
        ),
      ),
      _Card(
        icon: Icons.warning_amber_rounded,
        title: 'Avisos',
        child: faults.isEmpty
            ? const Text('Nenhum', style: TextStyle(color: Colors.white70))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final f in faults)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $f', style: const TextStyle(color: Color(0xFFFFB547), fontSize: 13)),
                    ),
                ],
              ),
      ),
    ]);
  }
}

class _OrientationTab extends StatelessWidget {
  const _OrientationTab(this.t, this.log, this.now);

  final pb.Telemetry t;
  final TelemetryLog log;
  final Duration now;

  @override
  Widget build(BuildContext context) {
    if (!Part.imu.presentIn(t)) return const _Grid([_Absent(Part.imu, wide: true)]);
    final q = t.orientation;
    return _Grid([
      _Card(
        icon: Icons.flight_rounded,
        title: 'Horizonte',
        child: SizedBox(
          height: 170,
          child: CustomPaint(painter: _HorizonPainter(t.rollDeg, t.pitchDeg), size: Size.infinite),
        ),
      ),
      _Card(
        icon: Icons.threed_rotation_rounded,
        title: 'Ângulos',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row('Rolagem (direita +)', '${t.rollDeg.toStringAsFixed(1)}°'),
            _Row('Arfagem (nariz para baixo +)', '${t.pitchDeg.toStringAsFixed(1)}°'),
            _Row('Guinada', '${t.yawDeg.toStringAsFixed(1)}°'),
            const SizedBox(height: 6),
            _Row(
              'Quaternion',
              '${q.w.toStringAsFixed(3)}, ${q.x.toStringAsFixed(3)}, '
                  '${q.y.toStringAsFixed(3)}, ${q.z.toStringAsFixed(3)}',
            ),
            const _Note('Acima de 35° o robô relaxa as pernas (TOMBADO).'),
          ],
        ),
      ),
      _Card(
        icon: Icons.show_chart_rounded,
        title: 'Últimos 30 s',
        child: _Chart(
          lines: [
            (log.series(now, (t) => t.rollDeg), _accent, 'rolagem'),
            (log.series(now, (t) => t.pitchDeg), const Color(0xFFC77DFF), 'arfagem'),
          ],
          min: -40,
          max: 40,
          unit: '°',
        ),
      ),
    ]);
  }
}

class _DistanceTab extends StatelessWidget {
  const _DistanceTab(this.t);

  final pb.Telemetry t;

  @override
  Widget build(BuildContext context) {
    if (!Part.distance.presentIn(t)) return const _Grid([_Absent(Part.distance, wide: true)]);
    const names = ['Frente', 'Direita', 'Trás', 'Esquerda'];
    return _Grid([
      for (var i = 0; i < names.length; i++)
        _DistanceCard(
          name: names[i],
          mm: i < t.distancesMm.length ? t.distancesMm[i] : 0,
          blocked: t.blockedMask & (1 << i) != 0,
        ),
    ]);
  }
}

class _EnvironmentTab extends StatelessWidget {
  const _EnvironmentTab(this.t);

  final pb.Telemetry t;

  @override
  Widget build(BuildContext context) {
    final esp = _Card(
      icon: Icons.memory_rounded,
      title: 'Chip do ESP32',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Big(t.esp32TemperatureC.toStringAsFixed(1), '°C'),
          const _Note('Sensor interno: lê alguns graus acima do ambiente.'),
        ],
      ),
    );
    // A firmware older than the MQ-2 never sets its fault bit: all-zero
    // readings mean "not there" (a real ADC never reads exactly 0).
    final gasRead = t.gasLevelPct > 0 || t.gasWarming || t.gasAlarm;
    final gas = Part.gas.presentIn(t) && gasRead ? _GasCard(t) : const _Absent(Part.gas);
    if (!Part.environment.presentIn(t) || t.pressureHpa == 0) {
      return _Grid([const _Absent(Part.environment), gas, esp]);
    }
    return _Grid([
      _Card(
        icon: Icons.thermostat_rounded,
        title: 'Temperatura',
        child: _Big(t.temperatureC.toStringAsFixed(1), '°C'),
      ),
      _Card(
        icon: Icons.water_drop_rounded,
        title: 'Umidade',
        child: _Big(t.humidityPct.toStringAsFixed(0), '%'),
      ),
      _Card(
        icon: Icons.speed_rounded,
        title: 'Pressão',
        child: _Big(t.pressureHpa.toStringAsFixed(0), 'hPa'),
      ),
      gas,
      esp,
    ]);
  }
}

class _LegsTab extends StatelessWidget {
  const _LegsTab(this.t);

  final pb.Telemetry t;

  @override
  Widget build(BuildContext context) {
    const legs = [
      'Esquerda dianteira',
      'Esquerda do meio',
      'Esquerda traseira',
      'Direita dianteira',
      'Direita do meio',
      'Direita traseira',
    ];
    final a = t.jointAnglesDeg;
    String angle(int leg, int joint) {
      final i = leg * 3 + joint;
      return i < a.length ? '${a[i].toStringAsFixed(1)}°' : '—';
    }

    TableRow row(List<String> cells, {bool header = false}) => TableRow(
      children: [
        for (final c in cells)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
            child: Text(
              c,
              style: TextStyle(
                color: header ? Colors.white54 : Colors.white,
                fontWeight: header ? FontWeight.w600 : FontWeight.w500,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );

    return _Grid([
      _Card(
        icon: Icons.pest_control_rounded,
        title: 'Ângulos comandados',
        wide: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Table(
              columnWidths: const {0: FlexColumnWidth(2)},
              children: [
                row(['Perna', 'Coxa', 'Fêmur', 'Tíbia'], header: true),
                for (var l = 0; l < legs.length; l++)
                  row(['$l · ${legs[l]}', angle(l, 0), angle(l, 1), angle(l, 2)]),
              ],
            ),
            const _Note(
              'O que o ESP32 calcula a cada ciclo, mesmo com os servos desligados (marcha "no papel").',
            ),
          ],
        ),
      ),
    ]);
  }
}

class _SystemTab extends StatelessWidget {
  const _SystemTab(this.t, this.log, this.now, this.hello);

  final pb.Telemetry t;
  final TelemetryLog log;
  final Duration now;
  final pb.Hello? hello;

  @override
  Widget build(BuildContext context) {
    final h = hello;
    return _Grid([
      _Card(
        icon: Icons.info_outline_rounded,
        title: 'Software',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row('Firmware (ESP32)', h == null || h.firmwareVersion.isEmpty ? '—' : h.firmwareVersion),
            _Row('Ponte (Pi)', h == null || h.hexdVersion.isEmpty ? '—' : h.hexdVersion),
            _Row('Protocolo', h == null ? '—' : '${h.protocolVersion}'),
            _Row('ESP32 ligado há', formatUptime(t.uptimeMs)),
          ],
        ),
      ),
      _Card(
        icon: Icons.timer_rounded,
        title: 'Laço de controle (50 Hz)',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Big((t.loopTimeUs / 1000).toStringAsFixed(2), 'ms'),
            const _Note('Limite: 20 ms por ciclo'),
            const SizedBox(height: 8),
            _Chart(
              lines: [(log.series(now, (t) => t.loopTimeUs / 1000), _accent, 'ms')],
              min: 0,
              max: math.max(1, (t.loopTimeUs / 1000) * 2).toDouble(),
              unit: ' ms',
              height: 90,
            ),
          ],
        ),
      ),
      _Card(
        icon: Icons.fact_check_rounded,
        title: 'Verificações',
        child: Column(
          children: [
            for (final (bit, text) in faultChecks)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  children: [
                    Icon(
                      t.faultFlags & bit != 0 ? Icons.error_rounded : Icons.check_circle_rounded,
                      size: 16,
                      color: t.faultFlags & bit != 0 ? const Color(0xFFFFB547) : const Color(0xFF3DDC97),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ]);
  }
}

// ------------------------------------------------------------- widgets ---

/// Cards in rows: side by side on a landscape phone, stacked when narrow.
/// Every card in a row takes the height of the tallest, so edges line up.
class _Grid extends StatelessWidget {
  const _Grid(this.cards);

  final List<Widget> cards;

  static bool _isWide(Widget c) => (c is _Card && c.wide) || (c is _Absent && c.wide);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth > 900 ? 3 : (box.maxWidth > 560 ? 2 : 1);
        const gap = 12.0;
        // Wide cards get a row of their own; the rest fill rows of [columns].
        final rows = <List<Widget>>[];
        for (final c in cards) {
          if (_isWide(c)) {
            rows.add([c]);
          } else if (rows.isEmpty || _isWide(rows.last.first) || rows.last.length == columns) {
            rows.add([c]);
          } else {
            rows.last.add(c);
          }
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              for (final (i, row) in rows.indexed) ...[
                if (i > 0) const SizedBox(height: gap),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var k = 0; k < (_isWide(row.first) ? 1 : columns); k++) ...[
                        if (k > 0) const SizedBox(width: gap),
                        Expanded(child: k < row.length ? row[k] : const SizedBox()),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.icon, required this.title, required this.child, this.wide = false});

  final IconData icon;
  final String title;
  final Widget child;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: _accent),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

/// A sensor not fitted yet (or not answering): says which chip, instead of
/// zeros that look like readings.
class _Absent extends StatelessWidget {
  const _Absent(this.part, {this.wide = false});

  final Part part;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return _Card(
      icon: Icons.sensors_off_rounded,
      title: part.label,
      wide: wide,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${part.chip} não instalado',
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'Ou não está respondendo. Os dados aparecem aqui sozinhos quando ele for ligado.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _Big extends StatelessWidget {
  const _Big(this.value, this.unit);

  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          value,
          style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 4),
        Text(unit, style: const TextStyle(color: Colors.white54, fontSize: 15)),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(text, style: const TextStyle(color: Colors.white38, fontSize: 11)),
  );
}

class _StateChip extends StatelessWidget {
  const _StateChip(this.state);

  final pb.State state;

  @override
  Widget build(BuildContext context) {
    final s = describeState(state);
    final color = severityColor(s.severity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        s.label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 13),
      ),
    );
  }
}

/// MQ-2: relative level (not ppm), warm-up and the alarm.
class _GasCard extends StatelessWidget {
  const _GasCard(this.t);

  final pb.Telemetry t;

  @override
  Widget build(BuildContext context) {
    const danger = Color(0xFFFF5A5F);
    final color = t.gasAlarm
        ? danger
        : t.gasWarming
        ? Colors.white38
        : const Color(0xFF3DDC97);
    return _Card(
      icon: Icons.local_fire_department_rounded,
      title: 'Gás e fumaça',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Big(t.gasLevelPct.toStringAsFixed(0), '% do sensor'),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (t.gasLevelPct / 100).clamp(0.0, 1.0),
              minHeight: 8,
              color: color,
              backgroundColor: Colors.white10,
            ),
          ),
          const SizedBox(height: 6),
          if (t.gasAlarm)
            const Text(
              'GÁS OU FUMAÇA DETECTADO',
              style: TextStyle(color: danger, fontSize: 13, fontWeight: FontWeight.w800),
            )
          else if (t.gasWarming)
            const Text(
              'Aquecendo o sensor: leituras confiáveis em alguns minutos',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            )
          else
            const Text('Ar normal', style: TextStyle(color: Color(0xFF3DDC97), fontSize: 12)),
          const _Note('Nível relativo ao ar limpo, não em ppm.'),
        ],
      ),
    );
  }
}

class _DistanceCard extends StatelessWidget {
  const _DistanceCard({required this.name, required this.mm, required this.blocked});

  final String name;
  final int mm;
  final bool blocked;

  @override
  Widget build(BuildContext context) {
    const full = 2000; // mm shown as a full bar
    final color = blocked
        ? const Color(0xFFFF5A5F)
        : mm < 450
        ? const Color(0xFFFFB547)
        : const Color(0xFF3DDC97);
    return _Card(
      icon: Icons.straighten_rounded,
      title: name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Big(mm >= 8000 || mm == 0 ? '—' : '$mm', mm >= 8000 || mm == 0 ? 'fora de alcance' : 'mm'),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (mm.clamp(0, full) / full).toDouble(),
              minHeight: 8,
              color: color,
              backgroundColor: Colors.white10,
            ),
          ),
          if (blocked) ...[
            const SizedBox(height: 6),
            const Text(
              'BLOQUEADO: o robô não anda para este lado',
              style: TextStyle(color: Color(0xFFFF5A5F), fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ],
        ],
      ),
    );
  }
}

/// Line chart of the last seconds; x in seconds before now (negative).
class _Chart extends StatelessWidget {
  const _Chart({
    required this.lines,
    required this.min,
    required this.max,
    required this.unit,
    this.height = 140,
  });

  final List<(List<(double, double)>, Color, String)> lines;
  final double min;
  final double max;
  final String unit;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          child: CustomPaint(painter: _ChartPainter(lines, min, max), size: Size.infinite),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final (_, color, label) in lines) ...[
              Container(width: 10, height: 3, color: color),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(width: 12),
            ],
            const Spacer(),
            Text(
              '${min.toStringAsFixed(0)} a ${max.toStringAsFixed(0)}$unit · 30 s',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.lines, this.min, this.max);

  final List<(List<(double, double)>, Color, String)> lines;
  final double min;
  final double max;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (final (points, color, _) in lines) {
      if (points.length < 2) continue;
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final (sec, v) = points[i];
        final x = size.width * (1 + sec / 30);
        final y = size.height * (1 - ((v - min) / (max - min)).clamp(0.0, 1.0));
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_ChartPainter old) => true;
}

/// Artificial horizon: the ground tilts with the robot's roll and slides
/// with its pitch.
class _HorizonPainter extends CustomPainter {
  _HorizonPainter(this.rollDeg, this.pitchDeg);

  final double rollDeg;
  final double pitchDeg;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-rollDeg * math.pi / 180);
    final shift = (pitchDeg / 45).clamp(-1.0, 1.0) * r;
    canvas.drawRect(Rect.fromLTRB(-2 * r, -2 * r, 2 * r, shift), Paint()..color = const Color(0xFF1F4E79));
    canvas.drawRect(Rect.fromLTRB(-2 * r, shift, 2 * r, 2 * r), Paint()..color = const Color(0xFF6B4A2B));
    canvas.drawLine(
      Offset(-2 * r, shift),
      Offset(2 * r, shift),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
    canvas.restore();
    final mark = Paint()
      ..color = const Color(0xFFFFB547)
      ..strokeWidth = 3;
    canvas.drawLine(c.translate(-r * 0.5, 0), c.translate(-r * 0.15, 0), mark);
    canvas.drawLine(c.translate(r * 0.15, 0), c.translate(r * 0.5, 0), mark);
    canvas.drawCircle(c, 3, mark);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_HorizonPainter old) => old.rollDeg != rollDeg || old.pitchDeg != pitchDeg;
}

String _modeName(pb.Mode m) => switch (m) {
  pb.Mode.MODE_SIT => 'Sentado',
  pb.Mode.MODE_STAND => 'Em pé (pose)',
  pb.Mode.MODE_WALK => 'Andando',
  pb.Mode.MODE_CALIBRATE => 'Calibração',
  pb.Mode.MODE_FRONT_LEGS => 'Patas',
  _ => '—',
};

String _gaitName(pb.Gait g) => switch (g) {
  pb.Gait.GAIT_TRIPOD => 'Tripé',
  pb.Gait.GAIT_WAVE => 'Onda',
  pb.Gait.GAIT_RIPPLE => 'Ripple',
  _ => '—',
};
