package com.lodo.app.ai

import com.lodo.app.core.CurrentLang
import com.lodo.app.core.Strings
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

    /** 与 iOS MemorySearch.maxSourceChars 同一个量级,ReAct 工具的观测结果
     * 不需要比这更长,超长页面截断不影响 AI 抓重点。 */
    private const val maxFetchChars = 8000

    data class Result(val title: String, val url: String, val snippet: String)

    private val client = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    /** web_fetch ReAct 工具:抓取用户给的具体链接并提取正文纯文本。没有
     * readability 之类的第三方库,用简单的标签剥离(先去 script/style/注释,
     * 再去所有标签、折叠空白),与 iOS ContentExtractor 的 WebKit HTML→纯文本
     * 转换效果相近但实现更朴素——够 AI 理解页面大意即可,不追求排版还原。 */
    suspend fun fetchUrl(url: String): String = withContext(Dispatchers.IO) {
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            throw DeepSeekException(Strings.translate("无效链接:", CurrentLang.value) + url)
        }
        val request = Request.Builder().url(url).build()
        client.newCall(request).execute().use { resp ->
            if (!resp.isSuccessful) {
                throw DeepSeekException(Strings.translate("抓取链接失败:HTTP ", CurrentLang.value) + resp.code)
            }
            val html = resp.body?.string().orEmpty()
            extractText(html).take(maxFetchChars)
        }
    }

    private fun extractText(html: String): String {
        val stripped = html
            .replace(Regex("(?is)<script.*?</script>"), " ")
            .replace(Regex("(?is)<style.*?</style>"), " ")
            .replace(Regex("(?is)<!--.*?-->"), " ")
            .replace(Regex("(?is)<[^>]+>"), " ")
        val decoded = stripped
            .replace("&nbsp;", " ")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&#39;", "'")
        return decoded.replace(Regex("\\s+"), " ").trim()
    }

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
                    throw DeepSeekException(Strings.translate("联网搜索失败:", CurrentLang.value) + "HTTP ${resp.code} ${text.take(200)}")
                }
                val results = try {
                    JSONObject(text).optJSONArray("results")
                } catch (_: Exception) {
                    throw DeepSeekException(Strings.translate("联网搜索失败:返回格式异常", CurrentLang.value))
                } ?: throw DeepSeekException(Strings.translate("联网搜索失败:返回格式异常", CurrentLang.value))
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
