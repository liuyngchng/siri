package com.rd.siri.ui

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rd.siri.SiriApp
import com.rd.siri.audio.AudioPlayer
import com.rd.siri.audio.AudioRecorder
import com.rd.siri.asr.SherpaAsrEngine
import com.rd.siri.chat.ChatSession
import com.rd.siri.chat.LlmClient
import com.rd.siri.config.ConfigRepository
import com.rd.siri.model.AppState
import com.rd.siri.model.ChatMessage
import com.rd.siri.model.VoiceState
import com.rd.siri.tts.SherpaTtsEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

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
    private var processingJob: Job? = null

    init {
        Log.i(TAG, "MainViewModel init start")

        // Load TTS preference
        _state.update { it.copy(ttsEnabled = configRepository.isTtsEnabled()) }

        viewModelScope.launch(Dispatchers.IO) {
            _state.update { it.copy(voiceState = VoiceState.Loading("模型加载中…")) }

            // Check native libraries first — if they failed to load, bail out early
            if (!SiriApp.instance.nativeLibrariesLoaded) {
                _state.update {
                    it.copy(voiceState = VoiceState.Error("原生引擎加载失败，请重新安装应用"))
                }
                return@launch
            }

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

    fun toggleTts(enable: Boolean) {
        configRepository.setTtsEnabled(enable)
        _state.update { it.copy(ttsEnabled = enable) }
        if (!enable) {
            stopSpeaking()
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

    /** Cancel every in-flight task so a new recording starts from a clean slate. */
    private fun cancelAllTasks() {
        Log.i(TAG, "cancelAllTasks: aborting all in-progress work")

        // Coroutine jobs
        recordingJob?.cancel()
        recordingJob = null
        streamingJob?.cancel()
        streamingJob = null
        speakingJob?.cancel()
        speakingJob = null
        processingJob?.cancel()
        processingJob = null

        // Audio I/O
        audioRecorder.stopRecording()
        audioPlayer.stop()

        // ASR engine buffer — discard stale samples from cancelled sessions
        asrEngine.reset()

        // ChatSession rollback: if a user message was added but no reply yet,
        // remove the orphaned message so it does not pollute the next conversation.
        val msgs = chatSession.messages.value
        if (msgs.isNotEmpty() && msgs.last().role == ChatMessage.Role.USER) {
            chatSession.clearLastUserMessage()
        }
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

        // Cancel everything in flight — ASR, LLM, TTS, etc.
        cancelAllTasks()

        Log.i(TAG, "startListening: begin recording")
        _state.update { it.copy(voiceState = VoiceState.Listening, partialAsrText = "", finalAsrText = "") }

        recordingJob = viewModelScope.launch {
            audioRecorder.startRecording()
                .catch { e ->
                    Log.e(TAG, "startListening: recording error", e)
                    _state.update { it.copy(voiceState = VoiceState.Error("录音错误: ${e.message}")) }
                }
                .collect { samples ->
                    asrEngine.acceptWaveform(samples)
                    val partial = asrEngine.getPendingText()
                    if (partial.isNotBlank()) {
                        Log.d(TAG, "startListening: partial ASR text='$partial'")
                    }
                    _state.update { it.copy(partialAsrText = partial) }
                }
        }
    }

    fun stopListening() {
        Log.i(TAG, "stopListening: stopping recording")
        audioRecorder.stopRecording()
        recordingJob?.cancel()

        _state.update { it.copy(voiceState = VoiceState.Recognizing) }

        processingJob = viewModelScope.launch(Dispatchers.IO) {
            try {
                recordingJob?.join()
                recordingJob = null

                Log.i(TAG, "stopListening: calling inputFinished")
                val text = asrEngine.inputFinished()
                Log.i(TAG, "stopListening: ASR final text='$text'")
                if (text.isBlank()) {
                    Log.w(TAG, "stopListening: ASR returned blank text, returning to idle")
                    _state.update { it.copy(voiceState = VoiceState.Idle, partialAsrText = "") }
                    return@launch
                }

                _state.update { it.copy(finalAsrText = text, partialAsrText = "", voiceState = VoiceState.Thinking) }

                if (!configRepository.hasConfig) {
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
                        _state.update { it.copy(voiceState = VoiceState.Idle) }
                    }
                }.onFailure { e ->
                    Log.e(TAG, "stopListening: LLM request failed", e)
                    _state.update { it.copy(voiceState = VoiceState.Error("请求失败: ${e.message}")) }
                }
            } finally {
                processingJob = null
            }
        }
    }

    fun speakText(text: String) {
        if (!_state.value.ttsEnabled) {
            _state.update { it.copy(voiceState = VoiceState.Idle) }
            return
        }
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
        val ttsEnabled = _state.value.ttsEnabled

        if (ttsEnabled) {
            _state.update { it.copy(voiceState = VoiceState.Speaking) }
        }

        if (ttsEnabled) {
            val sampleRate = ttsEngine.getSampleRate()
            val sentenceChannel = Channel<String>(Channel.UNLIMITED)
            val pcmChannel = Channel<FloatArray>(Channel.BUFFERED)
            var lastBoundary = 0

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
        } else {
            // TTS disabled: just collect the stream, save to chat, no audio
            try {
                textFlow.collect { token ->
                    accumulator.append(token)
                    _state.update { it.copy(assistantReply = accumulator.toString()) }
                }
            } finally {
                val reply = accumulator.toString()
                if (reply.isNotBlank()) {
                    chatSession.appendAssistantReply(reply)
                }
                _state.update { it.copy(assistantReply = reply) }
            }
        }
    }

    fun stopSpeaking() {
        speakingJob?.cancel()
        streamingJob?.cancel()
        audioPlayer.stop()
        _state.update { it.copy(voiceState = VoiceState.Idle) }
    }

    fun finishSpeaking() {
        Log.i(TAG, "finishSpeaking called")
        stopSpeaking()
    }

    fun cancelListening() {
        Log.i(TAG, "cancelListening called")
        audioRecorder.stopRecording()
        audioPlayer.stop()
        recordingJob?.cancel()
        recordingJob = null
        processingJob?.cancel()
        processingJob = null
        speakingJob?.cancel()
        speakingJob = null
        streamingJob?.cancel()
        streamingJob = null
        asrEngine.reset()
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
        processingJob?.cancel()
    }

}
