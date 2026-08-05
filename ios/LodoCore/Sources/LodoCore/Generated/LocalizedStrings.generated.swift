// 由 i18n/generate.py 从 i18n/strings.csv 生成,不要手改。
// 改动请回到 strings.csv 修订后重新运行脚本。


import Foundation


/// 生成表的 key;供 LodoCore 内非 View 上下文(错误文案、通知模板、
/// repeatLabel 等)显式查表用,不经过 SwiftUI 的 .environment(\.locale)。
public enum LK: String, CaseIterable {
    case shared_mon
    case shared_tue
    case shared_wed
    case shared_thu
    case shared_fri
    case shared_sat
    case shared_sun
    case shared_efficient_secretary
    case shared_gentle_companion
    case shared_strict_coach
    case shared_playful_witty
    case shared_like_a_sharp_executive_assistant
    case shared_warm_and_caring_like_a_friend_who_looks
    case shared_like_a_disciplined_coach_direct_and
    case shared_light_and_funny_a_bit_playful_makes
    case shared_default
    case shared_custom
    case shared_tongyi_qianwen
    case shared_zhipu
    case shared_chinese_yuan
    case shared_us_dollar
    case shared_euro
    case shared_japanese_yen
    case shared_british_pound
    case shared_hong_kong_dollar
    case shared_south_korean_won
    case shared_australian_dollar
    case shared_canadian_dollar
    case shared_singapore_dollar
    case shared_swiss_franc
    case shared_thai_baht
    case shared_ai_personality
    case shared_ai_assistant
    case shared_ai_thinking
    case shared_ai_service
    case shared_ai_memory
    case shared_task_content
    case shared_ok
    case shared_todo
    case shared_done
    case shared_endpoint_chat_completions
    case shared_describe_the_ai_s_tone_e_g_like_a_wuxia
    case shared_reminders
    case shared_undo
    case shared_reschedule
    case shared_no_tasks_yet
    case shared_no_memory_yet_the_ai_fills_this_in
    case shared_upcoming
    case shared_this_week_s_insight
    case shared_add
    case shared_add_a_time
    case shared_web_search
    case shared_settings
    case shared_skip
    case shared_ok_2
    case shared_confirm
    case shared_reset_memory
    case shared_cancel
    case shared_e_g_move_to_tomorrow_8pm
    case shared_apply_changes
    case shared_currency
    case shared_thinking_level
    case shared_provider
    case ios_core_model_default
    case shared_language
    case shared_independent_of_the_system_language
    case shared_ai_edit
    case shared_all_day
    case shared_weekday
    case shared_haptic_feedback
    case shared_reminder_times
    case shared_duration
    case shared_repeat
    case ios_core_deepseek_api_key_not_configured_set_it
    case ios_core_deepseek_request_failed
    case ios_core_couldn_t_parse
    case ios_core_invalid_response_search_memory_is
    case ios_core_invalid_response_web_search_is_missing
    case ios_core_invalid_response_web_fetch_is_missing
    case ios_core_invalid_response_unknown_tool
    case ios_core_invalid_response_missing_actions
    case ios_core_couldn_t_find_the_task_to_act_on
    case ios_core_invalid_response_saved_content_is_empty
    case ios_core_invalid_response_suggested_content_is
    case ios_core_invalid_response_preference_content_is
    case ios_core_invalid_response_question_is_empty
    case ios_core_invalid_response_answer_is_empty
    case ios_core_invalid_response_unknown_action
    case ios_core_invalid_response_ask_has_no_usable
    case ios_core_invalid_response_missing_candidates
    case ios_core_no_reschedule_suggestions_available
    case ios_core_invalid_response_missing_insight
    case ios_core_invalid_response_missing_suggestion
    case ios_core_invalid_response_missing_summary
    case ios_core_invalid_response_missing_text
    case ios_core_invalid_response_missing_title
    case ios_core_invalid_response_missing_answer
    case ios_core_invalid_response_missing_memory
    case ios_core_invalid_response_missing_preferences
    case ios_core_invalid_response_format
    case ios_core_invalid_endpoint_check_your_ai_provider
    case ios_core_invalid_response_title_is_empty
    case ios_core_invalid_time_format
    case ios_core_invalid_response_duration_out_of_range
    case ios_core_invalid_response_weekday_out_of_range
    case ios_core_tavily_api_key_not_configured_set_it_up
    case ios_core_web_search_failed
    case ios_core_apple_intelligence_available_no_key
    case ios_core_this_device_doesn_t_support_apple
    case ios_core_turn_on_apple_intelligence_in_settings
    case ios_core_the_apple_intelligence_model_is_getting
    case ios_core_apple_intelligence_is_currently
    case ios_core_no_weekday_selected
    case ios_notif_time_s_up_please_take_care_of_it
    case ios_notif_time_to_start_set_aside_d_minutes
    case ios_notif_time_s_up_please_confirm_it_s_done
    case ios_notif_time_s_up_don_t_forget
    case ios_notif_time_to_start_about_d_minutes_you_ve
    case ios_notif_time_s_up_all_done
    case ios_notif_time_s_up_go_now
    case ios_notif_time_to_start_give_yourself_d_minutes
    case ios_notif_time_s_up_is_it_done
    case ios_notif_ding_your_reminder_is_here
    case ios_notif_go_time_about_d_minutes_let_s_go
    case ios_notif_time_s_up_all_set_no_slacking
    case ios_notif_time_to_start
    case ios_notif_time_s_up_is_it_done_2
    case ios_notif_time_s_up
    case ios_notif_daily_todo_digest
    case ios_notif_no_tasks_today
    case ios_notif_done
    case ios_notif_snooze
    case ios_notif_reschedule
}

