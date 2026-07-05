package com.rd.siri.audio

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Singleton coordinating wake word detection state between [VoiceService] and the UI layer.
 *
 * Lifecycle of a wake-word-triggered voice session:
 *   1. VoiceService detects wake word → stops KWS → notifyWakeWord()
 *   2. MainViewModel receives event → starts ASR recording (mic now free)
 *   3. ASR → LLM → TTS → voice flow completes
 *   4. MainViewModel calls notifyVoiceFlowDone()
 *   5. VoiceService receives signal → resumes KWS detection
 */
object WakeWordManager {

    private val _wakeEvents = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val wakeEvents: SharedFlow<Unit> = _wakeEvents.asSharedFlow()

    private val _isRunning = MutableStateFlow(false)
    val isRunning: StateFlow<Boolean> = _isRunning.asStateFlow()

    /** Signal emitted when the voice flow completes and KWS should resume. */
    private val _resumeSignal = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val resumeSignal: SharedFlow<Unit> = _resumeSignal.asSharedFlow()

    /** Called by VoiceService when the wake word is detected. */
    fun notifyWakeWord() {
        _wakeEvents.tryEmit(Unit)
    }

    /** Called by MainViewModel when the voice flow (ASR→LLM→TTS) has completed. */
    fun notifyVoiceFlowDone() {
        _resumeSignal.tryEmit(Unit)
    }

    /** Called by VoiceService to update the running state. */
    fun setRunning(running: Boolean) {
        _isRunning.value = running
    }
}
