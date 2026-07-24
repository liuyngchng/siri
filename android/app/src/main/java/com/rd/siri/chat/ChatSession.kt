package com.rd.siri.chat

import android.util.Log
import com.rd.siri.config.ConfigRepository
import com.rd.siri.model.ChatMessage
import com.rd.siri.rag.HybridSearcher
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

class ChatSession(
    private val llmClient: LlmClient,
    private val configRepository: ConfigRepository,
    private val hybridSearcher: HybridSearcher? = null,
    private val maxHistory: Int = 5,
    private val maxScreenMessages: Int = 20,
    private val maxContextBufferSize: Int = 200
) {

    companion object {
        private const val TAG = "SiriApp"
    }

    /** Messages shown on screen — capped at [maxScreenMessages]. */
    private val _messages = MutableStateFlow<List<ChatMessage>>(emptyList())
    val messages: StateFlow<List<ChatMessage>> = _messages.asStateFlow()

    /**
     * Full LLM context buffer — preserved across screen clears.
     * Grows unboundedly; only the last [maxHistory] messages are sent to the LLM.
     */
    private val contextBuffer = mutableListOf<ChatMessage>()

    /** LLM context window: last [maxHistory] messages from the full context buffer. */
    private val contextMessages: List<ChatMessage>
        get() = contextBuffer.takeLast(maxHistory)

    /** Append a message to the on-screen list, trimming to [maxScreenMessages]. */
    private fun appendToScreen(msg: ChatMessage) {
        _messages.value = (_messages.value + msg).takeLast(maxScreenMessages)
    }

    /** Append to context buffer and trim to [maxContextBufferSize] to bound memory. */
    private fun appendToContext(msg: ChatMessage) {
        contextBuffer.add(msg)
        if (contextBuffer.size > maxContextBufferSize) {
            val excess = contextBuffer.size - maxContextBufferSize
            contextBuffer.subList(0, excess).clear()
        }
    }

    /**
     * 混合检索：向量语义 + BM25 关键词 → RRF 融合。
     * 如果 HybridSearcher 未配置或 RAG 被禁用，返回 null。
     */
    private suspend fun retrieveContext(userText: String): String? {
        if (hybridSearcher == null) return null
        if (!configRepository.isRagEnabled()) return null

        val results = hybridSearcher.search(userText, topK = 3)
        if (results.isEmpty()) {
            Log.d(TAG, "retrieveContext: no relevant chunks found")
            return null
        }

        Log.i(TAG, "retrieveContext: found ${results.size} chunks, " +
                "top RRF scores: " + results.map { "%.4f".format(it.score) })

        return results.joinToString("\n---\n") { result ->
            result.content
        }
    }

    suspend fun send(text: String): Result<String> {
        val userMsg = ChatMessage(role = ChatMessage.Role.USER, content = text)
        appendToScreen(userMsg)
        appendToContext(userMsg)

        val ragContext = retrieveContext(text)
        val result = llmClient.chat(contextMessages, ragContext = ragContext)

        result.onSuccess { reply ->
            val assistantMsg = ChatMessage(role = ChatMessage.Role.ASSISTANT, content = reply)
            appendToScreen(assistantMsg)
            appendToContext(assistantMsg)
        }.onFailure {
            // Rollback both buffers on failure
            _messages.value = _messages.value.dropLast(1)
            contextBuffer.removeAt(contextBuffer.lastIndex)
        }

        return result
    }

    suspend fun sendStream(text: String): Result<Flow<String>> {
        val userMsg = ChatMessage(role = ChatMessage.Role.USER, content = text)
        appendToScreen(userMsg)
        appendToContext(userMsg)

        val ragContext = retrieveContext(text)

        return try {
            val flow = llmClient.chatStream(contextMessages, ragContext = ragContext)
            Result.success(flow)
        } catch (e: Exception) {
            _messages.value = _messages.value.dropLast(1)
            contextBuffer.removeAt(contextBuffer.lastIndex)
            Result.failure(e)
        }
    }

    fun appendAssistantReply(text: String) {
        if (text.isBlank()) return
        val assistantMsg = ChatMessage(role = ChatMessage.Role.ASSISTANT, content = text)
        appendToScreen(assistantMsg)
        appendToContext(assistantMsg)
    }

    /** Remove the last user message from both screen and context buffer.
     *  Used when a recording is cancelled before the LLM reply arrives,
     *  so the orphaned user message does not affect the next conversation. */
    fun clearLastUserMessage() {
        val screenMsgs = _messages.value.toMutableList()
        if (screenMsgs.isNotEmpty() && screenMsgs.last().role == ChatMessage.Role.USER) {
            screenMsgs.removeAt(screenMsgs.lastIndex)
            _messages.value = screenMsgs
        }
        if (contextBuffer.isNotEmpty() && contextBuffer.last().role == ChatMessage.Role.USER) {
            contextBuffer.removeAt(contextBuffer.lastIndex)
        }
    }

    /** Full clear — both screen and LLM context (user-initiated). */
    fun clear() {
        _messages.value = emptyList()
        contextBuffer.clear()
    }

    val messageCount: Int
        get() = _messages.value.size
}
