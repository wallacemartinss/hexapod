package com.wallacemartinss.hexapod_app

import android.content.Context
import android.content.Intent
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.lights.Light
import android.hardware.lights.LightState
import android.hardware.lights.LightsManager
import android.hardware.lights.LightsRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.InputDevice
import androidx.annotation.RequiresApi
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Gamepad features the gamepads plugin does not cover (Android 12+, API 31):
 *  - "hexapod/controller" setLight(color): RGB light bar (DualSense, DualShock 4)
 *  - "hexapod/controller" openBluetoothSettings(): to pair a controller
 *  - "hexapod/controller/motion": accelerometer + gyroscope samples
 *    [kind (0 accel, 1 gyro), x, y, z] from the controller's own sensors.
 * Anything the phone's kernel does not expose is reported as unsupported.
 */
class ControllerChannel(private val context: Context, messenger: BinaryMessenger) {
    private var lightSession: LightsManager.LightsSession? = null
    private var sensorManager: SensorManager? = null
    private var listener: SensorEventListener? = null

    // A controller's sensors report on Android's own "SensorThread"; Flutter
    // only accepts channel messages on the main thread (else it aborts).
    private val main = Handler(Looper.getMainLooper())

    init {
        MethodChannel(messenger, "hexapod/controller").setMethodCallHandler { call, result ->
            when (call.method) {
                "setLight" -> {
                    val color = (call.argument<Number>("color") ?: 0).toInt()
                    result.success(if (Build.VERSION.SDK_INT >= 31) setLight(color) else false)
                }
                "openBluetoothSettings" -> result.success(openBluetoothSettings())
                "capabilities" -> result.success(
                    if (Build.VERSION.SDK_INT >= 31) capabilities() else mapOf("light" to false, "motion" to false)
                )
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "hexapod/controller/motion").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                if (Build.VERSION.SDK_INT >= 31) startMotion(events) else events.endOfStream()
            }

            override fun onCancel(arguments: Any?) = stopMotion()
        })
    }

    private fun openBluetoothSettings(): Boolean = try {
        context.startActivity(
            Intent(Settings.ACTION_BLUETOOTH_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
        true
    } catch (e: Exception) {
        false
    }

    private fun gamepads(): List<InputDevice> = InputDevice.getDeviceIds().toList()
        .mapNotNull { InputDevice.getDevice(it) }
        .filter { it.sources and InputDevice.SOURCE_GAMEPAD == InputDevice.SOURCE_GAMEPAD }

    @RequiresApi(31)
    private fun rgbLights(device: InputDevice): List<Light> =
        device.lightsManager.lights.filter { it.hasRgbControl() }

    @RequiresApi(31)
    private fun capabilities(): Map<String, Boolean> {
        val pads = gamepads()
        return mapOf(
            "light" to pads.any { rgbLights(it).isNotEmpty() },
            "motion" to pads.any { it.sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) != null },
        )
    }

    @RequiresApi(31)
    private fun setLight(color: Int): Boolean {
        val device = gamepads().firstOrNull { rgbLights(it).isNotEmpty() } ?: return false
        val request = LightsRequest.Builder().apply {
            rgbLights(device).forEach { addLight(it, LightState.Builder().setColor(color).build()) }
        }.build()
        return try {
            val session = lightSession ?: device.lightsManager.openSession().also { lightSession = it }
            session.requestLights(request)
            true
        } catch (e: Exception) {
            lightSession = null
            false
        }
    }

    @RequiresApi(31)
    private fun startMotion(events: EventChannel.EventSink) {
        stopMotion()
        val device = gamepads().firstOrNull {
            it.sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER) != null
        }
        if (device == null) {
            events.endOfStream()
            return
        }
        val manager = device.sensorManager
        val l = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                val kind = if (e.sensor.type == Sensor.TYPE_GYROSCOPE) 1.0 else 0.0
                val sample = listOf(kind, e.values[0].toDouble(), e.values[1].toDouble(), e.values[2].toDouble())
                main.post { if (listener === this) events.success(sample) } // dropped once stopped
            }

            override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
        }
        manager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)?.let {
            manager.registerListener(l, it, SensorManager.SENSOR_DELAY_GAME)
        }
        manager.getDefaultSensor(Sensor.TYPE_GYROSCOPE)?.let {
            manager.registerListener(l, it, SensorManager.SENSOR_DELAY_GAME)
        }
        sensorManager = manager
        listener = l
    }

    private fun stopMotion() {
        listener?.let { sensorManager?.unregisterListener(it) }
        listener = null
        sensorManager = null
    }

    fun dispose() {
        stopMotion()
        try {
            lightSession?.close()
        } catch (_: Exception) {
        }
        lightSession = null
    }
}
