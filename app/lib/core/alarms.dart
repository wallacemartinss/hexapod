import 'proto.dart' as pb;

/// The MQ-2 sees gas or smoke (only trusted while the sensor is fitted:
/// FAULT_GAS_SENSOR clear).
bool gasAlarmOn(pb.Telemetry? t) => t != null && t.gasAlarm && t.faultFlags & 2048 == 0;
