package com.lodo.app.ui

import com.lodo.app.core.CurrentLang
import com.lodo.app.core.Lang

/**
 * 这一轮新页面的双语文案:按应用内语言取中文或英文。
 *
 * 老页面的文案在 i18n/strings.csv 里生成成 R.string;新页面数量大、还在快速变,
 * 先就地写成一对字面量(中文为准,英文对照)。切换语言会重建 Activity,
 * CurrentLang 在那之前已经更新,所以这里直接读当前值即可。
 */
fun L(zh: String, en: String): String = if (UiLang.current == Lang.EN) en else zh

/**
 * 界面这一侧的语言状态(Compose 快照状态)。切换语言**不重建 Activity**(清单里声明了
 * `configChanges="locale|layoutDirection"`,重建那一下整屏黑一帧,就是"闪烁"的来源):
 * `stringResource` 跟着 LocalConfiguration 自己刷新,`L()`/`appLocale()` 读这里,
 * 组合时读到的地方语言一变就重组。core 包仍读 CurrentLang(纯 Kotlin,不能依赖 Compose)。
 */
object UiLang {
    private val state = androidx.compose.runtime.mutableStateOf(CurrentLang.value)
    var current: Lang
        get() = state.value
        set(value) { state.value = value }
}

/** 应用内语言对应的 Locale(星期、月份名跟着应用语言走,不跟系统语言)。 */
fun appLocale(): java.util.Locale =
    if (UiLang.current == Lang.EN) java.util.Locale.ENGLISH else java.util.Locale.SIMPLIFIED_CHINESE

/** 带应用内语言的日期格式;新页面一律用它,不要直接 DateTimeFormatter.ofPattern(…)。 */
fun appFormatter(pattern: String): java.time.format.DateTimeFormatter =
    java.time.format.DateTimeFormatter.ofPattern(pattern, appLocale())
