package com.lodo.app.data

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONTokener
import kotlin.coroutines.resume

/**
 * 前端渲染的网页(直接抓 HTML 只有一个空壳)在本机用一个不上屏的 WebView 渲染一遍,
 * 再把渲染后的 DOM 交给同一个正文抽取(同 iOS RenderedPageLoader)。
 * 只加载文章链接本身;用完清缓存、销毁,不留 cookie 以外的东西。超时 15 秒算失败。
 */
object RenderedPageLoader {
    @SuppressLint("SetJavaScriptEnabled")
    suspend fun html(context: Context, url: String): String? = withContext(Dispatchers.Main) {
        val web = WebView(context.applicationContext)
        try {
            web.settings.javaScriptEnabled = true
            web.settings.blockNetworkImage = true
            withTimeoutOrNull(15_000) {
                suspendCancellableCoroutine<Unit> { cont ->
                    web.webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, finished: String) {
                            if (cont.isActive) cont.resume(Unit)
                        }
                    }
                    web.loadUrl(url)
                }
                delay(1_500)   // 等页面脚本把正文渲染出来
                suspendCancellableCoroutine<String?> { cont ->
                    web.evaluateJavascript("document.documentElement.outerHTML") { raw ->
                        val html = runCatching { JSONTokener(raw).nextValue() as? String }.getOrNull()
                        if (cont.isActive) cont.resume(html)
                    }
                }
            }
        } finally {
            web.stopLoading()
            web.clearCache(true)
            web.destroy()
        }
    }
}
