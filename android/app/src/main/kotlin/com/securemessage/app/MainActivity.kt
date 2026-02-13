package com.securemessage.app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity — Flutter entry point with Tor MethodChannel bridge
 *
 * Provides MethodChannel for Flutter to control embedded Tor:
 * - startTor(): Start the TorService
 * - stopTor(): Stop the TorService
 * - getTorStatus(): Get current Tor state
 * - getSocksPort(): Get SOCKS proxy port (-1 if not connected)
 * - isSocksReachable(): Check if SOCKS proxy is reachable
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.securemessage/tor"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTor" -> {
                    startTorService()
                    result.success(true)
                }

                "stopTor" -> {
                    stopTorService()
                    result.success(true)
                }

                "getTorStatus" -> {
                    val status = mapOf(
                        "state" to TorService.state.name,
                        "bootstrapProgress" to TorService.bootstrapProgress,
                        "errorMessage" to TorService.errorMessage,
                        "isRunning" to TorService.isRunning
                    )
                    result.success(status)
                }

                "getSocksPort" -> {
                    result.success(TorService.socksPort)
                }

                "isSocksReachable" -> {
                    // Run in background thread to avoid blocking
                    Thread {
                        val reachable = TorService.isSocksReachable()
                        runOnUiThread {
                            result.success(reachable)
                        }
                    }.start()
                }

                "getBootstrapProgress" -> {
                    result.success(TorService.bootstrapProgress)
                }

                else -> {
                    result.notImplemented()
                }
            }
        }

        // Auto-start Tor service when app launches
        startTorService()
    }

    /**
     * Start TorService as foreground service
     */
    private fun startTorService() {
        val intent = Intent(this, TorService::class.java)
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    /**
     * Stop TorService
     */
    private fun stopTorService() {
        val intent = Intent(this, TorService::class.java)
        stopService(intent)
    }

    override fun onDestroy() {
        // Stop Tor when app is destroyed
        stopTorService()
        super.onDestroy()
    }
}
