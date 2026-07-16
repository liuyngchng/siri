package com.rd.siri

import android.app.Application
import android.util.Log
import com.rd.siri.config.ConfigRepository

class SiriApp : Application() {

    lateinit var configRepository: ConfigRepository
        private set

    /** True if all native libraries (.so) loaded successfully. */
    var nativeLibrariesLoaded: Boolean = false
        private set

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate start")
        instance = this

        loadNativeLibraries()

        try {
            configRepository = ConfigRepository(this)
            Log.i(TAG, "ConfigRepository initialized OK")
        } catch (e: Exception) {
            Log.e(TAG, "ConfigRepository init failed", e)
        }
        Log.i(TAG, "onCreate done")
    }

    private fun loadNativeLibraries() {
        var allLoaded = true
        try {
            System.loadLibrary("onnxruntime")
            Log.i(TAG, "libonnxruntime loaded")
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "Failed to load onnxruntime: ${e.message}")
            allLoaded = false
        }
        try {
            System.loadLibrary("sherpa-onnx-c-api")
            Log.i(TAG, "libsherpa-onnx-c-api loaded")
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "Failed to load sherpa-onnx-c-api: ${e.message}")
            allLoaded = false
        }
        try {
            System.loadLibrary("sherpa_onnx_jni")
            Log.i(TAG, "libsherpa_onnx_jni loaded")
        } catch (e: UnsatisfiedLinkError) {
            Log.e(TAG, "Failed to load sherpa_onnx_jni: ${e.message}")
            allLoaded = false
        }
        nativeLibrariesLoaded = allLoaded
        if (!allLoaded) {
            Log.e(TAG, "One or more native libraries failed to load — ASR/TTS/KWS will be unavailable")
        }
    }

    companion object {
        private const val TAG = "SiriApp"

        lateinit var instance: SiriApp
            private set
    }
}
