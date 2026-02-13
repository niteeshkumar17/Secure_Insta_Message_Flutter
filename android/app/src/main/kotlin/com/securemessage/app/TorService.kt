package com.securemessage.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.BufferedReader
import java.io.File
import java.io.FileOutputStream
import java.io.InputStreamReader
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * TorService — Foreground Android Service for embedded Tor daemon
 *
 * Lifecycle:
 * - Starts on app launch
 * - Runs as foreground service with persistent notification
 * - Manages Tor process lifecycle (start, monitor, stop)
 * - Stops on app exit
 *
 * Security:
 * - Tor binary runs in app's private directory
 * - No clearnet fallback (kill-switch enforced in app layer)
 * - Cookie authentication for control port
 * - Binds only to localhost
 */
class TorService : Service() {

    companion object {
        private const val TAG = "TorService"
        private const val NOTIFICATION_CHANNEL_ID = "tor_service_channel"
        private const val NOTIFICATION_ID = 1
        
        // Tor ports (localhost only)
        const val SOCKS_PORT = 9050
        const val CONTROL_PORT = 9051
        
        // State enum
        enum class TorState {
            STOPPED,
            STARTING,
            CONNECTING,
            CONNECTED,
            ERROR
        }

        // Singleton state for status queries
        private val _state = AtomicReference(TorState.STOPPED)
        private val _bootstrapProgress = AtomicInteger(0)
        private val _errorMessage = AtomicReference<String?>(null)
        private val _isRunning = AtomicBoolean(false)
        
        val state: TorState get() = _state.get()
        val bootstrapProgress: Int get() = _bootstrapProgress.get()
        val errorMessage: String? get() = _errorMessage.get()
        val isRunning: Boolean get() = _isRunning.get()
        val socksPort: Int get() = if (_state.get() == TorState.CONNECTED) SOCKS_PORT else -1
        
        // Check if SOCKS proxy is reachable
        fun isSocksReachable(): Boolean {
            return try {
                Socket("127.0.0.1", SOCKS_PORT).use { 
                    it.isConnected 
                }
            } catch (e: Exception) {
                false
            }
        }
    }

