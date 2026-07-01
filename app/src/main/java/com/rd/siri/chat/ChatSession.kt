package com.rd.siri.chat

import com.rd.siri.model.ChatMessage
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class ChatSession(private val llmClient: LlmClient) {

    companion object {
        private const val MAX_HISTORY = 20
    }

    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages: StateFlow<List<ChatMessage>> = _messages.asStateFlow()

    suspend fun send(text: String): Result<String> {
        val userMsg = ChatMessage(role = ChatMessage.Role.USER, content = text)
        _messages.value = (_messages.value + userMsg).takeLast(MAX_HISTORY)

        val result = llmClient.chat(_messages.value)

        result.onSuccess { reply ->
            val assistantMsg = ChatMessage(role = ChatMessage.Role.ASSISTANT, content = reply)
            _messages.value = (_messages.value + assistantMsg).takeLast(MAX_HISTORY)
        }.onFailure {
            _messages.value = _messages.value.dropLast(1)
        }

        return result
    }

    suspend fun sendStream(text: String): Result<Flow<String>> {
        val userMsg = ChatMessage(role = ChatMessage.Role.USER, content = text)
        _messages.value = (_messages.value + userMsg).takeLast(MAX_HISTORY)

        return try {
            val flow = llmClient.chatStream(_messages.value)
            Result.success(flow)
        } catch (e: Exception) {
            _messages.value = _messages.value.dropLast(1)
            Result.failure(e)
        }
    }

    fun appendAssistantReply(text: String) {
        if (text.isBlank()) return
        val assistantMsg = ChatMessage(role = ChatMessage.Role.ASSISTANT, content = text)
        _messages.value = (_messages.value + assistantMsg).takeLast(MAX_HISTORY)
    }

    fun clear() {
        _messages.value = emptyList()
    }

    val messageCount: Int
        get() = _messages.value.size
}
