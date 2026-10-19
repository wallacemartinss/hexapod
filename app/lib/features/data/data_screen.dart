import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/link/robot_link.dart';
import '../../core/proto.dart' as pb;
import '../../core/providers.dart';
import '../pilot/state_texts.dart';
import '../../l10n/l10n.dart';
import 'telemetry_log.dart';

const _bg = Color(0xFF0C1428);
const _card = Color(0xFF121C34);
const _accent = Color(0xFF3FCDF5);

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
  final _pi = PiLog();
  // package:clock, so tests with simulated time get real-looking charts.
  final _start = clock.now();
  Duration get _elapsed => clock.now().difference(_start);

  /// When the last GPS position arrived (null: none since the screen opened).
  Duration? _positionAt;
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    final now = ref.read(telemetryProvider).value;
    if (now != null) _log.add(_elapsed, now);
    if (ref.read(positionProvider).value != null) _positionAt = _elapsed;
    final pi = ref.read(piStatusProvider).value;
    if (pi != null) _pi.add(_elapsed, pi.status);
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
    ref.listen(positionProvider, (_, _) => _positionAt = _elapsed);
    ref.listen(piStatusProvider, (_, next) {
      final pi = next.value;
      if (pi != null) _pi.add(_elapsed, pi.status);
    });
    final position = ref.watch(positionProvider).value?.position;
    ref.watch(piStatusProvider); // a listen alone does not start the stream
    final gpsTalking = _positionAt != null && _elapsed - _positionAt! < const Duration(seconds: 3);
    final link = ref.watch(linkStatusProvider).value ?? LinkStatus.connecting;
    final hello = ref.watch(helloProvider).value;
    final t = _log.last;
    final now = _elapsed;

    const tabs = [
      (Icons.dashboard_rounded, 'Resumo'),
      (Icons.explore_rounded, 'Orientação'),
      (Icons.radar_rounded, 'Distância'),
      (Icons.place_rounded, 'Posição'),
      (Icons.thermostat_rounded, 'Ambiente'),
      (Icons.pest_control_rounded, 'Pernas'),
      (Icons.memory_rounded, 'Sistema'),
      (Icons.developer_board_rounded, 'Raspberry Pi'),
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
                    _PositionTab(gpsTalking ? position : null),
                    _EnvironmentTab(t),
                    _LegsTab(t),
                    _SystemTab(t, _log, now, hello),
                    _PiTab(_pi, now),
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
    final state = describeState(context.l10n, t.state);
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

class _PositionTab extends StatelessWidget {
  const _PositionTab(this.p);

  /// null: no GPS, or it went quiet.
  final pb.Position? p;

  @override
  Widget build(BuildContext context) {
    final p = this.p;
    if (p == null) {
      return const _Grid([
        _Card(
          icon: Icons.location_off_rounded,
          title: 'GPS',
          wide: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'GPS (NEO-6M) sem resposta',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 4),
              Text(
                'Não instalado, ou o fio TX do GPS não chega ao pino 10 do Pi.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ]);
    }
    final satellites = _Card(
      icon: Icons.satellite_alt_rounded,
      title: 'Satélites e precisão',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Big('${p.satellitesUsed}', 'em uso · ${p.satellitesInView} visíveis'),
          if (p.fix) _Row('Precisão (HDOP)', '${p.hdop.toStringAsFixed(1)} · ${_hdopText(p.hdop)}'),
          if (p.fix) _Row('Altitude', '${p.altitudeM.toStringAsFixed(0)} m'),
          if (p.utcMs > 0) _Row('Hora do GPS', _clockText(p.utcMs.toInt())),
        ],
      ),
    );
    if (!p.fix) {
      return _Grid([
        const _Card(
          icon: Icons.gps_not_fixed_rounded,
          title: 'Posição',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Procurando satélites…',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
              ),
              SizedBox(height: 6),
              Text(
                'Precisa de céu aberto: perto de uma janela ou ao ar livre. A primeira posição pode levar '
                'alguns minutos; o LED do GPS pisca quando encontra.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
        satellites,
      ]);
    }
    final coords = '${p.latitudeDeg.toStringAsFixed(6)}, ${p.longitudeDeg.toStringAsFixed(6)}';
    return _Grid([
      _Card(
        icon: Icons.gps_fixed_rounded,
        title: 'Posição',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _dms(p.latitudeDeg, 'N', 'S'),
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
            ),
            Text(
              _dms(p.longitudeDeg, 'L', 'O'),
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(coords, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: coords));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Coordenadas copiadas'), duration: Duration(seconds: 1)),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copiar coordenadas'),
            ),
          ],
        ),
      ),
      satellites,
      _Card(
        icon: Icons.explore_rounded,
        title: 'Movimento',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.speedMps * 3.6 < _gpsNoiseKmh) ...[
              const _Big('Parado', ''),
              const _Note(
                'Abaixo de ~3 km/h a velocidade do GPS é só ruído (parado, ele marca 1 a 4 km/h). '
                'O robô anda mais devagar que isso.',
              ),
            ] else ...[
              _Big((p.speedMps * 3.6).toStringAsFixed(1), 'km/h'),
              _Row('Rumo', '${p.courseDeg.toStringAsFixed(0)}° ${_compass(p.courseDeg)}'),
            ],
          ],
        ),
      ),
    ]);
  }
}

