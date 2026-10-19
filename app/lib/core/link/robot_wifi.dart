import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Puts the phone on the robot's own Wi-Fi from inside the app (Android 10+:
/// the system asks "connect to Hexapode-XXXX?"). Tests replace it.
abstract class RobotWifi {
  /// True once joined; the app's traffic then goes to the robot's network.
  Future<bool> join(String ssid, String password);

  /// Back to the phone's usual network.
  Future<void> release();
}

class AndroidRobotWifi implements RobotWifi {
  static const _channel = MethodChannel('hexapod/robot_wifi');

  @override
  Future<bool> join(String ssid, String password) async {
    try {
      return await _channel.invokeMethod<bool>('join', {'ssid': ssid, 'password': password}) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> release() async {
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
  }
}

/// null where joining a network from the app is not possible (the PC).
final robotWifiProvider = Provider<RobotWifi?>((ref) => Platform.isAndroid ? AndroidRobotWifi() : null);
