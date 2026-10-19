package com.wallacemartinss.hexapod_app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * "hexapod/robot_wifi": puts the app on the robot's own Wi-Fi without the
 * user visiting the system settings (Android 10+, WifiNetworkSpecifier: the
 * system asks "connect to Hexapode-XXXX?").
 *  - join(ssid, password) -> Boolean: connected, app traffic bound to it
 *  - release(): back to the phone's normal network
 * The robot's network has no internet, so the whole app process is bound to
 * it while joined (otherwise Android would route around it).
 */
class RobotWifiChannel(context: Context, messenger: BinaryMessenger) {
    private val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val main = Handler(Looper.getMainLooper())
    private var callback: ConnectivityManager.NetworkCallback? = null

    init {
        MethodChannel(messenger, "hexapod/robot_wifi").setMethodCallHandler { call, result ->
            when (call.method) {
                "join" -> {
                    val ssid = call.argument<String>("ssid") ?: return@setMethodCallHandler result.success(false)
                    val password = call.argument<String>("password") ?: ""
                    if (Build.VERSION.SDK_INT < 29) result.success(false) else join(ssid, password, result)
                }
                "release" -> {
                    release()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun join(ssid: String, password: String, result: MethodChannel.Result) {
        release()
        val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).setWpa2Passphrase(password).build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(spec)
            .build()
        var answered = false
        // Callbacks arrive on a ConnectivityThread: answer Flutter on main.
        fun answer(ok: Boolean) = main.post {
            if (!answered) {
                answered = true
                result.success(ok)
            }
        }
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cm.bindProcessToNetwork(network)
                answer(true)
            }

            override fun onUnavailable() {
                answer(false) // refused, or not found in time
            }

            override fun onLost(network: Network) {
                cm.bindProcessToNetwork(null)
            }
        }
        callback = cb
        try {
            cm.requestNetwork(request, cb, 30_000)
        } catch (e: Exception) {
            callback = null
            answer(false)
        }
    }

    fun release() {
        cm.bindProcessToNetwork(null)
        callback?.let {
            try {
                cm.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        callback = null
    }
}
