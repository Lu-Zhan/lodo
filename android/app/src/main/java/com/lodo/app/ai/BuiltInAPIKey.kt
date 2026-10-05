package com.lodo.app.ai

import com.lodo.app.BuildConfig

/**
 * 内置的 AI 服务商 API key,对应 iOS BuiltInAPIKey:真实值写在 gitignored 的
 * `android/local.properties`(`lodo.deepseekKey=…`),构建时进 BuildConfig,仓库里没有。
 * 没配时返回 null,app 按"没有内置 key"处理(设置里不显示开关,照常让用户填)。
 */
object BuiltInAPIKey {
    private val deepSeek: String? = BuildConfig.BUILT_IN_DEEPSEEK_KEY.takeIf { it.isNotBlank() }

    /** 按服务商名查内置 key;DeepSeek 两档(以及改名前的老名字)共用一把。 */
    fun key(provider: String): String? = when (provider) {
        "DeepSeek Flash", "DeepSeek V4 Pro", "DeepSeek", "DeepSeek V4 Flash Vision" -> deepSeek
        else -> null
    }
}
