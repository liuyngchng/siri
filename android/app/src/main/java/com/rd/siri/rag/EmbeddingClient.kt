package com.rd.siri.rag

import android.util.Log
import com.rd.siri.config.ConfigRepository
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * OpenAI 兼容 embedding API 客户端。
 * 与 LlmClient 共用 base URL + API key，只需额外配置 embedding model。
 */
class EmbeddingClient(private val configRepository: ConfigRepository) {

    companion object {
        private const val TAG = "SiriApp"
        private val JSON_MEDIA_TYPE = "application/json".toMediaType()
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    data class EmbeddingConfig(
        val apiBase: String,       // e.g. "https://dashscope.aliyuncs.com/compatible-mode/v1"
        val apiKey: String,
        val model: String          // e.g. "text-embedding-v3"
    )

    /** 从 ConfigRepository 读取 embedding 配置，复用 LLM 的 base URL 和 API key */
    private fun loadConfig(): EmbeddingConfig? {
        val llmConfig = configRepository.getConfig() ?: return null
        val embeddingModel = configRepository.getEmbeddingModel()
        return EmbeddingConfig(
            apiBase = llmConfig.baseUrl,
            apiKey = llmConfig.apiKey,
            model = embeddingModel
        )
    }

    /**
     * 将单段文本嵌入为向量。
     */
    suspend fun embed(text: String): FloatArray? = withContext(Dispatchers.IO) {
        val cfg = loadConfig() ?: run {
            Log.w(TAG, "EmbeddingClient: no config available")
            return@withContext null
        }

        runCatching {
            val body = JSONObject().apply {
                put("model", cfg.model)
                put("input", text)
            }

            val request = Request.Builder()
                .url("${cfg.apiBase}/embeddings")
                .addHeader("Authorization", "Bearer ${cfg.apiKey}")
                .addHeader("Content-Type", "application/json")
                .post(body.toString().toRequestBody(JSON_MEDIA_TYPE))
                .build()

            val response = client.newCall(request).execute()
            if (!response.isSuccessful) {
                val errorBody = response.body?.string() ?: "未知错误"
                Log.e(TAG, "EmbeddingClient: API error (${response.code}): ${errorBody.take(200)}")
                return@runCatching null
            }

            val json = JSONObject(response.body?.string() ?: "{}")
            val embeddingArr = json
                .getJSONArray("data")
                .getJSONObject(0)
                .getJSONArray("embedding")

            val vec = FloatArray(embeddingArr.length())
            for (i in 0 until embeddingArr.length()) {
                vec[i] = embeddingArr.getDouble(i).toFloat()
            }
            vec
        }.getOrNull()
    }
}