/// GPS speed below this is noise: standing still, a weak fix reads 1-4 km/h.
const _gpsNoiseKmh = 3.0;

/// 23°33'01.8" S
String _dms(double deg, String positive, String negative) {
  final d = deg.abs();
  final whole = d.floor();
  final minutes = (d - whole) * 60;
  final m = minutes.floor();
  final s = (minutes - m) * 60;
  return "$whole°${m.toString().padLeft(2, '0')}'${s.toStringAsFixed(1).padLeft(4, '0')}\" "
      '${deg >= 0 ? positive : negative}';
}

String _compass(double deg) {
  const names = ['N', 'NE', 'L', 'SE', 'S', 'SO', 'O', 'NO'];
  return names[((deg % 360) / 45).round() % 8];
}

String _hdopText(double hdop) => hdop <= 0
    ? '—'
    : hdop < 1
    ? 'ótima'
    : hdop < 2
    ? 'boa'
    : hdop < 5
    ? 'razoável'
    : 'fraca';

String _clockText(int utcMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(utcMs).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
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

class _PiTab extends StatelessWidget {
  const _PiTab(this.log, this.now);

  final PiLog log;
  final Duration now;

  @override
  Widget build(BuildContext context) {
    final p = log.last;
    final at = log.lastAt;
    if (p == null || at == null || now - at > const Duration(seconds: 6)) {
      return const _Grid([
        _Card(
          icon: Icons.developer_board_off_rounded,
          title: 'Raspberry Pi',
          wide: true,
          child: Text(
            'Aguardando os dados do Raspberry Pi… Eles chegam a cada 2 segundos (ponte a partir da versão com esta tela).',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ]);
    }
    const ok = Color(0xFF3DDC97);
    const warn = Color(0xFFFFB547);
    const bad = Color(0xFFFF5A5F);
    final (powerColor, powerText, powerNote) = p.underVoltage
        ? (
            bad,
            'Energia fraca agora',
            'O Pi está recebendo menos de ~4,63 V: ele reduz a velocidade e o Wi-Fi e a tela podem cair.',
          )
        : p.underVoltageSeen
        ? (
            warn,
            'Houve queda de energia',
            'Desde que a ponte ligou, a tensão caiu pelo menos uma vez. Confira a fonte e o cabo.',
          )
        : (ok, 'Energia boa', 'Nenhuma queda de tensão desde que a ponte ligou.');
    final throttled = p.cpuMaxFreqMhz > 0 && p.cpuFreqMhz < p.cpuMaxFreqMhz;
    String gb(int mb) => (mb / 1024).toStringAsFixed(1);
    return _Grid([
      _Card(
        icon: Icons.bolt_rounded,
        title: 'Energia',
        wide: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  p.underVoltage || p.underVoltageSeen ? Icons.warning_rounded : Icons.check_circle_rounded,
                  color: powerColor,
                ),
                const SizedBox(width: 8),
                Text(
                  powerText,
                  style: TextStyle(color: powerColor, fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ],
            ),
            _Note(powerNote),
            if (p.underVoltage || p.underVoltageSeen)
              const _Note(
                'Na bancada, use a fonte oficial do Raspberry (5,1 V / 2,5 A). Carregador de celular não serve.',
              ),
          ],
        ),
      ),
      _Card(
        icon: Icons.memory_rounded,
        title: 'Processador',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Big(p.cpuPercent.toStringAsFixed(0), '%'),
            const SizedBox(height: 8),
            _Chart(
              lines: [(log.series(now, (s) => s.cpuPercent), _accent, 'uso')],
              min: 0,
              max: 100,
              unit: ' %',
              height: 90,
              span: 120,
            ),
            const SizedBox(height: 4),
            _Row('Carga (1 min, 4 núcleos)', p.load1m.toStringAsFixed(2)),
            _Row('Velocidade', '${p.cpuFreqMhz} de ${p.cpuMaxFreqMhz} MHz'),
            if (throttled)
              const _Note('Abaixo do máximo: normal em repouso; com o Pi ocupado, é calor ou energia.'),
          ],
        ),
      ),
      _Card(
        icon: Icons.device_thermostat_rounded,
        title: 'Temperatura',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Big(p.temperatureC.toStringAsFixed(1), '°C'),
            const SizedBox(height: 8),
            _Chart(
              lines: [(log.series(now, (s) => s.temperatureC), warn, 'chip')],
              min: 20,
              max: 90,
              unit: ' °C',
              height: 90,
              span: 120,
            ),
            const _Note('Acima de 80 °C o Pi reduz a velocidade para esfriar.'),
          ],
        ),
      ),
      _Card(
        icon: Icons.storage_rounded,
        title: 'Memória',
        child: _Usage(p.memUsedMb, p.memTotalMb, '${p.memUsedMb} de ${p.memTotalMb} MB'),
      ),
      _Card(
        icon: Icons.sd_card_rounded,
        title: 'Cartão SD',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Usage(p.diskUsedMb, p.diskTotalMb, '${gb(p.diskUsedMb)} de ${gb(p.diskTotalMb)} GB'),
            const SizedBox(height: 4),
            _Row('Proteção do cartão', p.readOnly ? 'ligada' : 'desligada'),
          ],
        ),
      ),
      _Card(
        icon: Icons.wifi_rounded,
        title: 'Rede e tempo ligado',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row('Sinal do Wi-Fi', describeSignal(p.wifiRssiDbm)),
            _Row('Pi ligado há', formatUptime(p.uptimeS.toInt() * 1000)),
          ],
        ),
      ),
    ]);
  }
}

