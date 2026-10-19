import 'dart:async';

import 'package:flutter/services.dart';
import 'package:gamepads_platform_interface/gamepads_platform_interface.dart';

import 'controller_feedback.dart';

/// Accelerometer (m/s²) or gyroscope (rad/s) sample from the controller.
class MotionSample {
  const MotionSample({required this.gyro, required this.x, required this.y, required this.z});

  final bool gyro;
  final double x, y, z;
}

/// The controller's light bar, motors and motion sensors. Every call fails
/// soft: a phone or pad without the feature simply does nothing.
abstract class ControllerPlatform {
  Future<bool> setLight(int argb);

  /// Opens the phone's Bluetooth settings, to pair a controller.
  Future<bool> openBluetoothSettings();
  Future<bool> hasRumble(String gamepadId);
  Future<void> rumble(String gamepadId, Rumble r);
  Stream<MotionSample> motion();
}

/// Android implementation: lights and sensors through ControllerChannel.kt,
/// rumble through the gamepads plugin (the controller's own motors).
class AndroidControllerPlatform implements ControllerPlatform {
  static const _methods = MethodChannel('hexapod/controller');
  static const _motion = EventChannel('hexapod/controller/motion');

  @override
  Future<bool> setLight(int argb) async {
    try {
      return await _methods.invokeMethod<bool>('setLight', {'color': argb}) ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openBluetoothSettings() async {
    try {
      return await _methods.invokeMethod<bool>('openBluetoothSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> hasRumble(String gamepadId) async {
    try {
      return await GamepadsPlatformInterface.instance.hasRumble(gamepadId);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> rumble(String gamepadId, Rumble r) async {
    for (var i = 0; i < r.times; i++) {
      try {
        await GamepadsPlatformInterface.instance.rumble(
          gamepadId,
          lowFrequency: r.low,
          highFrequency: r.high,
          duration: r.duration,
        );
      } catch (_) {
        return;
      }
      await Future<void>.delayed(r.duration + r.gap);
    }
  }

  @override
  Stream<MotionSample> motion() => _motion
      .receiveBroadcastStream()
      .map((e) {
        final v = (e as List).cast<num>();
        return MotionSample(gyro: v[0] == 1, x: v[1].toDouble(), y: v[2].toDouble(), z: v[3].toDouble());
      })
      .handleError((_) {});
}
