package com.rd.siri.model

sealed class VoiceState {
    object Idle : VoiceState()
    data class Loading(val message: String = "模型加载中…") : VoiceState()
    object Listening : VoiceState()
    object Recognizing : VoiceState()
    object Thinking : VoiceState()
    object Speaking : VoiceState()
    data class Error(val message: String) : VoiceState()
}

data class AppState(
    val voiceState: VoiceState = VoiceState.Loading(),
    val enginesReady: Boolean = false,
    val partialAsrText: String = "",
    val finalAsrText: String = "",
    val assistantReply: String = "",
    val hasConfig: Boolean = false,
    val wakeWordEnabled: Boolean = false,
    val connectionTestResult: String? = null
)
