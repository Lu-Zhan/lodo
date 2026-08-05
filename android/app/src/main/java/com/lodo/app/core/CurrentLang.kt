package com.lodo.app.core

/** 当前应用语言,由 SettingsRepository 的语言设置同步写入。core/ai/notify 包
 * 不能 import Android 类,拿不到 Context,只能靠这个显式的当前状态读取,而不是
 * 每个函数签名都加 lang 参数——错误文案/通知文案都是终态、直接展示给用户的
 * 内容,不会被拼回发给 AI 的下一轮请求,不存在 repeatLabel/caption 那类会被
 * AI prompt 拼装复用的污染风险,所以这里用环境状态是安全的简化,不是偷懒。 */
object CurrentLang {
    @Volatile
    var value: Lang = Lang.ZH
}