    private var torProcess: Process? = null
    private var monitorThread: Thread? = null
    private var torDataDir: File? = null
    private val shutdownLatch = CountDownLatch(1)

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "TorService created")
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "TorService starting")
        
        // Start as foreground service immediately
        startForeground(NOTIFICATION_ID, createNotification("Starting Tor..."))
        
        // Start Tor in background thread
        Thread {
            try {
                startTor()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start Tor", e)
                _state.set(TorState.ERROR)
                _errorMessage.set(e.message)
                updateNotification("Tor error: ${e.message}")
            }
        }.start()
        
        // If service is killed, restart it
        return START_STICKY
    }

    override fun onDestroy() {
        Log.i(TAG, "TorService destroying")
        stopTor()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * Start the embedded Tor daemon
     */
    private fun startTor() {
        if (_isRunning.get()) {
            Log.w(TAG, "Tor already running")
            return
        }

        _state.set(TorState.STARTING)
        _bootstrapProgress.set(0)
        _errorMessage.set(null)
        updateNotification("Starting Tor...")

        // Setup Tor data directory
        torDataDir = File(filesDir, "tor_data")
        torDataDir!!.mkdirs()

        // Extract Tor binary and config
        val torBinary = extractAsset("tor/tor", "tor", executable = true)
        val geoipFile = extractAsset("tor/geoip", "geoip")
        val geoip6File = extractAsset("tor/geoip6", "geoip6")
        
        // ========================================
        // VERIFY BINARY IS EXECUTABLE
        // ========================================
        Log.i(TAG, "Tor binary path: ${torBinary.absolutePath}")
        Log.i(TAG, "Tor binary exists: ${torBinary.exists()}")
        Log.i(TAG, "Tor binary size: ${torBinary.length()} bytes")
        Log.i(TAG, "Tor binary executable: ${torBinary.canExecute()}")
        
        if (!torBinary.exists()) {
            throw IllegalStateException("Tor binary not found at ${torBinary.absolutePath}")
        }
        
        if (!torBinary.canExecute()) {
            // Try to set executable again
            val setExec = torBinary.setExecutable(true, false)
            Log.i(TAG, "Set executable result: $setExec")
            if (!torBinary.canExecute()) {
                throw IllegalStateException("Cannot set executable permission on Tor binary")
            }
        }
        
        // Create torrc configuration
        val torrcFile = createTorrc(torDataDir!!, geoipFile, geoip6File)

        Log.i(TAG, "Starting Tor process with torrc: ${torrcFile.absolutePath}")

        // Build process with torrc
        val processBuilder = ProcessBuilder(
            torBinary.absolutePath,
            "-f", torrcFile.absolutePath
        )
        processBuilder.directory(torDataDir)
        processBuilder.redirectErrorStream(true)
        
        // Set environment
        val env = processBuilder.environment()
        env["HOME"] = torDataDir!!.absolutePath
        env["LD_LIBRARY_PATH"] = filesDir.absolutePath
        
        // Start process
        try {
            torProcess = processBuilder.start()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start Tor process", e)
            _state.set(TorState.ERROR)
            _errorMessage.set("Failed to start Tor: ${e.message}")
            throw IllegalStateException("Failed to start Tor process: ${e.message}", e)
        }
        
        // Wait briefly and check if process is still alive
        Thread.sleep(500)
        val proc = torProcess
        if (proc != null && !proc.isAlive) {
            val exitCode = proc.exitValue()
            val errorOutput = proc.inputStream.bufferedReader().readText()
            Log.e(TAG, "Tor process died immediately with exit code: $exitCode")
            Log.e(TAG, "Tor output: $errorOutput")
            _state.set(TorState.ERROR)
            _errorMessage.set("Tor crashed on startup (exit=$exitCode): $errorOutput")
            throw IllegalStateException("Tor process died immediately with exit code $exitCode: $errorOutput")
        }
        
        _isRunning.set(true)
        _state.set(TorState.CONNECTING)
        updateNotification("Connecting to Tor network...")

        // Start monitoring thread
        monitorThread = Thread {
            monitorTorProcess()
        }
        monitorThread!!.start()

        Log.i(TAG, "Tor process started, monitoring bootstrap")
    }

    /**
     * Stop the Tor daemon
     */
    private fun stopTor() {
        Log.i(TAG, "Stopping Tor")
        _isRunning.set(false)
        _state.set(TorState.STOPPED)
        _bootstrapProgress.set(0)

        // Signal shutdown
        shutdownLatch.countDown()

        // Kill process
        val proc = torProcess
        if (proc != null) {
            try {
                proc.destroy()
                if (!proc.waitFor(5, TimeUnit.SECONDS)) {
                    proc.destroyForcibly()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping Tor process", e)
            }
        }
        torProcess = null

        // Wait for monitor thread
        val thread = monitorThread
        if (thread != null) {
            try {
                thread.join(2000)
            } catch (e: Exception) {
                Log.e(TAG, "Error joining monitor thread", e)
            }
        }
        monitorThread = null

        Log.i(TAG, "Tor stopped")
    }

    /**
     * Monitor Tor process output for bootstrap status
     */
    private fun monitorTorProcess() {
        val process = torProcess ?: return
        
        try {
            BufferedReader(InputStreamReader(process.inputStream)).use { reader ->
                var line: String? = null
                while (_isRunning.get()) {
                    line = reader.readLine()
                    if (line == null) break
                    val logLine = line
                    Log.d(TAG, "Tor: $logLine")

                    // Parse bootstrap progress
                    // Format: "Bootstrapped 50% (loading_descriptors): Loading relay descriptors"
                    if (logLine.contains("Bootstrapped")) {
                        val match = Regex("Bootstrapped (\\d+)%").find(logLine)
                        match?.let {
                            val progress = it.groupValues[1].toIntOrNull() ?: 0
                            _bootstrapProgress.set(progress)
                            
                            if (progress >= 100) {
                                _state.set(TorState.CONNECTED)
                                updateNotification("Tor connected")
                                Log.i(TAG, "Tor fully bootstrapped")
                            } else {
                                updateNotification("Tor: $progress% bootstrapped")
                            }
                        }
                    }

                    // Check for errors
                    if (logLine.contains("[err]") || logLine.contains("[warn]")) {
                        if (logLine.contains("Could not bind") || 
                            logLine.contains("Address already in use")) {
                            _state.set(TorState.ERROR)
                            _errorMessage.set("Port conflict - another Tor instance running?")
                            updateNotification("Tor error: port conflict")
                        }
                    }
                }
            }
        } catch (e: Exception) {
            if (_isRunning.get()) {
                Log.e(TAG, "Error monitoring Tor", e)
                _state.set(TorState.ERROR)
                _errorMessage.set("Monitoring error: ${e.message}")
            }
        } finally {
            // Process ended
            if (_isRunning.get()) {
                Log.w(TAG, "Tor process ended unexpectedly")
                _state.set(TorState.ERROR)
                _errorMessage.set("Tor process terminated")
                updateNotification("Tor disconnected")
            }
        }
    }

    /**
     * Extract asset to app's files directory
     */
    private fun extractAsset(assetPath: String, filename: String, executable: Boolean = false): File {
        val outputFile = File(filesDir, filename)
        
        // Check if already extracted (skip re-extraction for efficiency)
        if (outputFile.exists() && outputFile.length() > 0) {
            if (executable) {
                outputFile.setExecutable(true)
            }
            return outputFile
        }

        Log.i(TAG, "Extracting $assetPath to ${outputFile.absolutePath}")

        assets.open(assetPath).use { input ->
            FileOutputStream(outputFile).use { output ->
                input.copyTo(output)
            }
        }

        if (executable) {
            outputFile.setExecutable(true)
        }

        return outputFile
    }

    /**
     * Create torrc configuration file
     */
    private fun createTorrc(dataDir: File, geoipFile: File, geoip6File: File): File {
        val torrcFile = File(dataDir, "torrc")
        
        val config = """
            # Secure Insta Message — Tor Configuration
            # Auto-generated, do not edit manually
            
            # Data directory
            DataDirectory ${dataDir.absolutePath}
            
            # SOCKS proxy (localhost only)
            SOCKSPort 127.0.0.1:$SOCKS_PORT
            
            # Control port for bootstrap monitoring
            ControlPort 127.0.0.1:$CONTROL_PORT
            CookieAuthentication 1
            
            # GeoIP files
            GeoIPFile ${geoipFile.absolutePath}
            GeoIPv6File ${geoip6File.absolutePath}
            
            # Safety settings
            SafeSocks 1
            TestSocks 1
            
            # No DNS leaks
            DNSPort 0
            
            # Logging
            Log notice stdout
            
            # Connection settings
            AvoidDiskWrites 1
            ClientOnly 1
            
            # Mobile-friendly settings
            ConnectionPadding 0
            ReducedConnectionPadding 1
        """.trimIndent()
        
        torrcFile.writeText(config)
        return torrcFile
    }

    /**
     * Create notification channel (required for Android 8+)
     */
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Tor Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Shows Tor connection status"
                setShowBadge(false)
            }
            
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    /**
     * Create foreground notification
     */
    private fun createNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Secure Insta Message")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    /**
     * Update the foreground notification
     */
    private fun updateNotification(text: String) {
        val notification = createNotification(text)
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, notification)
    }
}
