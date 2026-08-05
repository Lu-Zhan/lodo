// 由 i18n/generate.py 从 i18n/strings.csv 生成,不要手改。
// 改动请回到 strings.csv 修订后重新运行脚本。


package com.lodo.app.core

/** 语言;不依赖 Android Context,core/ai/notify 包内显式传参用。 */
enum class Lang { ZH, EN }

/** 生成表:core/ai/notify 包(不能 import Android 类)的非资源文本查找。 */
object Strings {
    private val table: Map<String, Map<Lang, String>> = mapOf(
        "shared.mon" to mapOf(Lang.ZH to "周一", Lang.EN to "Mon"),
        "shared.tue" to mapOf(Lang.ZH to "周二", Lang.EN to "Tue"),
        "shared.wed" to mapOf(Lang.ZH to "周三", Lang.EN to "Wed"),
        "shared.thu" to mapOf(Lang.ZH to "周四", Lang.EN to "Thu"),
        "shared.fri" to mapOf(Lang.ZH to "周五", Lang.EN to "Fri"),
        "shared.sat" to mapOf(Lang.ZH to "周六", Lang.EN to "Sat"),
        "shared.sun" to mapOf(Lang.ZH to "周日", Lang.EN to "Sun"),
        "shared.efficient_secretary" to mapOf(Lang.ZH to "高效秘书", Lang.EN to "Efficient Secretary"),
        "shared.gentle_companion" to mapOf(Lang.ZH to "温柔陪伴", Lang.EN to "Gentle Companion"),
        "shared.strict_coach" to mapOf(Lang.ZH to "严格教练", Lang.EN to "Strict Coach"),
        "shared.playful_witty" to mapOf(Lang.ZH to "幽默轻松", Lang.EN to "Playful & Witty"),
        "shared.like_a_sharp_executive_assistant" to mapOf(Lang.ZH to "像一位干练的行政秘书:简洁、专业、直接,不说废话。", Lang.EN to "Like a sharp executive assistant: concise, professional, and direct—no fluff."),
        "shared.warm_and_caring_like_a_friend_who_looks" to mapOf(Lang.ZH to "语气温柔体贴,像关心你的朋友,多一点鼓励。", Lang.EN to "Warm and caring, like a friend who looks out for you—extra encouraging."),
        "shared.like_a_disciplined_coach_direct_and" to mapOf(Lang.ZH to "像自律教练:直接有推动力,催促按时完成,语气可以严厉但保持尊重。", Lang.EN to "Like a disciplined coach: direct and motivating, pushes you to finish on time, can be firm but stays respectful."),
        "shared.light_and_funny_a_bit_playful_makes" to mapOf(Lang.ZH to "轻松幽默,偶尔调皮,让提醒不那么无聊。", Lang.EN to "Light and funny, a bit playful—makes reminders less boring."),
        "shared.default" to mapOf(Lang.ZH to "默认", Lang.EN to "Default"),
        "shared.custom" to mapOf(Lang.ZH to "自定义", Lang.EN to "Custom"),
        "shared.tongyi_qianwen" to mapOf(Lang.ZH to "通义千问", Lang.EN to "Tongyi Qianwen"),
        "shared.zhipu" to mapOf(Lang.ZH to "智谱", Lang.EN to "Zhipu"),
        "shared.chinese_yuan" to mapOf(Lang.ZH to "人民币", Lang.EN to "Chinese Yuan"),
        "shared.us_dollar" to mapOf(Lang.ZH to "美元", Lang.EN to "US Dollar"),
        "shared.euro" to mapOf(Lang.ZH to "欧元", Lang.EN to "Euro"),
        "shared.japanese_yen" to mapOf(Lang.ZH to "日元", Lang.EN to "Japanese Yen"),
        "shared.british_pound" to mapOf(Lang.ZH to "英镑", Lang.EN to "British Pound"),
        "shared.hong_kong_dollar" to mapOf(Lang.ZH to "港币", Lang.EN to "Hong Kong Dollar"),
        "shared.south_korean_won" to mapOf(Lang.ZH to "韩元", Lang.EN to "South Korean Won"),
        "shared.australian_dollar" to mapOf(Lang.ZH to "澳元", Lang.EN to "Australian Dollar"),
        "shared.canadian_dollar" to mapOf(Lang.ZH to "加元", Lang.EN to "Canadian Dollar"),
        "shared.singapore_dollar" to mapOf(Lang.ZH to "新加坡元", Lang.EN to "Singapore Dollar"),
        "shared.swiss_franc" to mapOf(Lang.ZH to "瑞士法郎", Lang.EN to "Swiss Franc"),
        "shared.thai_baht" to mapOf(Lang.ZH to "泰铢", Lang.EN to "Thai Baht"),
        "shared.ai_personality" to mapOf(Lang.ZH to "AI 个性", Lang.EN to "AI Personality"),
        "shared.ai_assistant" to mapOf(Lang.ZH to "AI 助手", Lang.EN to "AI Assistant"),
        "shared.ai_thinking" to mapOf(Lang.ZH to "AI 思考", Lang.EN to "AI Thinking"),
        "shared.ai_service" to mapOf(Lang.ZH to "AI 服务", Lang.EN to "AI Service"),
        "shared.ai_memory" to mapOf(Lang.ZH to "AI 记忆", Lang.EN to "AI Memory"),
        "shared.task_content" to mapOf(Lang.ZH to "事项内容", Lang.EN to "Task content"),
        "shared.ok" to mapOf(Lang.ZH to "好", Lang.EN to "OK"),
        "shared.todo" to mapOf(Lang.ZH to "待办", Lang.EN to "Todo"),
        "shared.done" to mapOf(Lang.ZH to "已完成", Lang.EN to "Done"),
        "shared.endpoint_chat_completions" to mapOf(Lang.ZH to "接口地址(…/chat/completions)", Lang.EN to "Endpoint (…/chat/completions)"),
        "shared.describe_the_ai_s_tone_e_g_like_a_wuxia" to mapOf(Lang.ZH to "描述 AI 的说话风格,例如:像武侠小说里的师父", Lang.EN to "Describe the AI's tone, e.g. like a wuxia master"),
        "shared.reminders" to mapOf(Lang.ZH to "提醒", Lang.EN to "Reminders"),
        "shared.undo" to mapOf(Lang.ZH to "撤销", Lang.EN to "Undo"),
        "shared.reschedule" to mapOf(Lang.ZH to "改期", Lang.EN to "Reschedule"),
        "shared.no_tasks_yet" to mapOf(Lang.ZH to "暂无待办事项", Lang.EN to "No tasks yet"),
        "shared.no_memory_yet_the_ai_fills_this_in" to mapOf(Lang.ZH to "暂无记忆;AI 会在事项完成后自动归纳,也可以直接在这里手写。", Lang.EN to "No memory yet; the AI fills this in automatically after tasks are completed, or you can write it yourself."),
        "shared.upcoming" to mapOf(Lang.ZH to "未来待办", Lang.EN to "Upcoming"),
        "shared.this_week_s_insight" to mapOf(Lang.ZH to "本周洞察", Lang.EN to "This Week's Insight"),
        "shared.add" to mapOf(Lang.ZH to "添加", Lang.EN to "Add"),
        "shared.add_a_time" to mapOf(Lang.ZH to "添加时间点", Lang.EN to "Add a time"),
        "shared.web_search" to mapOf(Lang.ZH to "联网搜索", Lang.EN to "Web Search"),
        "shared.settings" to mapOf(Lang.ZH to "设置", Lang.EN to "Settings"),
        "shared.skip" to mapOf(Lang.ZH to "跳过", Lang.EN to "Skip"),
        "shared.ok_2" to mapOf(Lang.ZH to "确定", Lang.EN to "OK"),
        "shared.confirm" to mapOf(Lang.ZH to "确认执行", Lang.EN to "Confirm"),
        "shared.reset_memory" to mapOf(Lang.ZH to "重置记忆", Lang.EN to "Reset Memory"),
        "shared.cancel" to mapOf(Lang.ZH to "取消", Lang.EN to "Cancel"),
        "shared.e_g_move_to_tomorrow_8pm" to mapOf(Lang.ZH to "例如:改到明天晚上8点", Lang.EN to "e.g. move to tomorrow 8pm"),
        "shared.apply_changes" to mapOf(Lang.ZH to "应用修改", Lang.EN to "Apply Changes"),
        "shared.currency" to mapOf(Lang.ZH to "币种", Lang.EN to "Currency"),
        "shared.thinking_level" to mapOf(Lang.ZH to "思考强度", Lang.EN to "Thinking Level"),
        "shared.provider" to mapOf(Lang.ZH to "服务商", Lang.EN to "Provider"),
        "shared.language" to mapOf(Lang.ZH to "语言", Lang.EN to "Language"),
        "shared.independent_of_the_system_language" to mapOf(Lang.ZH to "独立于系统语言设置;AI 助手的对话内容不受影响,始终为中文。", Lang.EN to "Independent of the system language setting; AI assistant conversations are unaffected and stay in Chinese."),
        "shared.ai_edit" to mapOf(Lang.ZH to "AI 修改", Lang.EN to "AI Edit"),
        "shared.all_day" to mapOf(Lang.ZH to "全天", Lang.EN to "All day"),
        "shared.weekday" to mapOf(Lang.ZH to "周几", Lang.EN to "Weekday"),
        "shared.haptic_feedback" to mapOf(Lang.ZH to "振动反馈", Lang.EN to "Haptic Feedback"),
        "shared.reminder_times" to mapOf(Lang.ZH to "提醒时间点", Lang.EN to "Reminder times"),
        "shared.duration" to mapOf(Lang.ZH to "时长", Lang.EN to "Duration"),
        "shared.repeat" to mapOf(Lang.ZH to "重复", Lang.EN to "Repeat"),
        "android_core_ai.couldn_t_parse_invalid_response_web" to mapOf(Lang.ZH to "无法解析:返回格式异常:web_search 缺少 query", Lang.EN to "Couldn't parse: invalid response, web_search is missing query"),
        "android_core_ai.couldn_t_parse_invalid_response_web_2" to mapOf(Lang.ZH to "无法解析:返回格式异常:web_fetch 缺少 url", Lang.EN to "Couldn't parse: invalid response, web_fetch is missing url"),
        "android_core_ai.couldn_t_parse_invalid_response_missing" to mapOf(Lang.ZH to "无法解析:返回格式异常:缺少 actions", Lang.EN to "Couldn't parse: invalid response, missing actions"),
        "android_core_ai.couldn_t_parse_couldn_t_find_the_task" to mapOf(Lang.ZH to "无法解析:找不到要操作的事项", Lang.EN to "Couldn't parse: couldn't find the task to act on"),
        "android_core_ai.couldn_t_parse_invalid_response_answer" to mapOf(Lang.ZH to "无法解析:返回格式异常:回答内容为空", Lang.EN to "Couldn't parse: invalid response, answer content is empty"),
        "android_core_ai.couldn_t_parse_invalid_response_unknown" to mapOf(Lang.ZH to "无法解析:返回格式异常:未知 action", Lang.EN to "Couldn't parse: invalid response, unknown action"),
        "android_core_ai.couldn_t_parse_invalid_response_missing_2" to mapOf(Lang.ZH to "无法解析:返回格式异常:缺少 memory", Lang.EN to "Couldn't parse: invalid response, missing memory"),
        "android_core_ai.couldn_t_parse_invalid_response_missing_3" to mapOf(Lang.ZH to "无法解析:返回格式异常:缺少 summary", Lang.EN to "Couldn't parse: invalid response, missing summary"),
        "android_core_ai.couldn_t_parse_invalid_response_missing_4" to mapOf(Lang.ZH to "无法解析:返回格式异常:缺少 candidates", Lang.EN to "Couldn't parse: invalid response, missing candidates"),
        "android_core_ai.couldn_t_parse_no_reschedule" to mapOf(Lang.ZH to "无法解析:没有可用的改期候选", Lang.EN to "Couldn't parse: no reschedule suggestions available"),
        "android_core_ai.couldn_t_parse_invalid_response_missing_5" to mapOf(Lang.ZH to "无法解析:返回格式异常:缺少 insight", Lang.EN to "Couldn't parse: invalid response, missing insight"),
        "android_core_ai.couldn_t_parse_invalid_response_format" to mapOf(Lang.ZH to "无法解析:返回格式异常", Lang.EN to "Couldn't parse: invalid response format"),
        "android_core_ai.deepseek_request_failed_invalid" to mapOf(Lang.ZH to "调用 DeepSeek 失败:无效的服务地址,请到「设置」里检查 AI 服务商配置。", Lang.EN to "DeepSeek request failed: invalid endpoint. Check your AI provider settings."),
        "android_core_ai.couldn_t_parse_invalid_response" to mapOf(Lang.ZH to "无法解析:返回格式异常:时长超出范围", Lang.EN to "Couldn't parse: invalid response, duration out of range"),
        "android_core_ai.couldn_t_parse_invalid_response_weekday" to mapOf(Lang.ZH to "无法解析:返回格式异常:周几超出范围", Lang.EN to "Couldn't parse: invalid response, weekday out of range"),
        "android_core_ai.couldn_t_parse_invalid_response_unknown_2" to mapOf(Lang.ZH to "无法解析:返回格式异常:未知工具 ", Lang.EN to "Couldn't parse: invalid response, unknown tool "),
        "android_core_ai.couldn_t_parse_invalid_time_format" to mapOf(Lang.ZH to "无法解析:时间点格式异常:", Lang.EN to "Couldn't parse: invalid time format: "),
        "android_core_ai.deepseek_request_failed" to mapOf(Lang.ZH to "调用 DeepSeek 失败:", Lang.EN to "DeepSeek request failed: "),
        "android_core_ai.deepseek_api_key_not_configured_set_it" to mapOf(Lang.ZH to "未配置 DeepSeek API key,请到「设置」里填写。", Lang.EN to "DeepSeek API key not configured. Set it up in Settings."),
        "android_core_ai.deepseek_request_failed_invalid_2" to mapOf(Lang.ZH to "调用 DeepSeek 失败:无效的服务地址,请到「设置」里检查 AI 服务商配置。", Lang.EN to "DeepSeek request failed: invalid endpoint. Check your AI provider settings."),
        "android_core_ai.invalid_link" to mapOf(Lang.ZH to "无效链接:", Lang.EN to "Invalid link: "),
        "android_core_ai.failed_to_fetch_link_http" to mapOf(Lang.ZH to "抓取链接失败:HTTP ", Lang.EN to "Failed to fetch link: HTTP "),
        "android_core_ai.web_search_failed_invalid_response" to mapOf(Lang.ZH to "联网搜索失败:返回格式异常", Lang.EN to "Web search failed: invalid response format"),
        "android_core_ai.web_search_failed" to mapOf(Lang.ZH to "联网搜索失败:", Lang.EN to "Web search failed: "),
        "android_core_ai.couldn_t_parse" to mapOf(Lang.ZH to "无法解析:", Lang.EN to "Couldn't parse: "),
        "android_core_ai.today" to mapOf(Lang.ZH to "今天", Lang.EN to "Today"),
        "android_core_ai.tomorrow" to mapOf(Lang.ZH to "明天", Lang.EN to "Tomorrow"),
        "android_core_ai.yesterday" to mapOf(Lang.ZH to "昨天", Lang.EN to "Yesterday"),
        "android_core_ai.daily" to mapOf(Lang.ZH to "每天", Lang.EN to "Daily"),
        "android_core_ai.weekly" to mapOf(Lang.ZH to "每周", Lang.EN to "Weekly "),
        "android_notif.due_reminders" to mapOf(Lang.ZH to "到期提醒", Lang.EN to "Due Reminders"),
        "android_notif.nagging_reminders_for_due_tasks" to mapOf(Lang.ZH to "事项到期的纠缠式提醒", Lang.EN to "Nagging reminders for due tasks"),
        "android_notif.daily_todo_digest" to mapOf(Lang.ZH to "每日待办汇总", Lang.EN to "Daily Todo Digest"),
        "android_notif.time_s_up_please_take_care_of_it" to mapOf(Lang.ZH to "到时间了,请处理。", Lang.EN to "Time's up, please take care of it."),
        "android_notif.time_to_start_set_aside_d_minutes" to mapOf(Lang.ZH to "该开始了,请预留 %d 分钟。", Lang.EN to "Time to start—set aside %d minutes."),
        "android_notif.time_s_up_please_confirm_it_s_done" to mapOf(Lang.ZH to "时间已到,请确认完成情况。", Lang.EN to "Time's up—please confirm it's done."),
        "android_notif.time_s_up_don_t_forget" to mapOf(Lang.ZH to "到时间啦,别忘了哦~", Lang.EN to "Time's up, don't forget~"),
        "android_notif.time_to_start_about_d_minutes_you_ve" to mapOf(Lang.ZH to "要开始啦~大概需要 %d 分钟,加油!", Lang.EN to "Time to start~ about %d minutes, you've got this!"),
        "android_notif.time_s_up_all_done" to mapOf(Lang.ZH to "时间到啦,完成了吗?", Lang.EN to "Time's up, all done?"),
        "android_notif.time_s_up_go_now" to mapOf(Lang.ZH to "时间到了,马上行动!", Lang.EN to "Time's up, go now!"),
        "android_notif.time_to_start_give_yourself_d_minutes" to mapOf(Lang.ZH to "该开始了!给自己 %d 分钟,专注去做。", Lang.EN to "Time to start! Give yourself %d minutes and focus."),
        "android_notif.time_s_up_is_it_done" to mapOf(Lang.ZH to "时间到,完成了没有?", Lang.EN to "Time's up, is it done?"),
        "android_notif.ding_your_reminder_is_here" to mapOf(Lang.ZH to "叮!你的专属提醒到啦~", Lang.EN to "Ding! Your reminder is here~"),
        "android_notif.go_time_about_d_minutes_let_s_go" to mapOf(Lang.ZH to "开工时间到~预计 %d 分钟,冲鸭!", Lang.EN to "Go time~ about %d minutes, let's go!"),
        "android_notif.time_s_up_all_set_no_slacking" to mapOf(Lang.ZH to "时间到啦,搞定了没?别偷懒哦~", Lang.EN to "Time's up, all set? No slacking~"),
        "android_notif.time_to_start" to mapOf(Lang.ZH to "该开始了!(时长 ", Lang.EN to "Time to start! ("),
        "android_notif.time_s_up_is_it_done_2" to mapOf(Lang.ZH to "时间到 — 完成了吗?", Lang.EN to "Time's up — is it done?"),
        "android_notif.time_s_up" to mapOf(Lang.ZH to "到时间了", Lang.EN to "Time's up"),
        "android_notif.no_tasks_today" to mapOf(Lang.ZH to "今日暂无待办事项 🎉", Lang.EN to "No tasks today 🎉"),
        "android_notif.done" to mapOf(Lang.ZH to "完成", Lang.EN to "Done"),
        "android_notif.snooze" to mapOf(Lang.ZH to "稍等一会", Lang.EN to "Snooze"),
    )

    fun of(key: String, lang: Lang): String =
        table[key]?.get(lang) ?: table[key]?.get(Lang.ZH) ?: key

    /** 反向查找:给一段中文原文(可能带动态后缀),找最长匹配的已知前缀并
     * 把那一段替换成英文,后缀(工具名/HTTP 码等技术细节)保留原样不翻译。
     * 用于 DeepSeekException 这类把中文文案直接构造进异常消息的场景——
     * 没有对应表项时原样返回,不报错、不崩溃。 */
    private val zhToEn: List<Pair<String, String>> by lazy {
        table.values.mapNotNull { pair ->
            val zh = pair[Lang.ZH]; val en = pair[Lang.EN]
            if (zh != null && en != null) zh to en else null
        }.sortedByDescending { it.first.length }
    }

    fun translate(zh: String, lang: Lang): String {
        if (lang != Lang.EN) return zh
        zhToEn.firstOrNull { it.first == zh }?.let { return it.second }
        zhToEn.firstOrNull { zh.startsWith(it.first) }?.let { (zhPrefix, enPrefix) ->
            return enPrefix + zh.substring(zhPrefix.length)
        }
        return zh
    }
}
