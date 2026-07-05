package com.rd.siri.ui

import android.Manifest
import android.app.Application
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rd.siri.audio.AudioPlayer
import com.rd.siri.audio.AudioRecorder
import com.rd.siri.audio.VoiceService
import com.rd.siri.audio.WakeWordManager
import com.rd.siri.asr.SherpaAsrEngine
import com.rd.siri.chat.ChatSession
import com.rd.siri.chat.LlmClient
import com.rd.siri.config.ConfigRepository
import com.rd.siri.model.AppState
import com.rd.siri.model.VoiceState
import com.rd.siri.tts.SherpaTtsEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.sqrt

class MainViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private const val TAG = "SiriApp"
        private val SENTENCE_TERMINATORS = charArrayOf('。', '！', '？', '!', '?', '\n')
    }

    private val audioRecorder = AudioRecorder(application)
    private val audioPlayer = AudioPlayer()
    private val asrEngine = SherpaAsrEngine(application)
    private val ttsEngine = SherpaTtsEngine(application)
    private val configRepository = ConfigRepository(application)
    private val llmClient = LlmClient(configRepository)
    val chatSession = ChatSession(llmClient)

    private val _state = MutableStateFlow(AppState())
    val state: StateFlow<AppState> = _state.asStateFlow()

    private var recordingJob: Job? = null
    private var streamingJob: Job? = null
    private var speakingJob: Job? = null
    private var autoStopJob: Job? = null
    private var vadJob: Job? = null
    private var wakeWordTriggered = false
    private var multiTurnActive = false

    // Latest audio RMS energy, updated by the recording coroutine.
    // Used by the multi-turn VAD for speech/silence detection.
    private val latestRms = AtomicReference(0f)
    private var sampleCounter = 0L

    init {
        Log.i(TAG, "MainViewModel init start")

        // Observe wake word state from service (source of truth for UI)
        viewModelScope.launch {
            WakeWordManager.isRunning.collect { running ->
                _state.update { it.copy(wakeWordEnabled = running) }
            }
        }

        // When voice flow completes after a wake-word trigger, resume KWS.
        viewModelScope.launch {
            _state.collect { s ->
                if (wakeWordTriggered && s.voiceState is VoiceState.Idle && !multiTurnActive) {
                    Log.i(TAG, "Wake-word voice flow complete, signaling resume")
                    wakeWordTriggered = false
                    WakeWordManager.notifyVoiceFlowDone()
                }
            }
        }

        // Listen for wake word events
        viewModelScope.launch {
            WakeWordManager.wakeEvents.collect {
                Log.i(TAG, "Wake word event received!")
                if (_state.value.voiceState is VoiceState.Idle && _state.value.enginesReady) {
                    wakeWordTriggered = true
                    multiTurnActive = true
                    launch(Dispatchers.IO) {
                        _state.update { it.copy(voiceState = VoiceState.Speaking) }
                        val pcm = ttsEngine.synthesize("哎，我在呢", sid = 0)
                        if (pcm != null) {
                            audioPlayer.play(pcm, ttsEngine.getSampleRate())
                        }
                        startListening()
                    }
                }
            }
        }

        viewModelScope.launch(Dispatchers.IO) {
            _state.update { it.copy(voiceState = VoiceState.Loading("模型加载中…")) }

            val asrDeferred = async { asrEngine.initialize() }
            val ttsDeferred = async { ttsEngine.initialize() }

            val asrReady = asrDeferred.await()
            val ttsReady = ttsDeferred.await()
            Log.i(TAG, "ASR engine init done, ready=$asrReady")
            Log.i(TAG, "TTS engine init done, ready=$ttsReady")

            _state.update {
                if (asrReady && ttsReady) {
                    it.copy(voiceState = VoiceState.Idle, enginesReady = true)
                } else {
                    it.copy(voiceState = VoiceState.Error("模型加载失败，请检查模型文件"))
                }
            }
        }
    }

    fun isWakeWordEnabled(): Boolean = _state.value.wakeWordEnabled

    fun toggleWakeWord(enable: Boolean) {
        if (enable && ContextCompat.checkSelfPermission(
                getApplication(), Manifest.permission.RECORD_AUDIO
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            _state.update { it.copy(voiceState = VoiceState.Error("请先授予麦克风权限")) }
            return
        }

        val intent = Intent(getApplication(), VoiceService::class.java).apply {
            action = if (enable) VoiceService.ACTION_START else VoiceService.ACTION_STOP
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (enable) {
                getApplication<Application>().startForegroundService(intent)
            } else {
                getApplication<Application>().stopService(intent)
            }
        }
    }

    fun checkConfig(): Boolean {
        val hasConfig = configRepository.hasConfig
        _state.update {
            val newVoiceState = if (hasConfig && it.voiceState is VoiceState.Error
                && it.voiceState.message.contains("配置 API")
            ) {
                VoiceState.Idle
            } else {
                it.voiceState
            }
            it.copy(hasConfig = hasConfig, voiceState = newVoiceState)
        }
        return hasConfig
    }

    fun startListening() {
        if (!asrEngine.isReady) {
            _state.update { it.copy(voiceState = VoiceState.Error("模型未就绪，请先上传模型文件")) }
            return
        }
        if (!AudioRecorder.isPermissionGranted(getApplication())) {
            _state.update { it.copy(voiceState = VoiceState.Error("请授予麦克风权限")) }
            return
        }

        stopSpeaking()

        Log.i(TAG, "startListening: begin recording")
        _state.update { it.copy(voiceState = VoiceState.Listening, partialAsrText = "", finalAsrText = "") }

        // Reset energy tracker for VAD
        latestRms.set(0f)
        sampleCounter = 0L

        recordingJob = viewModelScope.launch {
            audioRecorder.startRecording()
                .catch { e ->
                    Log.e(TAG, "startListening: recording error", e)
                    _state.update { it.copy(voiceState = VoiceState.Error("录音错误: ${e.message}")) }
                }
                .collect { samples ->
                    asrEngine.acceptWaveform(samples)
                    val partial = asrEngine.getPendingText()
                    val energy = rms(samples)
                    if (partial.isNotBlank()) {
                        Log.d(TAG, "startListening: partial ASR text='$partial'")
                    }
                    // Log energy periodically to diagnose audio capture issues
                    if (sampleCounter++ % 20 == 0L) {
                        Log.d(TAG, "startListening: audio energy rms=$energy, partial='${partial.take(20)}'")
                    }
                    // Track audio energy for VAD
                    latestRms.set(energy)
                    _state.update { it.copy(partialAsrText = partial) }
                }
        }

        // VAD-based auto-stop when multi-turn mode is active
        if (multiTurnActive) {
            vadJob?.cancel()
            vadJob = viewModelScope.launch {
                val maxPeakWaitMs = 10000L
                val silenceThresholdMs = 1500L
                val energyThreshold = 0.005f

                var speechDetected = false
                var silenceStartMs: Long? = null
                var energyHighCount = 0
                val energyHighNeeded = 3  // require 600ms of sustained energy
                val startMs = System.currentTimeMillis()

                var vadLogCounter = 0
                while (true) {
                    delay(200)
                    val s = _state.value
                    if (s.voiceState !is VoiceState.Listening) break

                    val rms = latestRms.get()
                    val hasPartial = s.partialAsrText.isNotBlank()

                    // Periodic VAD status log
                    if (vadLogCounter++ % 10 == 0) {
                        Log.d(TAG, "VAD check: rms=$rms hasPartial=$hasPartial speechDetected=$speechDetected energyHighCount=$energyHighCount")
                    }

                    // Speech detection: ASR partial text is definitive.
                    // Energy alone requires sustained signal to filter out transient noise.
                    if (hasPartial) {
                        speechDetected = true
                        silenceStartMs = null
                        energyHighCount = 0
                    } else if (!speechDetected && rms > energyThreshold) {
                        energyHighCount++
                        if (energyHighCount >= energyHighNeeded) {
                            speechDetected = true
                        }
                    } else if (!speechDetected) {
                        energyHighCount = 0
                    }

                    // Silence after speech detected
                    if (speechDetected && rms <= energyThreshold && !hasPartial) {
                        if (silenceStartMs == null) {
                            silenceStartMs = System.currentTimeMillis()
                        } else if (System.currentTimeMillis() - silenceStartMs >= silenceThresholdMs) {
                            Log.i(TAG, "VAD: silence for ${silenceThresholdMs}ms after speech, auto-stopping")
                            stopListening()
                            break
                        }
                    } else if (speechDetected) {
                        silenceStartMs = null
                    }

                    // No speech detected at all → timeout
                    if (!speechDetected && System.currentTimeMillis() - startMs >= maxPeakWaitMs) {
                        Log.i(TAG, "VAD: no speech detected for ${maxPeakWaitMs}ms, auto-stopping")
                        stopListening()
                        break
                    }
                }
            }
        }
    }

    fun stopListening() {
        Log.i(TAG, "stopListening: stopping recording")
        autoStopJob?.cancel()
        vadJob?.cancel()
        audioRecorder.stopRecording()
        recordingJob?.cancel()

        _state.update { it.copy(voiceState = VoiceState.Recognizing) }

        viewModelScope.launch(Dispatchers.IO) {
            recordingJob?.join()
            recordingJob = null

            Log.i(TAG, "stopListening: calling inputFinished")
            val text = asrEngine.inputFinished()
            Log.i(TAG, "stopListening: ASR final text='$text'")
            if (text.isBlank()) {
                Log.w(TAG, "stopListening: ASR returned blank text, returning to idle")
                if (wakeWordTriggered) {
                    WakeWordManager.notifyFalseTrigger()
                }
                multiTurnActive = false
                _state.update { it.copy(voiceState = VoiceState.Idle, partialAsrText = "") }
                return@launch
            }

            // Productive wake — reset adaptive debounce
            if (wakeWordTriggered) {
                WakeWordManager.notifyProductiveWake()
            }

            _state.update { it.copy(finalAsrText = text, partialAsrText = "", voiceState = VoiceState.Thinking) }

            if (!configRepository.hasConfig) {
                multiTurnActive = false
                _state.update {
                    it.copy(voiceState = VoiceState.Error("请先在设置中配置 API 信息"))
                }
                return@launch
            }

            Log.i(TAG, "stopListening: sending to LLM, text='$text'")
            val result = chatSession.sendStream(text)
            result.onSuccess { flow ->
                streamingJob = viewModelScope.launch {
                    val fullReply = StringBuilder()
                    try {
                        speakStream(flow, fullReply)
                    } catch (e: kotlinx.coroutines.CancellationException) {
                    } catch (e: Exception) {
                        Log.e(TAG, "stopListening: stream TTS failed", e)
                    }
                    Log.i(TAG, "stopListening: LLM reply complete, len=${fullReply.length}")
                    if (multiTurnActive) {
                        Log.i(TAG, "Multi-turn: auto-starting next listening round")
                        startListening()
                    } else {
                        _state.update { it.copy(voiceState = VoiceState.Idle) }
                    }
                }
            }.onFailure { e ->
                multiTurnActive = false
                Log.e(TAG, "stopListening: LLM request failed", e)
                _state.update { it.copy(voiceState = VoiceState.Error("请求失败: ${e.message}")) }
            }
        }
    }

    fun speakText(text: String) {
        speakingJob?.cancel()
        audioPlayer.stop()

        _state.update { it.copy(voiceState = VoiceState.Speaking) }

        speakingJob = viewModelScope.launch {
            try {
                val sentences = com.rd.siri.tts.TextNormalizer.splitSentences(text)
                Log.i(TAG, "speakReply: ${sentences.size} sentences, text='${text.take(80)}'")
                val sampleRate = ttsEngine.getSampleRate()
                val channel = Channel<FloatArray>(Channel.BUFFERED)

                coroutineScope {
                    launch(Dispatchers.IO) {
                        for (sentence in sentences) {
                            val normalized = com.rd.siri.tts.TextNormalizer.normalize(sentence)
                            if (normalized.isBlank()) continue
                            Log.i(TAG, "speakReply: synthesizing sentence='${normalized.take(40)}'")
                            val pcm = ttsEngine.synthesize(normalized, sid = 0)
                            if (pcm != null) {
                                channel.send(pcm)
                            }
                        }
                        channel.close()
                    }

                    launch(Dispatchers.IO) {
                        for (pcm in channel) {
                            audioPlayer.play(pcm, sampleRate)
                        }
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
            } catch (e: Exception) {
                Log.e(TAG, "speakReply: TTS failed", e)
            } finally {
                _state.update { it.copy(voiceState = VoiceState.Idle) }
            }
        }
    }

    private suspend fun speakStream(
        textFlow: Flow<String>,
        accumulator: StringBuilder
    ) {
        val sampleRate = ttsEngine.getSampleRate()
        val sentenceChannel = Channel<String>(Channel.UNLIMITED)
        val pcmChannel = Channel<FloatArray>(Channel.BUFFERED)
        var lastBoundary = 0

        _state.update { it.copy(voiceState = VoiceState.Speaking) }

        coroutineScope {
            val synthJob = launch(Dispatchers.IO) {
                try {
                    for (sentence in sentenceChannel) {
                        val normalized = com.rd.siri.tts.TextNormalizer.normalize(sentence)
                        if (normalized.isBlank()) continue
                        Log.i(TAG, "speakStream: synthesizing '${normalized.take(40)}'")
                        val pcm = ttsEngine.synthesize(normalized, sid = 0)
                        if (pcm != null) {
                            pcmChannel.send(pcm)
                        }
                    }
                } finally {
                    pcmChannel.close()
                }
            }

            val playerJob = launch(Dispatchers.IO) {
                for (pcm in pcmChannel) {
                    audioPlayer.play(pcm, sampleRate)
                }
            }

            try {
                textFlow.collect { token ->
                    accumulator.append(token)
                    _state.update { it.copy(assistantReply = accumulator.toString()) }

                    val text = accumulator.toString()
                    while (lastBoundary < text.length) {
                        var boundaryIdx = -1
                        for (i in lastBoundary until text.length) {
                            if (text[i] in SENTENCE_TERMINATORS) {
                                boundaryIdx = i
                                break
                            }
                        }
                        if (boundaryIdx == -1) break

                        val sentence = text.substring(lastBoundary, boundaryIdx).trim()
                        if (sentence.isNotBlank()) {
                            sentenceChannel.send(sentence)
                        }
                        lastBoundary = boundaryIdx + 1
                    }
                }
            } finally {
                val remaining = accumulator.toString().substring(lastBoundary).trim()
                if (remaining.isNotBlank()) {
                    Log.i(TAG, "speakStream: flushing remaining '${remaining.take(40)}'")
                    sentenceChannel.send(remaining)
                }
                sentenceChannel.close()
            }

            val reply = accumulator.toString()
            if (reply.isNotBlank()) {
                chatSession.appendAssistantReply(reply)
            }
            _state.update { it.copy(assistantReply = reply) }

            synthJob.join()
            playerJob.join()
        }
    }

    fun stopSpeaking() {
        speakingJob?.cancel()
        streamingJob?.cancel()
        audioPlayer.stop()
        _state.update { it.copy(voiceState = VoiceState.Idle) }
    }

    fun finishSpeaking() {
        Log.i(TAG, "finishSpeaking called, multiTurnActive=$multiTurnActive")
        multiTurnActive = false
        stopSpeaking()
    }

    fun cancelListening() {
        Log.i(TAG, "cancelListening called, wakeWordTriggered=$wakeWordTriggered")
        if (wakeWordTriggered) {
            WakeWordManager.notifyFalseTrigger()
        }
        multiTurnActive = false
        autoStopJob?.cancel()
        vadJob?.cancel()
        audioRecorder.stopRecording()
        recordingJob?.cancel()
        recordingJob = null
        _state.update { it.copy(voiceState = VoiceState.Idle, partialAsrText = "") }
    }

    fun clearError() {
        _state.update { it.copy(voiceState = VoiceState.Idle) }
    }

    fun clearHistory() {
        chatSession.clear()
        _state.update { it.copy(assistantReply = "", partialAsrText = "", finalAsrText = "") }
    }

    override fun onCleared() {
        super.onCleared()
        audioRecorder.stopRecording()
        audioPlayer.release()
        asrEngine.destroy()
        ttsEngine.destroy()
        recordingJob?.cancel()
        streamingJob?.cancel()
        speakingJob?.cancel()
    }

    private fun rms(samples: FloatArray): Float {
        var sum = 0.0
        for (s in samples) {
            sum += s.toDouble() * s
        }
        return sqrt(sum / samples.size).toFloat()
    }
}
