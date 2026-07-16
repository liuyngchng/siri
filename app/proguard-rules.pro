# ── sherpa-onnx JNI native methods ──────────────────────────────────────────

# ASR engine
-keep class com.rd.siri.asr.SherpaAsrEngine {
    native <methods>;
}

# TTS engine
-keep class com.rd.siri.tts.SherpaTtsEngine {
    native <methods>;
}

# KWS / wake word engine
-keep class com.rd.siri.audio.WakeWordEngine {
    native <methods>;
}

# ── OkHttp ───────────────────────────────────────────────────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keepnames class okhttp3.internal.publicsuffix.PublicSuffixDatabase

# ── Commons Compress ─────────────────────────────────────────────────────────
-dontwarn org.apache.commons.compress.**
-keep class org.apache.commons.compress.** { *; }

# ── JSON (org.json / Android built-in) ───────────────────────────────────────
-keep class org.json.** { *; }

# ── Kotlin coroutines ────────────────────────────────────────────────────────
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# ── Compose ──────────────────────────────────────────────────────────────────
-dontwarn androidx.compose.**

# ── Keep data classes used with EncryptedSharedPreferences ──────────────────
-keep class com.rd.siri.config.LlmConfig { *; }
-keep class com.rd.siri.model.** { *; }