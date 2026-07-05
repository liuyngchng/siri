package com.rd.siri.audio

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Log
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

class WakeWordEngine(private val context: Context) {

    companion object {
        private const val TAG = "SiriApp"
        const val SAMPLE_RATE = 16000
        private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
        private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT
        private const val BUFFER_SIZE_FACTOR = 4
    }

    @Volatile
    private var spotterPtr: Long = 0
    @Volatile
    private var keywordsContent: String = ""

    private val isRunning = AtomicBoolean(false)
    private var detectionThread: Thread? = null
    @Volatile
    private var audioRecord: AudioRecord? = null

    val isReady: Boolean get() = spotterPtr != 0L

    fun initialize(modelDir: File, numThreads: Int = 1): Boolean {
        if (spotterPtr != 0L) {
            Log.w(TAG, "WakeWordEngine: already initialized")
            return true
        }

        // Load keywords from assets
        keywordsContent = try {
            context.assets.open("kws_keywords.txt").bufferedReader().use { it.readText().trim() }
        } catch (e: Exception) {
            Log.e(TAG, "WakeWordEngine: failed to read keywords from assets", e)
            return false
        }
        Log.i(TAG, "WakeWordEngine: keywords='${keywordsContent}'")

        Log.i(TAG, "WakeWordEngine: initializing with modelDir=${modelDir.absolutePath}, threads=$numThreads")
        spotterPtr = nativeCreateSpotter(modelDir.absolutePath, keywordsContent, numThreads)
        if (spotterPtr == 0L) {
            Log.e(TAG, "WakeWordEngine: failed to create spotter")
            return false
        }
        Log.i(TAG, "WakeWordEngine: initialized successfully")
        return true
    }

    /**
     * Start continuous wake word detection on a background thread.
     * [onDetected] is called from the detection thread when a wake word is detected.
     */
    fun start(onDetected: (keyword: String) -> Unit) {
        if (spotterPtr == 0L) {
            Log.e(TAG, "WakeWordEngine: not initialized")
            return
        }
        if (isRunning.getAndSet(true)) {
            Log.w(TAG, "WakeWordEngine: already running")
            return
        }

        detectionThread = Thread {
            runDetectionLoop(onDetected)
        }.apply {
            name = "WakeWordDetection"
            priority = Thread.NORM_PRIORITY
            start()
        }
    }

    fun stop() {
        isRunning.set(false)
        audioRecord?.stop()
        detectionThread?.join(1000)
        detectionThread = null
    }

    fun destroy() {
        stop()
        if (spotterPtr != 0L) {
            nativeDestroySpotter(spotterPtr)
            spotterPtr = 0
            Log.i(TAG, "WakeWordEngine: destroyed")
        }
    }

    // ── Detection loop ───────────────────────────────────────────────────────

    private fun runDetectionLoop(onDetected: (String) -> Unit) {
        val streamPtr = nativeCreateStream(spotterPtr)
        if (streamPtr == 0L) {
            Log.e(TAG, "WakeWordEngine: failed to create keyword stream")
            isRunning.set(false)
            return
        }

        val bufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
            .let { it * BUFFER_SIZE_FACTOR }

        val recorder = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            CHANNEL_CONFIG,
            AUDIO_FORMAT,
            bufferSize
        )

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            nativeDestroyStream(streamPtr)
            isRunning.set(false)
            Log.e(TAG, "WakeWordEngine: AudioRecord init failed")
            return
        }

        audioRecord = recorder

        try {
            recorder.startRecording()
            Log.i(TAG, "WakeWordEngine: detection loop started")

            val shortBuf = ShortArray(bufferSize / 2)
            val floatBuf = FloatArray(bufferSize / 2)

            while (isRunning.get()) {
                val n = recorder.read(shortBuf, 0, shortBuf.size)
                if (n <= 0) break

                for (i in 0 until n) {
                    floatBuf[i] = shortBuf[i].toFloat() / Short.MAX_VALUE.toFloat()
                }

                val samples = if (n == floatBuf.size) floatBuf else floatBuf.copyOf(n)
                nativeAcceptWaveform(streamPtr, samples, SAMPLE_RATE)

                while (nativeIsStreamReady(spotterPtr, streamPtr)) {
                    nativeDecodeStream(spotterPtr, streamPtr)
                    val keyword = nativeGetResult(spotterPtr, streamPtr)
                    if (keyword.isNotEmpty()) {
                        Log.i(TAG, "WakeWordEngine: detected '$keyword'")
                        nativeResetStream(spotterPtr, streamPtr)
                        try {
                            onDetected(keyword)
                        } catch (e: Exception) {
                            Log.e(TAG, "WakeWordEngine: callback error", e)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "WakeWordEngine: detection error", e)
        } finally {
            try { recorder.stop() } catch (_: IllegalStateException) {}
            recorder.release()
            audioRecord = null
            nativeDestroyStream(streamPtr)
            isRunning.set(false)
            Log.i(TAG, "WakeWordEngine: detection loop stopped")
        }
    }

    // ── Native methods ──────────────────────────────────────────────────────

    private external fun nativeCreateSpotter(modelDir: String, keywords: String, numThreads: Int): Long

    private external fun nativeDestroySpotter(ptr: Long)

    private external fun nativeCreateStream(ptr: Long): Long

    private external fun nativeDestroyStream(streamPtr: Long)

    private external fun nativeAcceptWaveform(
        streamPtr: Long, samples: FloatArray, sampleRate: Int
    )

    private external fun nativeIsStreamReady(ptr: Long, streamPtr: Long): Boolean

    private external fun nativeDecodeStream(ptr: Long, streamPtr: Long)

    private external fun nativeGetResult(ptr: Long, streamPtr: Long): String

    private external fun nativeResetStream(ptr: Long, streamPtr: Long)
}
