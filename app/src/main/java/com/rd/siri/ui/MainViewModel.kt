package com.rd.siri.ui

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.rd.siri.audio.AudioPlayer
import com.rd.siri.audio.AudioRecorder
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private const val TAG = "SiriApp"
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

    init {
        Log.i(TAG, "MainViewModel init start")
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

    /**
     * Start listening: begin audio recording and streaming to ASR.
     */
    fun startListening() {
        if (!asrEngine.isReady) {
            _state.update { it.copy(voiceState = VoiceState.Error("模型未就绪，请先上传模型文件")) }
            return
        }
        if (!AudioRecorder.isPermissionGranted(getApplication())) {
            _state.update { it.copy(voiceState = VoiceState.Error("请授予麦克风权限")) }
            return
        }

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

    /**
     * Stop listening, finalize ASR, and send to LLM.
     */
    fun stopListening() {
        Log.i(TAG, "stopListening: stopping recording")
        audioRecorder.stopRecording()
        recordingJob?.cancel()

        _state.update { it.copy(voiceState = VoiceState.Recognizing) }

        viewModelScope.launch(Dispatchers.IO) {
            // Wait for recording coroutine to finish (read() unblocked by stopRecording above)
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

            // Check config before sending
            if (!configRepository.hasConfig) {
                _state.update {
                    it.copy(voiceState = VoiceState.Error("请先在设置中配置 API 信息"))
                }
                return@launch
            }

            // Stream LLM response
            Log.i(TAG, "stopListening: sending to LLM, text='$text'")
            val result = chatSession.sendStream(text)
            result.onSuccess { flow ->
                val fullReply = StringBuilder()
                streamingJob = viewModelScope.launch {
                    flow.collect { token ->
                        fullReply.append(token)
                        _state.update { it.copy(assistantReply = fullReply.toString()) }
                    }
                    val reply = fullReply.toString()
                    Log.i(TAG, "stopListening: LLM reply complete, len=${reply.length}")
                    chatSession.appendAssistantReply(reply)
                    _state.update { it.copy(assistantReply = reply) }
                    speakText(reply)
                }
            }.onFailure { e ->
                Log.e(TAG, "stopListening: LLM request failed", e)
                _state.update { it.copy(voiceState = VoiceState.Error("请求失败: ${e.message}")) }
            }
        }
    }

    /**
     * Speak text via TTS. Cancel any previous speech first.
     * Synthesizes and plays sentence by sentence so the first audio starts sooner.
     */
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
                    // Producer: synthesize sentences
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

                    // Consumer: play synthesized audio
                    launch(Dispatchers.IO) {
                        for (pcm in channel) {
                            audioPlayer.play(pcm, sampleRate)
                        }
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                // swallowed — normal stop
            } catch (e: Exception) {
                Log.e(TAG, "speakReply: TTS failed", e)
            } finally {
                _state.update { it.copy(voiceState = VoiceState.Idle) }
            }
        }
    }

    fun stopSpeaking() {
        speakingJob?.cancel()
        audioPlayer.stop()
        _state.update { it.copy(voiceState = VoiceState.Idle) }
    }

    fun cancelListening() {
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
        audioPlayer.stop()
        asrEngine.destroy()
        ttsEngine.destroy()
        recordingJob?.cancel()
        streamingJob?.cancel()
        speakingJob?.cancel()
    }
}
