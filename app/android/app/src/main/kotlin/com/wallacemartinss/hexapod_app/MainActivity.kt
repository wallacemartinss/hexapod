package com.wallacemartinss.hexapod_app

import android.hardware.input.InputManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.view.KeyEvent
import android.view.MotionEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import org.flame_engine.gamepads_android.GamepadsCompatibleActivity

// Hands gamepad input (PS5 DualSense over Bluetooth) to the gamepads plugin.
class MainActivity : FlutterActivity(), GamepadsCompatibleActivity {
    private var keyListener: ((KeyEvent) -> Boolean)? = null
    private var motionListener: ((MotionEvent) -> Boolean)? = null

    // Many phones drop multicast packets unless an app holds this lock: without
    // it the mDNS lookup of hexapod.local never gets an answer.
    private var multicastLock: WifiManager.MulticastLock? = null
    private var controller: ControllerChannel? = null
    private var robotWifi: RobotWifiChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        controller = ControllerChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        robotWifi = RobotWifiChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("hexapod-mdns").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onDestroy() {
        controller?.dispose()
        robotWifi?.release()
        multicastLock?.release()
        super.onDestroy()
    }

    // Android turns the DualSense touchpad into a mouse: a pointer on screen
    // and accidental clicks on the pilot's buttons. While the app has focus it
    // captures the pointer, which hides it and keeps its events to itself
    // (the touchscreen and the gamepad sticks are not affected).
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && Build.VERSION.SDK_INT >= 26) {
            val view = window.decorView.findFocus() ?: window.decorView
            view.setOnCapturedPointerListener { _, _ -> true } // swallow
            view.requestPointerCapture()
        }
    }

    override fun dispatchGenericMotionEvent(motionEvent: MotionEvent): Boolean {
        if (motionListener?.invoke(motionEvent) == true) return true
        return super.dispatchGenericMotionEvent(motionEvent)
    }

    override fun dispatchKeyEvent(keyEvent: KeyEvent): Boolean {
        if (keyListener?.invoke(keyEvent) == true) return true
        return super.dispatchKeyEvent(keyEvent)
    }

    override fun registerInputDeviceListener(listener: InputManager.InputDeviceListener, handler: Handler?) {
        val inputManager = getSystemService(INPUT_SERVICE) as InputManager
        inputManager.registerInputDeviceListener(listener, null)
    }

    override fun registerKeyEventHandler(handler: (KeyEvent) -> Boolean) {
        keyListener = handler
    }

    override fun registerMotionEventHandler(handler: (MotionEvent) -> Boolean) {
        motionListener = handler
    }
}
