package com.lodo.app.ai

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/** 联网搜索:接 Tavily(https://tavily.com,专为 AI agent 设计的搜索 API,免费额度
 * 每月 1000 次),供 AI 助手的 web_search ReAct 工具用。key 存取复用
 * SettingsRepository.apiKey(provider)/saveApiKey(key, provider) 那一套按"服务商"
 * 分存的机制,把 Tavily 当一个服务商——不单独加一套存取逻辑。与 iOS
 * WebSearchClient 逐字一致的实现思路。 */
object WebSearchClient {
    const val PROVIDER_NAME = "Tavily"

    data class Result(val title: String, val url: String, val snippet: String)

    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    suspend fun search(apiKey: String, query: String, maxResults: Int = 5): List<Result> =
        withContext(Dispatchers.IO) {
            val body = JSONObject()
                .put("api_key", apiKey)
                .put("query", query)
                .put("search_depth", "basic")
                .put("max_results", maxResults)
            val request = Request.Builder()
                .url("https://api.tavily.com/search")
                .post(body.toString().toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(request).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                if (resp.code != 200) {
                    throw DeepSeekException("联网搜索失败:HTTP ${resp.code} ${text.take(200)}")
                }
                val results = try {
                    JSONObject(text).optJSONArray("results")
                } catch (_: Exception) {
                    throw DeepSeekException("联网搜索失败:返回格式异常")
                } ?: throw DeepSeekException("联网搜索失败:返回格式异常")
                (0 until results.length()).mapNotNull { i ->
                    val item = results.optJSONObject(i) ?: return@mapNotNull null
                    val title = item.optString("title")
                    val url = item.optString("url")
                    if (title.isEmpty() || url.isEmpty()) return@mapNotNull null
                    Result(title, url, item.optString("content"))
                }
            }
        }
}
