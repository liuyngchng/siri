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

    var speakerId = 0

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

    init {
        Log.i(TAG, "MainViewModel init start")
        viewModelScope.launch(Dispatchers.IO) {
            Log.i(TAG, "ASR engine init start")
            val asrReady = asrEngine.initialize()
            Log.i(TAG, "ASR engine init done, ready=$asrReady")
            Log.i(TAG, "TTS engine init start")
            val ttsReady = ttsEngine.initialize()
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
        _state.update { it.copy(hasConfig = hasConfig) }
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
                    speakReply(reply)
                }
            }.onFailure { e ->
                Log.e(TAG, "stopListening: LLM request failed", e)
                _state.update { it.copy(voiceState = VoiceState.Error("请求失败: ${e.message}")) }
            }
        }
    }

    /**
     * Speak the assistant's reply via TTS.
     */
    private fun speakReply(text: String) {
        Log.i(TAG, "speakReply: synthesizing, text='${text.take(80)}'")
        _state.update { it.copy(voiceState = VoiceState.Speaking) }

        viewModelScope.launch {
            try {
                val normalizedText = com.rd.siri.tts.TextNormalizer.normalize(text)
                Log.i(TAG, "speakReply: normalized text='${normalizedText.take(80)}'")
                val pcm = withContext(Dispatchers.IO) {
                    ttsEngine.synthesize(normalizedText, sid = speakerId)
                }
                if (pcm != null) {
                    Log.i(TAG, "speakReply: TTS done, pcm samples=${pcm.size}, playing")
                    audioPlayer.play(pcm, ttsEngine.getSampleRate())
                } else {
                    Log.e(TAG, "speakReply: TTS returned null PCM")
                }
            } catch (e: Exception) {
                Log.e(TAG, "speakReply: TTS failed", e)
            } finally {
                _state.update { it.copy(voiceState = VoiceState.Idle) }
            }
        }
    }

    fun stopSpeaking() {
        audioPlayer.stop()
        _state.update { it.copy(voiceState = VoiceState.Idle) }
    }

    fun cycleSpeakerId(): Int {
        speakerId = (speakerId + 1) % 10
        return speakerId
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
    }
}
