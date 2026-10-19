import 'package:flutter/material.dart';

import '../../core/proto.dart' as pb;
import '../../l10n/l10n.dart';

export '../../core/alarms.dart' show gasAlarmOn;

enum Severity { ok, info, warning, danger }

/// How a robot state is shown to the pilot: a short label, what happened and
/// what to do about it.
class StateText {
  const StateText(this.label, this.severity, [this.detail, this.action]);

  final String label;
  final Severity severity;
  final String? detail;
  final String? action;
}

/// Banner for the gas alarm: informative, the robot keeps doing what it does.
StateText gasAlarmText(AppLocalizations l) =>
    StateText(l.stateGas, Severity.danger, l.stateGasDetail, l.stateGasAction);

StateText describeState(AppLocalizations l, pb.State s) => switch (s) {
  pb.State.STATE_NORMAL => StateText(l.stateNormal, Severity.ok),
  pb.State.STATE_STOPPING => StateText(
    l.stateStopping,
    Severity.warning,
    l.stateStoppingDetail,
    l.stateStoppingAction,
  ),
  pb.State.STATE_SAFE_SIT => StateText(
    l.stateSafeSit,
    Severity.warning,
    l.stateSafeSitDetail,
    l.stateSafeSitAction,
  ),
  pb.State.STATE_RELAXED => StateText(
    l.stateRelaxed,
    Severity.info,
    l.stateRelaxedDetail,
    l.stateRelaxedAction,
  ),
  pb.State.STATE_BLOCKED => StateText(l.stateBlocked, Severity.warning, l.stateBlockedDetail),
  pb.State.STATE_LOW_BATTERY => StateText(
    l.stateLowBattery,
    Severity.danger,
    l.stateLowBatteryDetail,
    l.stateLowBatteryAction,
  ),
  pb.State.STATE_TIPPED => StateText(
    l.stateTipped,
    Severity.danger,
    l.stateTippedDetail,
    l.stateTippedAction,
  ),
  pb.State.STATE_ESTOP => StateText(l.stateEstop, Severity.danger, l.stateEstopDetail, l.stateEstopAction),
  _ => const StateText('—', Severity.info),
};

/// Fault bits worth telling the pilot (hexapod.v1.Fault).
List<String> describeFaults(AppLocalizations l, int flags) => [
  if (flags & 1 != 0) l.faultLeftServos,
  if (flags & 2 != 0) l.faultRightServos,
  if (flags & 4 != 0) l.faultImu,
  if (flags & 8 != 0) l.faultDistance,
  if (flags & 16 != 0) l.faultEnvironment,
  if (flags & 32 != 0) l.faultPower,
  if (flags & 64 != 0) l.faultOvercurrent,
  if (flags & 128 != 0) l.faultBatteryLow,
  if (flags & 256 != 0) l.faultBatteryCritical,
  if (flags & 512 != 0) l.faultLoopOverrun,
  if (flags & 1024 != 0) l.faultCalibration,
  if (flags & 2048 != 0) l.faultGas,
];

Color severityColor(Severity s) => switch (s) {
  Severity.ok => const Color(0xFF3DDC97),
  Severity.info => const Color(0xFF7FB2FF),
  Severity.warning => const Color(0xFFFFB547),
  Severity.danger => const Color(0xFFFF5A5F),
};

/// 3S LiPo: rough state of charge from the pack voltage (resting curve).
int batteryPercent(double volts) {
  final cell = volts / 3;
  const curve = <(double, int)>[
    (3.30, 0),
    (3.50, 5),
    (3.68, 20),
    (3.74, 35),
    (3.80, 50),
    (3.87, 65),
    (3.95, 80),
    (4.06, 90),
    (4.20, 100),
  ];
  if (cell <= curve.first.$1) return 0;
  for (var i = 1; i < curve.length; i++) {
    final (v1, p1) = curve[i];
    if (cell <= v1) {
      final (v0, p0) = curve[i - 1];
      return (p0 + (p1 - p0) * (cell - v0) / (v1 - v0)).round();
    }
  }
  return 100;
}
