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

    final l = context.l10n;
    final tabs = [
      (Icons.dashboard_rounded, l.dataTabSummary),
      (Icons.explore_rounded, l.dataTabOrientation),
      (Icons.radar_rounded, l.dataTabDistance),
      (Icons.place_rounded, l.dataTabPosition),
      (Icons.thermostat_rounded, l.dataTabEnvironment),
      (Icons.pest_control_rounded, l.dataTabLegs),
      (Icons.memory_rounded, l.dataTabSystem),
      (Icons.developer_board_rounded, l.dataTabPi),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          foregroundColor: Colors.white,
          title: Text(l.dataTitle),
          actions: [
            if (t != null) _StateChip(t.state),
            const SizedBox(width: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFE5383B),
                foregroundColor: Colors.white,
              ),
              onPressed: ref.read(controlProvider.notifier).stop,
              child: Text(l.dataStop, style: const TextStyle(fontWeight: FontWeight.w800)),
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
                    link == LinkStatus.connected ? l.dataWaiting : l.dataNoConnection,
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
    final l = context.l10n;
    final state = describeState(l, t.state);
    final faults = [
      if (t.gasAlarm && Part.gas.presentIn(t)) l.dataGasDetected,
      for (final (bit, text) in faultTexts(l))
        if (t.faultFlags & bit != 0) text,
    ];
    return _Grid([
      _Card(
        icon: Icons.smart_toy_rounded,
        title: l.dataState,
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
            _Row(l.dataMode, _modeName(l, t.mode)),
            _Row(l.dataGait, _gaitName(l, t.gait)),
            _Row(l.dataUptime, formatUptime(t.uptimeMs)),
          ],
        ),
      ),
      if (Part.power.presentIn(t))
        _Card(
          icon: Icons.battery_full_rounded,
          title: l.dataBattery,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Big('${batteryPercent(t.batteryVoltageV)}', '%'),
              _Row(l.dataVoltage, '${t.batteryVoltageV.toStringAsFixed(2)} V'),
              _Row(l.dataPerCell, '${(t.batteryVoltageV / 3).toStringAsFixed(2)} V'),
              _Row(l.dataCurrent, '${t.batteryCurrentA.toStringAsFixed(2)} A'),
              _Note(l.dataCurrentNote),
            ],
          ),
        )
      else
        const _Absent(Part.power),
      _Card(
        icon: Icons.wifi_rounded,
        title: l.dataLink,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Big(log.rateHz(now).toStringAsFixed(0), 'Hz'),
            _Note(l.dataTelemetryExpected),
            _Row(l.dataReceived, '${log.received}'),
            _Row(l.dataLost, '${log.lost}'),
            _Row(l.dataLastCommand, '#${t.lastCommandSeq}'),
          ],
        ),
      ),
      _Card(
        icon: Icons.warning_amber_rounded,
        title: l.dataWarnings,
        child: faults.isEmpty
            ? Text(l.dataNone, style: const TextStyle(color: Colors.white70))
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
    final l = context.l10n;
    final q = t.orientation;
    return _Grid([
      _Card(
        icon: Icons.flight_rounded,
        title: l.dataHorizon,
        child: SizedBox(
          height: 170,
          child: CustomPaint(painter: _HorizonPainter(t.rollDeg, t.pitchDeg), size: Size.infinite),
        ),
      ),
      _Card(
        icon: Icons.threed_rotation_rounded,
        title: l.dataAngles,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row(l.dataRoll, '${t.rollDeg.toStringAsFixed(1)}°'),
            _Row(l.dataPitch, '${t.pitchDeg.toStringAsFixed(1)}°'),
            _Row(l.dataYaw, '${t.yawDeg.toStringAsFixed(1)}°'),
            const SizedBox(height: 6),
            _Row(
              l.dataQuaternion,
              '${q.w.toStringAsFixed(3)}, ${q.x.toStringAsFixed(3)}, '
              '${q.y.toStringAsFixed(3)}, ${q.z.toStringAsFixed(3)}',
            ),
            _Note(l.dataTippedNote),
          ],
        ),
      ),
      _Card(
        icon: Icons.show_chart_rounded,
        title: l.dataLast30s,
        child: _Chart(
          lines: [
            (log.series(now, (t) => t.rollDeg), _accent, l.dataRollLegend),
            (log.series(now, (t) => t.pitchDeg), const Color(0xFFC77DFF), l.dataPitchLegend),
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
    final l = context.l10n;
    final names = [l.dataFront, l.dataRight, l.dataBack, l.dataLeft];
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
    final l = context.l10n;
    if (p == null) {
      return _Grid([
        _Card(
          icon: Icons.location_off_rounded,
          title: l.dataGps,
          wide: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.dataGpsNoAnswer,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(l.dataGpsNoAnswerHint, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
      ]);
    }
    final satellites = _Card(
      icon: Icons.satellite_alt_rounded,
      title: l.dataSatellites,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Big('${p.satellitesUsed}', l.dataSatellitesInUse(p.satellitesInView)),
          if (p.fix) _Row(l.dataHdop, '${p.hdop.toStringAsFixed(1)} · ${_hdopText(l, p.hdop)}'),
          if (p.fix) _Row(l.dataAltitude, '${p.altitudeM.toStringAsFixed(0)} m'),
          if (p.utcMs > 0) _Row(l.dataGpsTime, _clockText(p.utcMs.toInt())),
        ],
      ),
    );
    if (!p.fix) {
      return _Grid([
        _Card(
          icon: Icons.gps_not_fixed_rounded,
          title: l.dataPosition,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.dataSearchingSatellites,
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(l.dataSearchingHint, style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
        title: l.dataPosition,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _dms(p.latitudeDeg, 'N', 'S'),
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
            ),
            Text(
              _dms(p.longitudeDeg, l.dataCompassEast, l.dataCompassWest),
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(coords, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: coords));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.dataCoordsCopied), duration: const Duration(seconds: 1)),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: Text(l.dataCopyCoords),
            ),
          ],
        ),
      ),
      satellites,
      _Card(
        icon: Icons.explore_rounded,
        title: l.dataMovement,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.speedMps * 3.6 < _gpsNoiseKmh) ...[
              _Big(l.dataStill, ''),
              _Note(l.dataSpeedNoiseNote),
            ] else ...[
              _Big((p.speedMps * 3.6).toStringAsFixed(1), 'km/h'),
              _Row(l.dataCourse, '${p.courseDeg.toStringAsFixed(0)}° ${_compass(l, p.courseDeg)}'),
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

/// One of the 8 compass points; East and West letters depend on the language.
String _compass(AppLocalizations l, double deg) {
  final e = l.dataCompassEast;
  final w = l.dataCompassWest;
  final names = ['N', 'N$e', e, 'S$e', 'S', 'S$w', w, 'N$w'];
  return names[((deg % 360) / 45).round() % 8];
}

String _hdopText(AppLocalizations l, double hdop) => hdop <= 0
    ? '—'
    : hdop < 1
    ? l.dataHdopGreat
    : hdop < 2
    ? l.dataHdopGood
    : hdop < 5
    ? l.dataHdopFair
    : l.dataHdopWeak;

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
    final l = context.l10n;
    final esp = _Card(
      icon: Icons.memory_rounded,
      title: l.dataEspChip,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [_Big(t.esp32TemperatureC.toStringAsFixed(1), '°C'), _Note(l.dataEspChipNote)],
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
        title: l.dataTemperature,
        child: _Big(t.temperatureC.toStringAsFixed(1), '°C'),
      ),
      _Card(
        icon: Icons.water_drop_rounded,
        title: l.dataHumidity,
        child: _Big(t.humidityPct.toStringAsFixed(0), '%'),
      ),
      _Card(
        icon: Icons.speed_rounded,
        title: l.dataPressure,
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
    final l10n = context.l10n;
    final legs = [
      l10n.dataLegLeftFront,
      l10n.dataLegLeftMiddle,
      l10n.dataLegLeftRear,
      l10n.dataLegRightFront,
      l10n.dataLegRightMiddle,
      l10n.dataLegRightRear,
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
        title: l10n.dataCommandedAngles,
        wide: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Table(
              columnWidths: const {0: FlexColumnWidth(2)},
              children: [
                row([l10n.dataLeg, l10n.dataCoxa, l10n.dataFemur, l10n.dataTibia], header: true),
                for (var l = 0; l < legs.length; l++)
                  row(['$l · ${legs[l]}', angle(l, 0), angle(l, 1), angle(l, 2)]),
              ],
            ),
            _Note(l10n.dataLegsNote),
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
    final l = context.l10n;
    return _Grid([
      _Card(
        icon: Icons.info_outline_rounded,
        title: l.dataSoftware,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Row(l.dataFirmware, h == null || h.firmwareVersion.isEmpty ? '—' : h.firmwareVersion),
            _Row(l.dataBridge, h == null || h.hexdVersion.isEmpty ? '—' : h.hexdVersion),
            _Row(l.dataProtocol, h == null ? '—' : '${h.protocolVersion}'),
            _Row(l.dataEspUptime, formatUptime(t.uptimeMs)),
          ],
        ),
      ),
      _Card(
        icon: Icons.timer_rounded,
        title: l.dataLoop,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Big((t.loopTimeUs / 1000).toStringAsFixed(2), 'ms'),
            _Note(l.dataLoopLimit),
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
        title: l.dataChecks,
        child: Column(
          children: [
            for (final (bit, text) in faultChecks(l))
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
    final l = context.l10n;
    if (p == null || at == null || now - at > const Duration(seconds: 6)) {
      return _Grid([
        _Card(
          icon: Icons.developer_board_off_rounded,
          title: l.dataTabPi,
          wide: true,
          child: Text(l.dataPiWaiting, style: const TextStyle(color: Colors.white70)),
        ),
      ]);
    }
    const ok = Color(0xFF3DDC97);
    const warn = Color(0xFFFFB547);
    const bad = Color(0xFFFF5A5F);
    final (powerColor, powerText, powerNote) = p.underVoltage
        ? (bad, l.dataPowerLowNow, l.dataPowerLowNowNote)
        : p.underVoltageSeen
        ? (warn, l.dataPowerDipped, l.dataPowerDippedNote)
        : (ok, l.dataPowerGood, l.dataPowerGoodNote);
    final throttled = p.cpuMaxFreqMhz > 0 && p.cpuFreqMhz < p.cpuMaxFreqMhz;
    String gb(int mb) => (mb / 1024).toStringAsFixed(1);
    return _Grid([
      _Card(
        icon: Icons.bolt_rounded,
        title: l.dataPower,
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
            if (p.underVoltage || p.underVoltageSeen) _Note(l.dataPowerSupplyNote),
          ],
        ),
      ),
      _Card(
        icon: Icons.memory_rounded,
        title: l.dataCpu,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Big(p.cpuPercent.toStringAsFixed(0), '%'),
            const SizedBox(height: 8),
            _Chart(
              lines: [(log.series(now, (s) => s.cpuPercent), _accent, l.dataCpuLegend)],
              min: 0,
              max: 100,
              unit: ' %',
              height: 90,
              span: 120,
            ),
            const SizedBox(height: 4),
            _Row(l.dataLoad, p.load1m.toStringAsFixed(2)),
            _Row(l.dataSpeed, l.dataAmountOf('${p.cpuFreqMhz}', '${p.cpuMaxFreqMhz}', 'MHz')),
            if (throttled) _Note(l.dataThrottledNote),
          ],
        ),
      ),
      _Card(
        icon: Icons.device_thermostat_rounded,
        title: l.dataTemperature,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Big(p.temperatureC.toStringAsFixed(1), '°C'),
            const SizedBox(height: 8),
            _Chart(
              lines: [(log.series(now, (s) => s.temperatureC), warn, l.dataChipLegend)],
              min: 20,
              max: 90,
              unit: ' °C',
              height: 90,
              span: 120,
            ),
            _Note(l.dataPiHotNote),
          ],
        ),
      ),
      _Card(
        icon: Icons.storage_rounded,
        title: l.dataMemory,
        child: _Usage(p.memUsedMb, p.memTotalMb, l.dataAmountOf('${p.memUsedMb}', '${p.memTotalMb}', 'MB')),
      ),
      _Card(
        icon: Icons.sd_card_rounded,
        title: l.dataSdCard,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Usage(p.diskUsedMb, p.diskTotalMb, l.dataAmountOf(gb(p.diskUsedMb), gb(p.diskTotalMb), 'GB')),
            const SizedBox(height: 4),
            _Row(l.dataCardProtection, p.readOnly ? l.dataOn : l.dataOff),
          ],
        ),
      ),
      _Card(
        icon: Icons.wifi_rounded,
        title: l.dataNetwork,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (p.model.isNotEmpty) _Row(l.dataPiModel, p.model.replaceFirst('Raspberry Pi ', 'Pi ')),
            _Row(l.dataWifiSignal, describeSignal(l, p.wifiRssiDbm)),
            _Row(l.dataPiUptime, formatUptime(p.uptimeS.toInt() * 1000)),
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
    final l = context.l10n;
    return _Card(
      icon: Icons.sensors_off_rounded,
      title: part.label(l),
      wide: wide,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.dataNotInstalled(part.chip),
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(l.dataNotInstalledHint, style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
    final l = context.l10n;
    return _Card(
      icon: Icons.local_fire_department_rounded,
      title: l.partGas,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Big(t.gasLevelPct.toStringAsFixed(0), l.dataGasUnit),
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
            Text(
              l.dataGasDetected,
              style: const TextStyle(color: danger, fontSize: 13, fontWeight: FontWeight.w800),
            )
          else if (t.gasWarming)
            Text(l.dataGasWarming, style: const TextStyle(color: Colors.white54, fontSize: 12))
          else
            Text(l.dataGasNormal, style: const TextStyle(color: Color(0xFF3DDC97), fontSize: 12)),
          _Note(l.dataGasNote),
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
    final l = context.l10n;
    return _Card(
      icon: Icons.straighten_rounded,
      title: name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Big(mm >= 8000 || mm == 0 ? '—' : '$mm', mm >= 8000 || mm == 0 ? l.dataOutOfRange : 'mm'),
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
            Text(
              l.dataBlocked,
              style: const TextStyle(color: Color(0xFFFF5A5F), fontSize: 12, fontWeight: FontWeight.w700),
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
              context.l10n.dataChartRange(
                min.toStringAsFixed(0),
                max.toStringAsFixed(0),
                unit,
                span >= 60 ? '${span ~/ 60} min' : '${span.toInt()} s',
              ),
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

String _modeName(AppLocalizations l, pb.Mode m) => switch (m) {
  pb.Mode.MODE_SIT => l.dataModeSit,
  pb.Mode.MODE_STAND => l.dataModeStand,
  pb.Mode.MODE_WALK => l.dataModeWalk,
  pb.Mode.MODE_CALIBRATE => l.dataModeCalibrate,
  pb.Mode.MODE_FRONT_LEGS => l.dataModeFrontLegs,
  _ => '—',
};

String _gaitName(AppLocalizations l, pb.Gait g) => switch (g) {
  pb.Gait.GAIT_TRIPOD => l.dataGaitTripod,
  pb.Gait.GAIT_WAVE => l.dataGaitWave,
  pb.Gait.GAIT_RIPPLE => l.dataGaitRipple,
  _ => '—',
};