public enum LocalizedStrings {
    private static let table: [LK: [AppLanguage: String]] = [
        .shared_mon: [.zhHans: "周一", .en: "Mon"],
        .shared_tue: [.zhHans: "周二", .en: "Tue"],
        .shared_wed: [.zhHans: "周三", .en: "Wed"],
        .shared_thu: [.zhHans: "周四", .en: "Thu"],
        .shared_fri: [.zhHans: "周五", .en: "Fri"],
        .shared_sat: [.zhHans: "周六", .en: "Sat"],
        .shared_sun: [.zhHans: "周日", .en: "Sun"],
        .shared_efficient_secretary: [.zhHans: "高效秘书", .en: "Efficient Secretary"],
        .shared_gentle_companion: [.zhHans: "温柔陪伴", .en: "Gentle Companion"],
        .shared_strict_coach: [.zhHans: "严格教练", .en: "Strict Coach"],
        .shared_playful_witty: [.zhHans: "幽默轻松", .en: "Playful & Witty"],
        .shared_like_a_sharp_executive_assistant: [.zhHans: "像一位干练的行政秘书:简洁、专业、直接,不说废话。", .en: "Like a sharp executive assistant: concise, professional, and direct—no fluff."],
        .shared_warm_and_caring_like_a_friend_who_looks: [.zhHans: "语气温柔体贴,像关心你的朋友,多一点鼓励。", .en: "Warm and caring, like a friend who looks out for you—extra encouraging."],
        .shared_like_a_disciplined_coach_direct_and: [.zhHans: "像自律教练:直接有推动力,催促按时完成,语气可以严厉但保持尊重。", .en: "Like a disciplined coach: direct and motivating, pushes you to finish on time, can be firm but stays respectful."],
        .shared_light_and_funny_a_bit_playful_makes: [.zhHans: "轻松幽默,偶尔调皮,让提醒不那么无聊。", .en: "Light and funny, a bit playful—makes reminders less boring."],
        .shared_default: [.zhHans: "默认", .en: "Default"],
        .shared_custom: [.zhHans: "自定义", .en: "Custom"],
        .shared_tongyi_qianwen: [.zhHans: "通义千问", .en: "Tongyi Qianwen"],
        .shared_zhipu: [.zhHans: "智谱", .en: "Zhipu"],
        .shared_chinese_yuan: [.zhHans: "人民币", .en: "Chinese Yuan"],
        .shared_us_dollar: [.zhHans: "美元", .en: "US Dollar"],
        .shared_euro: [.zhHans: "欧元", .en: "Euro"],
        .shared_japanese_yen: [.zhHans: "日元", .en: "Japanese Yen"],
        .shared_british_pound: [.zhHans: "英镑", .en: "British Pound"],
        .shared_hong_kong_dollar: [.zhHans: "港币", .en: "Hong Kong Dollar"],
        .shared_south_korean_won: [.zhHans: "韩元", .en: "South Korean Won"],
        .shared_australian_dollar: [.zhHans: "澳元", .en: "Australian Dollar"],
        .shared_canadian_dollar: [.zhHans: "加元", .en: "Canadian Dollar"],
        .shared_singapore_dollar: [.zhHans: "新加坡元", .en: "Singapore Dollar"],
        .shared_swiss_franc: [.zhHans: "瑞士法郎", .en: "Swiss Franc"],
        .shared_thai_baht: [.zhHans: "泰铢", .en: "Thai Baht"],
        .shared_ai_personality: [.zhHans: "AI 个性", .en: "AI Personality"],
        .shared_ai_assistant: [.zhHans: "AI 助手", .en: "AI Assistant"],
        .shared_ai_thinking: [.zhHans: "AI 思考", .en: "AI Thinking"],
        .shared_ai_service: [.zhHans: "AI 服务", .en: "AI Service"],
        .shared_ai_memory: [.zhHans: "AI 记忆", .en: "AI Memory"],
        .shared_task_content: [.zhHans: "事项内容", .en: "Task content"],
        .shared_ok: [.zhHans: "好", .en: "OK"],
        .shared_todo: [.zhHans: "待办", .en: "Todo"],
        .shared_done: [.zhHans: "已完成", .en: "Done"],
        .shared_endpoint_chat_completions: [.zhHans: "接口地址(…/chat/completions)", .en: "Endpoint (…/chat/completions)"],
        .shared_describe_the_ai_s_tone_e_g_like_a_wuxia: [.zhHans: "描述 AI 的说话风格,例如:像武侠小说里的师父", .en: "Describe the AI's tone, e.g. like a wuxia master"],
        .shared_reminders: [.zhHans: "提醒", .en: "Reminders"],
        .shared_undo: [.zhHans: "撤销", .en: "Undo"],
        .shared_reschedule: [.zhHans: "改期", .en: "Reschedule"],
        .shared_no_tasks_yet: [.zhHans: "暂无待办事项", .en: "No tasks yet"],
        .shared_no_memory_yet_the_ai_fills_this_in: [.zhHans: "暂无记忆;AI 会在事项完成后自动归纳,也可以直接在这里手写。", .en: "No memory yet; the AI fills this in automatically after tasks are completed, or you can write it yourself."],
        .shared_upcoming: [.zhHans: "未来待办", .en: "Upcoming"],
        .shared_this_week_s_insight: [.zhHans: "本周洞察", .en: "This Week's Insight"],
        .shared_add: [.zhHans: "添加", .en: "Add"],
        .shared_add_a_time: [.zhHans: "添加时间点", .en: "Add a time"],
        .shared_web_search: [.zhHans: "联网搜索", .en: "Web Search"],
        .shared_settings: [.zhHans: "设置", .en: "Settings"],
        .shared_skip: [.zhHans: "跳过", .en: "Skip"],
        .shared_ok_2: [.zhHans: "确定", .en: "OK"],
        .shared_confirm: [.zhHans: "确认执行", .en: "Confirm"],
        .shared_reset_memory: [.zhHans: "重置记忆", .en: "Reset Memory"],
        .shared_cancel: [.zhHans: "取消", .en: "Cancel"],
        .shared_e_g_move_to_tomorrow_8pm: [.zhHans: "例如:改到明天晚上8点", .en: "e.g. move to tomorrow 8pm"],
        .shared_apply_changes: [.zhHans: "应用修改", .en: "Apply Changes"],
        .shared_currency: [.zhHans: "币种", .en: "Currency"],
        .shared_thinking_level: [.zhHans: "思考强度", .en: "Thinking Level"],
        .shared_provider: [.zhHans: "服务商", .en: "Provider"],
        .ios_core_model_default: [.zhHans: "模型(默认 ", .en: "Model (default "],
        .shared_language: [.zhHans: "语言", .en: "Language"],
        .shared_independent_of_the_system_language: [.zhHans: "独立于系统语言设置;AI 助手的对话内容不受影响,始终为中文。", .en: "Independent of the system language setting; AI assistant conversations are unaffected and stay in Chinese."],
        .shared_ai_edit: [.zhHans: "AI 修改", .en: "AI Edit"],
        .shared_all_day: [.zhHans: "全天", .en: "All day"],
        .shared_weekday: [.zhHans: "周几", .en: "Weekday"],
        .shared_haptic_feedback: [.zhHans: "振动反馈", .en: "Haptic Feedback"],
        .shared_reminder_times: [.zhHans: "提醒时间点", .en: "Reminder times"],
        .shared_duration: [.zhHans: "时长", .en: "Duration"],
        .shared_repeat: [.zhHans: "重复", .en: "Repeat"],
        .ios_core_deepseek_api_key_not_configured_set_it: [.zhHans: "未配置 DeepSeek API key,请到「设置」里填写。", .en: "DeepSeek API key not configured. Set it up in Settings."],
        .ios_core_deepseek_request_failed: [.zhHans: "调用 DeepSeek 失败:", .en: "DeepSeek request failed: "],
        .ios_core_couldn_t_parse: [.zhHans: "无法解析:", .en: "Couldn't parse: "],
        .ios_core_invalid_response_search_memory_is: [.zhHans: "返回格式异常:search_memory 缺少 query", .en: "Invalid response: search_memory is missing query"],
        .ios_core_invalid_response_web_search_is_missing: [.zhHans: "返回格式异常:web_search 缺少 query", .en: "Invalid response: web_search is missing query"],
        .ios_core_invalid_response_web_fetch_is_missing: [.zhHans: "返回格式异常:web_fetch 缺少 url", .en: "Invalid response: web_fetch is missing url"],
        .ios_core_invalid_response_unknown_tool: [.zhHans: "返回格式异常:未知工具 ", .en: "Invalid response: unknown tool "],
        .ios_core_invalid_response_missing_actions: [.zhHans: "返回格式异常:缺少 actions", .en: "Invalid response: missing actions"],
        .ios_core_couldn_t_find_the_task_to_act_on: [.zhHans: "找不到要操作的事项", .en: "Couldn't find the task to act on"],
        .ios_core_invalid_response_saved_content_is_empty: [.zhHans: "返回格式异常:收藏内容为空", .en: "Invalid response: saved content is empty"],
        .ios_core_invalid_response_suggested_content_is: [.zhHans: "返回格式异常:建议收藏内容为空", .en: "Invalid response: suggested content is empty"],
        .ios_core_invalid_response_preference_content_is: [.zhHans: "返回格式异常:偏好内容为空", .en: "Invalid response: preference content is empty"],
        .ios_core_invalid_response_question_is_empty: [.zhHans: "返回格式异常:查询问题为空", .en: "Invalid response: question is empty"],
        .ios_core_invalid_response_answer_is_empty: [.zhHans: "返回格式异常:回答内容为空", .en: "Invalid response: answer is empty"],
        .ios_core_invalid_response_unknown_action: [.zhHans: "返回格式异常:未知 action", .en: "Invalid response: unknown action"],
        .ios_core_invalid_response_ask_has_no_usable: [.zhHans: "返回格式异常:ask 缺少可用问题", .en: "Invalid response: ask has no usable question"],
        .ios_core_invalid_response_missing_candidates: [.zhHans: "返回格式异常:缺少 candidates", .en: "Invalid response: missing candidates"],
        .ios_core_no_reschedule_suggestions_available: [.zhHans: "没有可用的改期候选", .en: "No reschedule suggestions available"],
        .ios_core_invalid_response_missing_insight: [.zhHans: "返回格式异常:缺少 insight", .en: "Invalid response: missing insight"],
        .ios_core_invalid_response_missing_suggestion: [.zhHans: "返回格式异常:缺少 suggestion", .en: "Invalid response: missing suggestion"],
        .ios_core_invalid_response_missing_summary: [.zhHans: "返回格式异常:缺少 summary", .en: "Invalid response: missing summary"],
        .ios_core_invalid_response_missing_text: [.zhHans: "返回格式异常:缺少 text", .en: "Invalid response: missing text"],
        .ios_core_invalid_response_missing_title: [.zhHans: "返回格式异常:缺少 title", .en: "Invalid response: missing title"],
        .ios_core_invalid_response_missing_answer: [.zhHans: "返回格式异常:缺少 answer", .en: "Invalid response: missing answer"],
        .ios_core_invalid_response_missing_memory: [.zhHans: "返回格式异常:缺少 memory", .en: "Invalid response: missing memory"],
        .ios_core_invalid_response_missing_preferences: [.zhHans: "返回格式异常:缺少 preferences", .en: "Invalid response: missing preferences"],
        .ios_core_invalid_response_format: [.zhHans: "返回格式异常", .en: "Invalid response format"],
        .ios_core_invalid_endpoint_check_your_ai_provider: [.zhHans: "无效的服务地址,请到「设置」里检查 AI 服务商配置。", .en: "Invalid endpoint. Check your AI provider settings."],
        .ios_core_invalid_response_title_is_empty: [.zhHans: "返回格式异常:标题为空", .en: "Invalid response: title is empty"],
        .ios_core_invalid_time_format: [.zhHans: "时间点格式异常:", .en: "Invalid time format: "],
        .ios_core_invalid_response_duration_out_of_range: [.zhHans: "返回格式异常:时长超出范围", .en: "Invalid response: duration out of range"],
        .ios_core_invalid_response_weekday_out_of_range: [.zhHans: "返回格式异常:周几超出范围", .en: "Invalid response: weekday out of range"],
        .ios_core_tavily_api_key_not_configured_set_it_up: [.zhHans: "未配置 Tavily API key,请到「设置」里填写。", .en: "Tavily API key not configured. Set it up in Settings."],
        .ios_core_web_search_failed: [.zhHans: "联网搜索失败:", .en: "Web search failed: "],
        .ios_core_apple_intelligence_available_no_key: [.zhHans: "苹果智能可用:免 key、离线,数据不出设备。", .en: "Apple Intelligence available: no key needed, offline, data stays on device."],
        .ios_core_this_device_doesn_t_support_apple: [.zhHans: "此设备不支持苹果智能。", .en: "This device doesn't support Apple Intelligence."],
        .ios_core_turn_on_apple_intelligence_in_settings: [.zhHans: "请先在系统设置中开启 Apple Intelligence。", .en: "Turn on Apple Intelligence in Settings first."],
        .ios_core_the_apple_intelligence_model_is_getting: [.zhHans: "苹果智能模型准备中,请稍后再试。", .en: "The Apple Intelligence model is getting ready—try again shortly."],
        .ios_core_apple_intelligence_is_currently: [.zhHans: "苹果智能暂不可用。", .en: "Apple Intelligence is currently unavailable."],
        .ios_core_no_weekday_selected: [.zhHans: "未选择星期", .en: "No weekday selected"],
        .ios_notif_time_s_up_please_take_care_of_it: [.zhHans: "到时间了,请处理。", .en: "Time's up, please take care of it."],
        .ios_notif_time_to_start_set_aside_d_minutes: [.zhHans: "该开始了,请预留 %d 分钟。", .en: "Time to start—set aside %d minutes."],
        .ios_notif_time_s_up_please_confirm_it_s_done: [.zhHans: "时间已到,请确认完成情况。", .en: "Time's up—please confirm it's done."],
        .ios_notif_time_s_up_don_t_forget: [.zhHans: "到时间啦,别忘了哦~", .en: "Time's up, don't forget~"],
        .ios_notif_time_to_start_about_d_minutes_you_ve: [.zhHans: "要开始啦~大概需要 %d 分钟,加油!", .en: "Time to start~ about %d minutes, you've got this!"],
        .ios_notif_time_s_up_all_done: [.zhHans: "时间到啦,完成了吗?", .en: "Time's up, all done?"],
        .ios_notif_time_s_up_go_now: [.zhHans: "时间到了,马上行动!", .en: "Time's up, go now!"],
        .ios_notif_time_to_start_give_yourself_d_minutes: [.zhHans: "该开始了!给自己 %d 分钟,专注去做。", .en: "Time to start! Give yourself %d minutes and focus."],
        .ios_notif_time_s_up_is_it_done: [.zhHans: "时间到,完成了没有?", .en: "Time's up, is it done?"],
        .ios_notif_ding_your_reminder_is_here: [.zhHans: "叮!你的专属提醒到啦~", .en: "Ding! Your reminder is here~"],
        .ios_notif_go_time_about_d_minutes_let_s_go: [.zhHans: "开工时间到~预计 %d 分钟,冲鸭!", .en: "Go time~ about %d minutes, let's go!"],
        .ios_notif_time_s_up_all_set_no_slacking: [.zhHans: "时间到啦,搞定了没?别偷懒哦~", .en: "Time's up, all set? No slacking~"],
        .ios_notif_time_to_start: [.zhHans: "该开始了!(时长 ", .en: "Time to start! ("],
        .ios_notif_time_s_up_is_it_done_2: [.zhHans: "时间到 — 完成了吗?", .en: "Time's up — is it done?"],
        .ios_notif_time_s_up: [.zhHans: "到时间了", .en: "Time's up"],
        .ios_notif_daily_todo_digest: [.zhHans: "每日待办汇总", .en: "Daily Todo Digest"],
        .ios_notif_no_tasks_today: [.zhHans: "今日暂无待办事项 🎉", .en: "No tasks today 🎉"],
        .ios_notif_done: [.zhHans: "完成", .en: "Done"],
        .ios_notif_snooze: [.zhHans: "稍等一会", .en: "Snooze"],
        .ios_notif_reschedule: [.zhHans: "改期", .en: "Reschedule"],
    ]

    public static func text(_ key: LK, language: AppLanguage) -> String {
        table[key]?[language] ?? table[key]?[.zhHans] ?? key.rawValue
    }

    /// 反向查找:给一段中文原文(可能带动态后缀,如"返回格式异常:未知工具 xxx"),
    /// 找最长匹配的已知前缀并把那一段替换成英文,后缀(工具名/HTTP 码等技术细节)
    /// 保留原样不翻译。用于 DeepSeekError 这类把中文文案直接存进关联值的场景——
    /// 没有对应表项时原样返回,不报错、不崩溃。
    private static let zhToEn: [(zh: String, en: String)] = table.values.compactMap { pair in
        guard let zh = pair[.zhHans], let en = pair[.en] else { return nil }
        return (zh, en)
    }.sorted { $0.zh.count > $1.zh.count }

    public static func translate(_ zh: String, language: AppLanguage) -> String {
        guard language == .en else { return zh }
        if let exact = zhToEn.first(where: { $0.zh == zh }) { return exact.en }
        for (zhPrefix, enPrefix) in zhToEn where zh.hasPrefix(zhPrefix) {
            return enPrefix + zh.dropFirst(zhPrefix.count)
        }
        return zh
    }
}