/// "used of total" with a bar that turns amber above 80 % and red above 95 %.
class _Usage extends StatelessWidget {
  const _Usage(this.used, this.total, this.text);

  final int used;
  final int total;
  final String text;

  @override
  Widget build(BuildContext context) {
    final f = total == 0 ? 0.0 : used / total;
    final color = f > 0.95 ? const Color(0xFFFF5A5F) : (f > 0.8 ? const Color(0xFFFFB547) : _accent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Big((f * 100).toStringAsFixed(0), '%'),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: f,
            minHeight: 8,
            color: color,
            backgroundColor: Colors.white12,
          ),
        ),
        const SizedBox(height: 6),
        Text(text, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
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
    final s = describeState(context.l10n, state);
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
    this.span = 30,
  });

  final List<(List<(double, double)>, Color, String)> lines;
  final double min;
  final double max;
  final String unit;
  final double height;

  /// Seconds of history across the width (oldest at the left edge).
  final double span;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: height,
          child: CustomPaint(painter: _ChartPainter(lines, min, max, span), size: Size.infinite),
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
              '${min.toStringAsFixed(0)} a ${max.toStringAsFixed(0)}$unit · ${span >= 60 ? '${span ~/ 60} min' : '${span.toInt()} s'}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.lines, this.min, this.max, this.span);

  final List<(List<(double, double)>, Color, String)> lines;
  final double min;
  final double max;
  final double span;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    canvas.clipRect(Offset.zero & size); // history older than [span] stays inside
    for (final (points, color, _) in lines) {
      if (points.length < 2) continue;
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final (sec, v) = points[i];
        final x = size.width * (1 + sec / span);
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
