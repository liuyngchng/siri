package com.rd.siri.audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import com.rd.siri.MainActivity
import com.rd.siri.R
import com.rd.siri.model.ModelManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.io.File

@RequiresApi(Build.VERSION_CODES.S)
class VoiceService : Service() {

    companion object {
        const val TAG = "SiriApp"
        const val CHANNEL_ID = "voice_service_channel"
        const val NOTIFICATION_ID = 1001
        const val ACTION_START = "com.rd.siri.action.START_WAKE"
        const val ACTION_STOP = "com.rd.siri.action.STOP_WAKE"

        private const val DEBOUNCE_MS = 5000L
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val engine = WakeWordEngine(this)
    private var lastWakeTime = 0L
    private var kwsActive = false  // true when engine is actively detecting

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()

        // Observe resume signal: when the voice flow completes, restart KWS
        serviceScope.launch {
            WakeWordManager.resumeSignal.collect {
                Log.i(TAG, "VoiceService: resume signal received")
                startEngine()
            }
        }

        Log.i(TAG, "VoiceService: created")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startWakeDetection()
            ACTION_STOP -> {
                stopWakeDetection()
                stopSelf()
            }
            else -> Log.w(TAG, "VoiceService: unknown action=${intent?.action}")
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        serviceScope.cancel()
        stopEngine()
        engine.destroy()
        stopForeground(STOP_FOREGROUND_REMOVE)
        WakeWordManager.setRunning(false)
        super.onDestroy()
        Log.i(TAG, "VoiceService: destroyed")
    }

    // ── Top-level start/stop (external control) ─────────────────────────────

    private fun startWakeDetection() {
        // MUST call startForeground() within ~5s — show notification immediately
        showForegroundNotification()
        WakeWordManager.setRunning(true)

        if (engine.isReady) {
            startEngine()
        } else {
            // Model init is slow (~7s), do it on a background thread
            Thread({
                if (!ensureInitializedSync()) {
                    stopSelf()
                    return@Thread
                }
                startEngine()
            }, "KwsInit").start()
        }
        Log.i(TAG, "VoiceService: wake detection started")
    }

    private fun stopWakeDetection() {
        stopEngine()
        stopForeground(STOP_FOREGROUND_REMOVE)
        WakeWordManager.setRunning(false)
        Log.i(TAG, "VoiceService: wake detection stopped")
    }

    // ── Engine control (pause/resume — keep notification alive while paused) ──

    private fun startEngine() {
        if (kwsActive) {
            Log.d(TAG, "VoiceService: engine already active")
            return
        }
        kwsActive = true
        engine.start { keyword ->
            val now = System.currentTimeMillis()
            if (now - lastWakeTime < DEBOUNCE_MS) {
                Log.d(TAG, "VoiceService: wake word debounced (${now - lastWakeTime}ms)")
                return@start
            }
            lastWakeTime = now
            Log.i(TAG, "VoiceService: wake word '$keyword' detected — pausing KWS")

            // Release the microphone before emitting the event so ASR can use it
            stopEngine()
            WakeWordManager.notifyWakeWord()
        }
        Log.i(TAG, "VoiceService: engine started")
    }

    private fun stopEngine() {
        engine.stop()
        kwsActive = false
        Log.i(TAG, "VoiceService: engine stopped")
    }

    // ── Initialization (runs on background thread, returns success) ────────

    private fun ensureInitializedSync(): Boolean {
        if (engine.isReady) return true

        val modelDir = File(filesDir, "models/${ModelManager.KWS_MODEL_DIR}")
        if (!ModelManager.checkKwsReady(this)) {
            Log.e(TAG, "VoiceService: KWS model not ready in ${modelDir.absolutePath}")
            return false
        }

        if (!engine.initialize(modelDir, numThreads = 1)) {
            Log.e(TAG, "VoiceService: engine init failed")
            return false
        }
        return true
    }

    // ── Notification ─────────────────────────────────────────────────────────

    private fun showForegroundNotification() {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.wake_word_listening_title))
            .setContentText(getString(R.string.wake_word_listening_text))
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            .build()

        startForeground(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        )
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.voice_channel),
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "语音服务通道"
            setShowBadge(false)
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }
}
