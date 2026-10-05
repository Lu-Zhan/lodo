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
fun L(zh: String, en: String): String = if (CurrentLang.value == Lang.EN) en else zh
