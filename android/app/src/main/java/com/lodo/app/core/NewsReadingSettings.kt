package com.lodo.app.core

/**
 * 新闻总结用哪种语言(同 iOS `NewsSummaryLanguage`):单篇总结和「今日」总结共用。
 * 存储值别改(`""` = 跟随应用语言)。
 */
enum class NewsSummaryLanguage(val raw: String) {
    FOLLOW_APP(""), CHINESE("zh"), ENGLISH("en"), JAPANESE("ja"), KOREAN("ko"), ORIGINAL("original");

    /** 选项上显示的名字(语言名本身不翻译,同 iOS displayName)。 */
    fun displayName(appEnglish: Boolean): String = when (this) {
        FOLLOW_APP -> if (appEnglish) "Follow app" else "跟随应用语言"
        CHINESE -> "中文"
        ENGLISH -> "English"
        JAPANESE -> "日本語"
        KOREAN -> "한국어"
        ORIGINAL -> if (appEnglish) "Same as article" else "与原文相同"
    }

    /** 拼进 prompt 的语言名;跟随应用时用应用语言那一个(由调用方给)。 */
    fun promptName(appLanguageName: String): String = when (this) {
        FOLLOW_APP -> appLanguageName
        CHINESE -> "中文"
        ENGLISH -> "英文"
        JAPANESE -> "日文"
        KOREAN -> "韩文"
        ORIGINAL -> "文章原文所用的语言"
    }

    companion object {
        fun from(raw: String?) = entries.firstOrNull { it.raw == raw } ?: FOLLOW_APP
    }
}
