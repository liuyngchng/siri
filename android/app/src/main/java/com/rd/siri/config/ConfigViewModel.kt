package com.rd.siri.config

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

sealed class ConnectionTestResult {
    object Idle : ConnectionTestResult()
    object Testing : ConnectionTestResult()
    data class Success(val message: String) : ConnectionTestResult()
    data class Failure(val error: String) : ConnectionTestResult()
}

class ConfigViewModel(application: Application) : AndroidViewModel(application) {

    private val repository = ConfigRepository(application)

    private val _config = MutableStateFlow(repository.getConfig())
    val config: StateFlow<LlmConfig?> = _config.asStateFlow()

    private val _testResult = MutableStateFlow<ConnectionTestResult>(ConnectionTestResult.Idle)
    val testResult: StateFlow<ConnectionTestResult> = _testResult.asStateFlow()

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    fun saveConfig(apiUrl: String, model: String, apiKey: String, enableSearch: Boolean = false, searchParamName: String = "enable_search") {
        val trimmedUrl = apiUrl.trim().trimEnd('/')
        val trimmedModel = model.trim()
        val trimmedKey = apiKey.trim()

        if (trimmedUrl.isBlank() || trimmedModel.isBlank() || trimmedKey.isBlank()) {
            _testResult.value = ConnectionTestResult.Failure("所有字段不能为空")
            return
        }

        if (!trimmedUrl.startsWith("http://") && !trimmedUrl.startsWith("https://")) {
            _testResult.value = ConnectionTestResult.Failure("API 地址必须以 http:// 或 https:// 开头")
            return
        }

        val newConfig = LlmConfig(trimmedUrl, trimmedModel, trimmedKey, enableSearch, searchParamName)
        repository.saveConfig(newConfig)
        _config.value = newConfig
        _testResult.value = ConnectionTestResult.Success("配置已保存")
    }

    fun testConnection(apiUrl: String, model: String, apiKey: String) {
        if (apiUrl.isBlank() || model.isBlank() || apiKey.isBlank()) {
            _testResult.value = ConnectionTestResult.Failure("请先填写完整信息")
            return
        }

        viewModelScope.launch {
            _testResult.value = ConnectionTestResult.Testing

            val baseUrl = apiUrl.trim().trimEnd('/')
            val key = apiKey.trim()
            val llmModel = model.trim()

            val llmResult = withContext(Dispatchers.IO) { testLLM(baseUrl, llmModel, key) }
            val embResult = withContext(Dispatchers.IO) { testEmbedding(baseUrl, key) }

            _testResult.value = when {
                llmResult is ConnectionTestResult.Success && embResult is ConnectionTestResult.Success ->
                    ConnectionTestResult.Success("连接成功！LLM OK, Embedding OK")
                llmResult is ConnectionTestResult.Success && embResult is ConnectionTestResult.Failure ->
                    ConnectionTestResult.Failure("LLM OK, 但 Embedding 失败: ${embResult.error}")
                llmResult is ConnectionTestResult.Failure && embResult is ConnectionTestResult.Success ->
                    ConnectionTestResult.Failure("LLM 失败: ${llmResult.error}")
                llmResult is ConnectionTestResult.Failure && embResult is ConnectionTestResult.Failure ->
                    ConnectionTestResult.Failure("LLM 失败: ${llmResult.error}\nEmbedding 也失败: ${embResult.error}")
                else -> ConnectionTestResult.Failure("未知错误")
            }
        }
    }

    private fun testLLM(baseUrl: String, model: String, apiKey: String): ConnectionTestResult {
        return try {
            val body = JSONObject().apply {
                put("model", model)
                put("messages", JSONArray().apply {
                    put(JSONObject().apply {
                        put("role", "user")
                        put("content", "hi")
                    })
                })
                put("max_tokens", 1)
            }

            val request = Request.Builder()
                .url("$baseUrl/chat/completions")
                .addHeader("Authorization", "Bearer $apiKey")
                .addHeader("Content-Type", "application/json")
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val response = client.newCall(request).execute()

            if (response.isSuccessful) {
                ConnectionTestResult.Success("OK")
            } else {
                val errorBody = response.body?.string() ?: "未知错误"
                ConnectionTestResult.Failure("${response.code} ${errorBody.take(100)}")
            }
        } catch (e: java.net.UnknownHostException) {
            ConnectionTestResult.Failure("无法解析地址")
        } catch (e: java.net.ConnectException) {
            ConnectionTestResult.Failure("连接被拒绝")
        } catch (e: java.net.SocketTimeoutException) {
            ConnectionTestResult.Failure("连接超时")
        } catch (e: javax.net.ssl.SSLHandshakeException) {
            ConnectionTestResult.Failure("SSL 证书验证失败")
        } catch (e: Exception) {
            ConnectionTestResult.Failure(e.message ?: "未知错误")
        }
    }

    private fun testEmbedding(baseUrl: String, apiKey: String): ConnectionTestResult {
        return try {
            val embeddingModel = repository.getEmbeddingModel()
            val body = JSONObject().apply {
                put("model", embeddingModel)
                put("input", "test")
            }

            val request = Request.Builder()
                .url("$baseUrl/embeddings")
                .addHeader("Authorization", "Bearer $apiKey")
                .addHeader("Content-Type", "application/json")
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()

            val response = client.newCall(request).execute()

            if (response.isSuccessful) {
                ConnectionTestResult.Success("OK")
            } else {
                val errorBody = response.body?.string() ?: "未知错误"
                ConnectionTestResult.Failure("${response.code} ${errorBody.take(100)}")
            }
        } catch (e: java.net.UnknownHostException) {
            ConnectionTestResult.Failure("无法解析地址")
        } catch (e: java.net.ConnectException) {
            ConnectionTestResult.Failure("连接被拒绝")
        } catch (e: java.net.SocketTimeoutException) {
            ConnectionTestResult.Failure("连接超时")
        } catch (e: javax.net.ssl.SSLHandshakeException) {
            ConnectionTestResult.Failure("SSL 证书验证失败")
        } catch (e: Exception) {
            ConnectionTestResult.Failure(e.message ?: "未知错误")
        }
    }

    fun clearConfig() {
        repository.clearConfig()
        _config.value = null
        _testResult.value = ConnectionTestResult.Idle
    }

    fun resetTestResult() {
        _testResult.value = ConnectionTestResult.Idle
    }
}
