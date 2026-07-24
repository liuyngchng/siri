package com.rd.siri.chat

import com.rd.siri.config.ConfigRepository
import com.rd.siri.config.LlmConfig
import com.rd.siri.model.ChatMessage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import android.util.Log
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

class LlmClient(private val configRepository: ConfigRepository) {

    companion object {
        private fun buildSystemPrompt(ragContext: String? = null): String {
            val now = java.text.SimpleDateFormat(
                "yyyy年M月d日", java.util.Locale.CHINESE
            ).format(java.util.Date())
            val week = java.text.SimpleDateFormat(
                "EEEE", java.util.Locale.CHINESE
            ).format(java.util.Date())

            val knowledgeSection = if (!ragContext.isNullOrBlank()) {
                """
## 客服知识库信息
- 今日日期：$now（星期$week）
- 知识库内容：
---
$ragContext
---
"""
            } else {
                """
## 客服知识库信息
- 今日日期：$now（星期$week）
- 知识库内容：暂无匹配的知识库条目，请引导客户转接人工。
"""
            }

            return """## 角色
你是燃气公司的客服，负责解答客户咨询，处理气费、营业厅、维修进度等问题。你必须基于客服知识库信息回答用户问题，若用户描述的问题比较模糊，需要引导客户说出正确的问题，当客服知识库信息中无用户问题相关的答案时，需要引导客户转接人工，回复话术"这个问题我还在学习中呢，我一定更加努力，为您提供更优质的服务。如需人工服务，请点击人工客服，转接人工处理。(寒暄闲聊除外)"。

## 闲聊与寒暄的判定
- 如果用户的消息明显与燃气业务无关，比如问候、玩笑、日常话题等，请不要触发知识库查询，直接以亲切、幽默的方式回应，并巧妙引导回燃气咨询。
- 示例：
  用户："我没给汽水付钱"
  客服："哈哈，您太幽默了，我们只收燃气费，不卖汽水哦～请问有什么燃气方面的问题可以帮您呢？"
  用户："今天天气真好"
  客服："是呀，心情都跟着变好了呢！您有燃气方面的问题随时告诉我哈～"
- 注意：即使消息中含有"钱、付、缴费"等词，若语境明显为玩笑/闲聊，仍按闲聊处理，不触发知识库查询。

## 工作流程
1. 常规咨询处理（如气费、营业厅、气价等）：
   - 【最高优先级-强制前置】当用户问题涉及地点（如"这里有营业厅吗"），且未明确指定具体燃气公司全称时，你的首次响应必须是询问城市，绝对禁止在询问城市之前直接输出营业厅地址。
   - 用户提供城市后，你必须显式地执行公司数量判断：
     - 情况A（多公司）：如果提供的城市存在两个或两个以上的燃气公司，必须使用以下话术询问：
       "您好，请选择您的燃气公司：\n公司名称1\n公司名称2"
     - 情况B（单公司）：如果提供的城市只存在一个燃气公司（如昆明），且该公司网点数量较多，必须执行多网点输出限制策略（见下方第4点），严禁直接一次性罗列所有网点。
   - 必须从客服知识库查找答案，若知识库中没有时，引导咨询人工客服，禁止胡编乱造。
   - 回复需友好热情，使用"您"称呼客户，避免"客户"字样。

2. 工单催派处理（用户反馈维修人员未上门）：
   - 请用户提供维修单号，并查询进度。
   - 若用户情绪生气，回复："不好意思，将为您转接人工客服提供升级服务"并保留标签：人工客服

3. 闲聊与寒暄：
   - 响应客户的寒暄闲聊，保持友好，但不过度展开。

4. 多网点输出限制策略：
   - 触发条件：当确认了公司，且该公司在对应城市的营业网点超过8个时。
   - 首次响应规则：你必须主动引导用户缩小范围，禁止一次性列出所有网点。请按以下步骤执行：
     - 步骤1（区域引导）：使用话术："为您找到 公司全称 在 城市 的多个服务网点。请问您去哪个区比较方便呢？比如官渡区、西山区？我帮您精准查询 😊"
     - 步骤2（精准回复）：待用户提供区域后，从知识库中筛选该区域的网点进行展示。若该区域无网点，则推荐最近的或市级中心网点。
     - 步骤3（兜底推荐）：若用户不指定区域，则执行核心推荐策略："那我先为您推荐一个中心营业厅：最核心的1个营业厅。查询更多附近网点，可点击网点导航 👉 营业网点导航"
   - 注意：即使网点数量少于8个，也鼓励优先采用此策略提升体验，但可按原格式简要列出。

## 特别注意
- 你不具备任何外呼、记录反馈、核实、催单、派单或短信通知能力，禁止承诺处理时效、持续跟进、结果告知等通知方式或主动反馈跟进。
- 禁止使用一些不符合客服语境的语气词，比如"哈哈"这种带有嘲笑、不尊重的词。

## 回答要求
- 准确性：必须基于客服知识库回复，若知识库没有，引导咨询人工客服，禁止胡编乱造。
- 格式保留：保留原始文本的格式。
- 语言风格：口语化、符合客服的语境亲切自然，可以合理使用emoji表情，让内容更生动，避免机械冰冷。
- 复杂信息排版：气价、营业厅等复杂信息可使用Markdown加粗重点、分点列出。
- 情感表达：带情感地输出，体现共情和耐心。

## 回答示例
### 如何查看余额
- 1、如果您家是物联网表：
- （1）可以短按一下燃气表旁的显示按钮，显示屏上会显示您的剩余金额，再次点击可显示累积用气量、气价等信息哦。
- （2）进入"昆仑慧享+"服务号，绑定用户号后，界面上会显示您的余额。
- 2、如果您家是插卡燃气表，燃气表插卡时会显示剩余气量哦。操作方法您可以参考下面的视频链接哦：
如何在燃气表上查询余额

$knowledgeSection
## 全部历史消息
（历史消息已在上方对话中提供，请结合上下文理解用户意图）"""
        }

        private val JSON_MEDIA_TYPE = "application/json".toMediaType()

        data class LlmParams(
            val maxTokens: Int = 1024,
            val temperature: Double = 0.7,
            val topP: Double = 0.9
        )
    }

    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(120, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .build()

    private val defaultParams = LlmParams()

    suspend fun chat(
        messages: List<ChatMessage>,
        params: LlmParams = defaultParams,
        ragContext: String? = null
    ): Result<String> = withContext(Dispatchers.IO) {
        val config = loadConfig() ?: return@withContext Result.failure(
            IllegalStateException("请先在设置中配置 API 信息")
        )

        runCatching {
            val body = buildRequestBody(messages, config, params, stream = false, ragContext = ragContext)
            val request = buildRequest(config, body)

            val response = client.newCall(request).execute()
            if (!response.isSuccessful) {
                val errorBody = response.body?.string() ?: "未知错误"
                throw Exception("API 错误 (${response.code}): ${errorBody.take(300)}")
            }

            val json = JSONObject(response.body?.string() ?: "{}")
            json.getJSONArray("choices")
                .getJSONObject(0)
                .getJSONObject("message")
                .getString("content")
        }
    }

    fun chatStream(
        messages: List<ChatMessage>,
        params: LlmParams = defaultParams,
        ragContext: String? = null
    ): Flow<String> = flow {
        val config = loadConfig() ?: throw IllegalStateException("请先在设置中配置 API 信息")

        val body = buildRequestBody(messages, config, params, stream = true, ragContext = ragContext)
        val request = buildRequest(config, body)

        val response = client.newCall(request).execute()

        if (!response.isSuccessful) {
            val errorBody = response.body?.string() ?: "未知错误"
            throw Exception("API 错误 (${response.code}): ${errorBody.take(300)}")
        }

        val reader = BufferedReader(InputStreamReader(response.body?.byteStream() ?: return@flow))

        reader.useLines { lines ->
            for (line in lines) {
                if (line.startsWith("data: ")) {
                    val data = line.removePrefix("data: ").trim()
                    if (data == "[DONE]") break

                    try {
                        val json = JSONObject(data)
                        val choices = json.optJSONArray("choices")
                        if (choices != null && choices.length() > 0) {
                            val delta = choices.getJSONObject(0).optJSONObject("delta")
                            if (delta != null && delta.has("content") && !delta.isNull("content")) {
                                val content = delta.getString("content")
                                if (content.isNotEmpty()) {
                                    emit(content)
                                }
                            }
                        }
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }.flowOn(Dispatchers.IO)

    private fun loadConfig(): LlmConfig? = configRepository.getConfig()

    private fun buildRequestBody(
        messages: List<ChatMessage>,
        config: LlmConfig,
        params: LlmParams,
        stream: Boolean,
        ragContext: String? = null
    ): String {
        val msgArray = JSONArray()

        msgArray.put(JSONObject().apply {
            put("role", "system")
            put("content", buildSystemPrompt(ragContext))
        })

        for (msg in messages) {
            msgArray.put(JSONObject().apply {
                put("role", msg.role.value)
                put("content", msg.content)
            })
        }

        return JSONObject().apply {
            put("model", config.model)
            put("messages", msgArray)
            put("stream", stream)
            put("max_tokens", params.maxTokens)
            put("temperature", params.temperature)
            put("top_p", params.topP)
            if (config.enableSearch && config.searchParamName.isNotBlank()) {
                Log.i("LlmClient", "联网搜索已启用, param=${config.searchParamName}")
                put(config.searchParamName, true)
            }
        }.toString()
    }

    private fun buildRequest(config: LlmConfig, body: String): Request =
        Request.Builder()
            .url(config.chatCompletionsUrl)
            .addHeader("Authorization", "Bearer ${config.apiKey}")
            .addHeader("Content-Type", "application/json")
            .post(body.toRequestBody(JSON_MEDIA_TYPE))
            .build()
}
