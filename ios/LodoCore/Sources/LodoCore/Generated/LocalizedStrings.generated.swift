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
    case ios_core_qwen_asr_api_key_not_configured_set
    case ios_core_qwen_asr_request_failed
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
    case ios_core_weekly_caption_prefix
    case ios_core_next_occurrence
    case ios_core_no_time_set
    case ios_core_start_task_hint
    case ios_core_contact_exported_count
    case ios_core_contact_export_skipped_count
    case ios_core_contact_export_failed_count
    case ios_core_routine_requires_weekday
    case ios_core_routine_next_unavailable
    case ios_core_routine_next_caption
    case ios_core_action_create
    case ios_core_action_update
    case ios_core_action_complete
    case ios_core_action_delete
    case ios_core_action_save
    case ios_core_action_query_memory
    case ios_core_action_answer
    case ios_core_action_suggest_save
    case ios_core_action_remember_preference
    case ios_core_action_auto_record
    case ios_core_action_plan_trip
    case ios_core_action_edit_trip
    case ios_core_action_countdown
    case ios_core_unknown_task
    case ios_core_intent_task_added
    case ios_core_action_missing_count
    case ios_core_completed_at
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
    case ios_notif_ignore
    case shared_white
    case shared_pink
    case shared_green
    case shared_brown
    case shared_blue
    case shared_black
    case shared_daily
    case shared_weekly
    case ios_core_health_steps
    case ios_core_health_active_energy
    case ios_core_health_exercise_minutes
    case ios_core_health_sleep
    case ios_core_health_resting_heart_rate
    case ios_core_health_hrv
    case ios_core_health_body_mass
    case ios_core_health_unit_steps
    case ios_core_health_unit_kcal
    case ios_core_health_unit_minutes
    case ios_core_health_unit_hours
    case ios_core_health_unit_bpm
    case ios_core_health_unit_ms
    case ios_core_health_unit_kg
    case ios_core_invalid_response_read_health_is_missing
    case ios_core_invalid_response_missing_analysis
    case ios_core_health_trend_chart_suffix
    case ios_core_travel_flight
    case ios_core_travel_train
    case ios_core_travel_coach
    case ios_core_travel_lodging
    case ios_core_travel_place
    case ios_core_invalid_response_read_trip_is_missing
    case ios_core_invalid_response_missing_items
    case ios_core_flight_status_scheduled
    case ios_core_flight_status_check_in
    case ios_core_flight_status_boarding
    case ios_core_flight_status_gate_closed
    case ios_core_flight_status_departed
    case ios_core_flight_status_delayed
    case ios_core_flight_status_arrived
    case ios_core_flight_status_canceled
    case ios_core_flight_status_diverted
    case ios_core_menu_untitled
    case ios_core_menu_dish_count
    case ios_core_menu_no_text
    case ios_core_menu_no_dishes
    case ios_core_task_in_progress
    case ios_core_duration_field
    case ios_core_duration_none
    case ios_core_relative_started
    case ios_core_relative_minutes
    case ios_core_relative_hours
    case ios_core_relative_hours_minutes
    case ios_core_relative_days
    case ios_core_memory_kind_text
    case ios_core_memory_kind_link
    case ios_core_memory_kind_pdf
    case ios_core_memory_kind_image
    case ios_core_memory_kind_file
    case ios_core_skill_agent_title
    case ios_core_skill_todo_title
    case ios_core_skill_memory_title
    case ios_core_skill_web_search_title
    case ios_core_skill_health_title
    case ios_core_skill_travel_title
    case ios_core_skill_trip_planner_title
    case ios_core_skill_news_title
    case ios_core_skill_countdown_title
    case ios_core_skill_asset_ledger_title
    case ios_core_skill_feeds_title
    case ios_core_skill_assets_title
    case ios_core_skill_duration_title
    case ios_core_skill_routine_web_title
    case ios_core_skill_agent_subtitle
    case ios_core_skill_todo_subtitle
    case ios_core_skill_memory_subtitle
    case ios_core_skill_web_search_subtitle
    case ios_core_skill_health_subtitle
    case ios_core_skill_travel_subtitle
    case ios_core_skill_trip_planner_subtitle
    case ios_core_skill_news_subtitle
    case ios_core_skill_countdown_subtitle
    case ios_core_skill_asset_ledger_subtitle
    case ios_core_skill_feeds_subtitle
    case ios_core_skill_assets_subtitle
    case ios_core_skill_duration_subtitle
    case ios_core_skill_routine_web_subtitle
    case ios_core_skill_group_system
    case ios_core_skill_group_memory
    case ios_core_skill_group_travel
    case ios_core_skill_group_health
    case ios_core_skill_group_news
    case ios_core_skill_group_routine
    case ios_core_skill_group_custom
    case ios_core_skill_error_missing_frontmatter
    case ios_core_skill_error_missing_name
    case ios_core_skill_error_missing_description
    case ios_core_skill_error_empty_body
    case ios_core_skill_error_name_too_long
    case ios_core_skill_error_description_too_long
    case ios_core_skill_error_body_too_long
    case ios_core_zip_invalid
    case ios_core_zip_unsupported_method
    case ios_core_zip_decompression_failed
    case ios_core_feed_not_rss
    case ios_core_feed_parse_failed
    case ios_core_news_invalid_url
    case ios_core_news_already_subscribed
    case ios_core_news_feed_not_found
    case ios_core_exchange_rate_failed
    case ios_core_embedding_unavailable
    case ios_core_embedding_failed
    case ios_core_reminders_repeat_note
    case ios_core_task_fields_required
    case ios_core_travel_screenshot_text_missing
    case ios_core_travel_import_items_missing
    case ios_core_news_no_recent_articles
    case ios_core_backup_import_success
    case ios_core_backup_import_summary
    case ios_core_skill_file_not_utf8
    case ios_core_skill_duplicate_name
    case ios_core_agent_memory_cancelled
    case ios_core_agent_memory_saved
    case ios_core_agent_memory_auto_saved
    case ios_core_agent_task_created
    case ios_core_agent_task_updated
    case ios_core_agent_operation_cancelled
    case ios_core_agent_question_cancelled
    case ios_core_agent_operations_completed
    case ios_core_feed_subscription_failed
    case ios_core_processing
    case ios_core_thinking_busy
    case ios_core_thinking_reviewing
    case ios_core_thinking_slacking
    case ios_core_thinking_overtime
    case ios_core_thinking_reasoning
    case ios_core_thinking_reflecting
    case ios_core_thinking_pondering
    case ios_core_thinking_guessing
    case ios_core_thinking_planning
    case ios_core_thinking_working_hard
    case ios_core_thinking_meeting
    case ios_core_speech_permission_denied
    case ios_core_microphone_permission_denied
    case ios_core_speech_unavailable
    case ios_core_recording_start_failed
    case ios_core_recording_file_unreadable
    case ios_core_backup_invalid_file
    case ios_core_reminders_permission_failed
    case ios_core_reminders_export_failed
    case ios_notif_routine_open_reminder
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
        .shared_todo: [.zhHans: "任务", .en: "Task"],
        .shared_done: [.zhHans: "已完成", .en: "Done"],
        .shared_endpoint_chat_completions: [.zhHans: "接口地址(…/chat/completions)", .en: "Endpoint (…/chat/completions)"],
        .shared_describe_the_ai_s_tone_e_g_like_a_wuxia: [.zhHans: "描述 AI 的说话风格,例如:像武侠小说里的师父", .en: "Describe the AI's tone, e.g. like a wuxia master"],
        .shared_reminders: [.zhHans: "提醒", .en: "Reminders"],
        .shared_undo: [.zhHans: "撤销", .en: "Undo"],
        .shared_reschedule: [.zhHans: "改期", .en: "Reschedule"],
        .shared_no_tasks_yet: [.zhHans: "暂无任务", .en: "No tasks yet"],
        .shared_no_memory_yet_the_ai_fills_this_in: [.zhHans: "暂无记忆;AI 会在事项完成后自动归纳,也可以直接在这里手写。", .en: "No memory yet; the AI fills this in automatically after tasks are completed, or you can write it yourself."],
        .shared_upcoming: [.zhHans: "未来任务", .en: "Upcoming"],
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
        .ios_core_qwen_asr_api_key_not_configured_set: [.zhHans: "未配置 Qwen 语音识别 API key,请到「设置」里填写。", .en: "Qwen speech recognition API key not configured. Set it up in Settings."],
        .ios_core_qwen_asr_request_failed: [.zhHans: "调用 Qwen 语音识别失败:", .en: "Qwen speech recognition request failed: "],
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
        .ios_core_weekly_caption_prefix: [.zhHans: "每周", .en: "Every"],
        .ios_core_next_occurrence: [.zhHans: "下次", .en: "Next"],
        .ios_core_no_time_set: [.zhHans: "未设置时间", .en: "No time set"],
        .ios_core_start_task_hint: [.zhHans: "该开始了!", .en: "Time to start!"],
        .ios_core_contact_exported_count: [.zhHans: "已导出 %lld 位", .en: "Exported %lld contacts"],
        .ios_core_contact_export_skipped_count: [.zhHans: "跳过 %lld 位重复", .en: "Skipped %lld duplicates"],
        .ios_core_contact_export_failed_count: [.zhHans: "%lld 位失败", .en: "%lld failed"],
        .ios_core_routine_requires_weekday: [.zhHans: "至少选一天", .en: "Select at least one day"],
        .ios_core_routine_next_unavailable: [.zhHans: "当前设置算不出下一次触发时间。", .en: "Can't calculate the next run with the current settings."],
        .ios_core_routine_next_caption: [.zhHans: "下一次:%@。一天可以设多个时间点。", .en: "Next: %@. You can add multiple times per day."],
        .ios_core_action_create: [.zhHans: "新建:%@(%@)", .en: "Create: %@ (%@)"],
        .ios_core_action_update: [.zhHans: "修改:%@(%@)", .en: "Update: %@ (%@)"],
        .ios_core_action_complete: [.zhHans: "完成:%@", .en: "Complete: %@"],
        .ios_core_action_delete: [.zhHans: "删除:%@", .en: "Delete: %@"],
        .ios_core_action_save: [.zhHans: "收藏:%@", .en: "Save: %@"],
        .ios_core_action_query_memory: [.zhHans: "查询记忆", .en: "Search memories"],
        .ios_core_action_answer: [.zhHans: "回答问题", .en: "Answer the question"],
        .ios_core_action_suggest_save: [.zhHans: "建议收藏:%@", .en: "Suggest saving: %@"],
        .ios_core_action_remember_preference: [.zhHans: "记住偏好:%@", .en: "Remember preference: %@"],
        .ios_core_action_auto_record: [.zhHans: "自动记录:%@", .en: "Auto-record: %@"],
        .ios_core_action_plan_trip: [.zhHans: "规划行程:%@", .en: "Plan trip: %@"],
        .ios_core_action_edit_trip: [.zhHans: "调整行程:%@", .en: "Update trip: %@"],
        .ios_core_action_countdown: [.zhHans: "倒数日:%@", .en: "Countdown: %@"],
        .ios_core_unknown_task: [.zhHans: "未知事项", .en: "Unknown task"],
        .ios_core_intent_task_added: [.zhHans: "已添加:%@,%@", .en: "Added: %@, %@"],
        .ios_core_action_missing_count: [.zhHans: "有 %lld 项操作未执行:对应事项已不存在", .en: "%lld operations were skipped because the tasks no longer exist"],
        .ios_core_completed_at: [.zhHans: "已于 %@ 完成", .en: "Completed on %@"],
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
        .ios_notif_daily_todo_digest: [.zhHans: "每日任务汇总", .en: "Daily Task Digest"],
        .ios_notif_no_tasks_today: [.zhHans: "今日暂无任务 🎉", .en: "No tasks today 🎉"],
        .ios_notif_done: [.zhHans: "完成", .en: "Done"],
        .ios_notif_snooze: [.zhHans: "稍等一会", .en: "Snooze"],
        .ios_notif_reschedule: [.zhHans: "改期", .en: "Reschedule"],
        .ios_notif_ignore: [.zhHans: "忽略", .en: "Ignore"],
        .shared_white: [.zhHans: "白色", .en: "White"],
        .shared_pink: [.zhHans: "粉色", .en: "Pink"],
        .shared_green: [.zhHans: "绿色", .en: "Green"],
        .shared_brown: [.zhHans: "棕色", .en: "Brown"],
        .shared_blue: [.zhHans: "蓝色", .en: "Blue"],
        .shared_black: [.zhHans: "黑色", .en: "Black"],
        .shared_daily: [.zhHans: "每天", .en: "Daily"],
        .shared_weekly: [.zhHans: "每周", .en: "Weekly"],
        .ios_core_health_steps: [.zhHans: "步数", .en: "Steps"],
        .ios_core_health_active_energy: [.zhHans: "活动能量", .en: "Active Energy"],
        .ios_core_health_exercise_minutes: [.zhHans: "锻炼时长", .en: "Exercise Time"],
        .ios_core_health_sleep: [.zhHans: "睡眠时长", .en: "Sleep"],
        .ios_core_health_resting_heart_rate: [.zhHans: "静息心率", .en: "Resting Heart Rate"],
        .ios_core_health_hrv: [.zhHans: "心率变异性", .en: "Heart Rate Variability"],
        .ios_core_health_body_mass: [.zhHans: "体重", .en: "Body Mass"],
        .ios_core_health_unit_steps: [.zhHans: "步", .en: "steps"],
        .ios_core_health_unit_kcal: [.zhHans: "千卡", .en: "kcal"],
        .ios_core_health_unit_minutes: [.zhHans: "分钟", .en: "min"],
        .ios_core_health_unit_hours: [.zhHans: "小时", .en: "h"],
        .ios_core_health_unit_bpm: [.zhHans: "次/分", .en: "bpm"],
        .ios_core_health_unit_ms: [.zhHans: "毫秒", .en: "ms"],
        .ios_core_health_unit_kg: [.zhHans: "公斤", .en: "kg"],
        .ios_core_invalid_response_read_health_is_missing: [.zhHans: "返回格式异常:read_health 缺少 days", .en: "Invalid response: read_health is missing days"],
        .ios_core_invalid_response_missing_analysis: [.zhHans: "返回格式异常:缺少 analysis", .en: "Invalid response: missing analysis"],
        .ios_core_health_trend_chart_suffix: [.zhHans: "趋势图", .en: " trend chart"],
        .ios_core_travel_flight: [.zhHans: "航班", .en: "Flight"],
        .ios_core_travel_train: [.zhHans: "火车", .en: "Train"],
        .ios_core_travel_coach: [.zhHans: "客车", .en: "Coach"],
        .ios_core_travel_lodging: [.zhHans: "住宿", .en: "Lodging"],
        .ios_core_travel_place: [.zhHans: "地点", .en: "Place"],
        .ios_core_invalid_response_read_trip_is_missing: [.zhHans: "返回格式异常:read_trip 缺少 name", .en: "Invalid response: read_trip is missing name"],
        .ios_core_invalid_response_missing_items: [.zhHans: "返回格式异常:缺少 items", .en: "Invalid response: missing items"],
        .ios_core_flight_status_scheduled: [.zhHans: "计划中", .en: "Scheduled"],
        .ios_core_flight_status_check_in: [.zhHans: "值机中", .en: "Check-in open"],
        .ios_core_flight_status_boarding: [.zhHans: "登机中", .en: "Boarding"],
        .ios_core_flight_status_gate_closed: [.zhHans: "登机口已关闭", .en: "Gate closed"],
        .ios_core_flight_status_departed: [.zhHans: "已起飞", .en: "Departed"],
        .ios_core_flight_status_delayed: [.zhHans: "延误", .en: "Delayed"],
        .ios_core_flight_status_arrived: [.zhHans: "已到达", .en: "Arrived"],
        .ios_core_flight_status_canceled: [.zhHans: "已取消", .en: "Canceled"],
        .ios_core_flight_status_diverted: [.zhHans: "备降", .en: "Diverted"],
        .ios_core_menu_untitled: [.zhHans: "未命名菜单", .en: "Untitled Menu"],
        .ios_core_menu_dish_count: [.zhHans: "{0} 道菜", .en: "{0} dishes"],
        .ios_core_menu_no_text: [.zhHans: "没从图片里认出文字。换一张更清楚、正对着菜单拍的照片试试,或者直接贴文字。", .en: "Couldn't read any text from the photos. Try a sharper photo taken straight on, or paste the text instead."],
        .ios_core_menu_no_dishes: [.zhHans: "没从这份菜单里读出菜品。换一张更完整的照片或文字再试试。", .en: "Couldn't find any dishes on this menu. Try a fuller photo or text."],
        .ios_core_task_in_progress: [.zhHans: "进行中", .en: "In progress"],
        .ios_core_duration_field: [.zhHans: "时长:%@", .en: "Duration: %@"],
        .ios_core_duration_none: [.zhHans: "无", .en: "None"],
        .ios_core_relative_started: [.zhHans: "已开始", .en: "Started"],
        .ios_core_relative_minutes: [.zhHans: "%lld 分钟后", .en: "in %lld min"],
        .ios_core_relative_hours: [.zhHans: "%lld 小时后", .en: "in %lld hr"],
        .ios_core_relative_hours_minutes: [.zhHans: "%lld 小时 %lld 分钟后", .en: "in %lld hr %lld min"],
        .ios_core_relative_days: [.zhHans: "%lld 天后", .en: "in %lld days"],
        .ios_core_memory_kind_text: [.zhHans: "文字", .en: "Text"],
        .ios_core_memory_kind_link: [.zhHans: "链接", .en: "Link"],
        .ios_core_memory_kind_pdf: [.zhHans: "PDF", .en: "PDF"],
        .ios_core_memory_kind_image: [.zhHans: "图片", .en: "Image"],
        .ios_core_memory_kind_file: [.zhHans: "文件", .en: "File"],
        .ios_core_skill_agent_title: [.zhHans: "总则(agent.md)", .en: "General rules (agent.md)"],
        .ios_core_skill_todo_title: [.zhHans: "构建待办", .en: "Task management"],
        .ios_core_skill_memory_title: [.zhHans: "记忆", .en: "Memory"],
        .ios_core_skill_web_search_title: [.zhHans: "联网搜索", .en: "Web search"],
        .ios_core_skill_health_title: [.zhHans: "健康", .en: "Health"],
        .ios_core_skill_travel_title: [.zhHans: "旅行", .en: "Travel"],
        .ios_core_skill_trip_planner_title: [.zhHans: "规划行程", .en: "Trip planning"],
        .ios_core_skill_news_title: [.zhHans: "新闻", .en: "News"],
        .ios_core_skill_countdown_title: [.zhHans: "倒数日", .en: "Countdown"],
        .ios_core_skill_asset_ledger_title: [.zhHans: "资产台账", .en: "Asset Ledger"],
        .ios_core_skill_feeds_title: [.zhHans: "订阅管理", .en: "Subscriptions"],
        .ios_core_skill_assets_title: [.zhHans: "资产与负债", .en: "Assets and liabilities"],
        .ios_core_skill_duration_title: [.zhHans: "时长建议", .en: "Duration suggestions"],
        .ios_core_skill_routine_web_title: [.zhHans: "定时任务联网", .en: "Web search for routines"],
        .ios_core_skill_agent_subtitle: [.zhHans: "AI 入口的角色设定与通用判断规则", .en: "AI assistant role and general decision rules"],
        .ios_core_skill_todo_subtitle: [.zhHans: "新建/修改事项的字段格式与时间换算规则", .en: "Task creation and editing fields and time conversion rules"],
        .ios_core_skill_memory_subtitle: [.zhHans: "收藏与查记忆的判定规则(仅记忆功能开启时生效)", .en: "Rules for saving and searching memories (only active when Memory is enabled)"],
        .ios_core_skill_web_search_subtitle: [.zhHans: "查最新信息/回答一般问题的判定规则(仅配置 Tavily key 后生效)", .en: "Rules for current information and general questions (requires a Tavily key)"],
        .ios_core_skill_health_subtitle: [.zhHans: "读健康数据回答身体状况问题的判定规则(仅开启健康分析后生效)", .en: "Rules for answering health questions from data (requires Health Analysis)"],
        .ios_core_skill_travel_subtitle: [.zhHans: "读行程回答问题、按天调整已记下的行程(仅记录过旅行后生效)", .en: "Read trips and adjust plans by day (requires a saved trip)"],
        .ios_core_skill_trip_planner_subtitle: [.zhHans: "按目的地、天数和偏好自动排行程,确认后写进「旅行」", .en: "Plan a trip from the destination, duration, and your preferences; add it to Travel after you confirm."],
        .ios_core_skill_news_subtitle: [.zhHans: "在订阅的新闻与博客里找文章、回答最近发生了什么(仅有订阅后生效)", .en: "Search subscribed news and blogs for articles and recent events (requires subscriptions)"],
        .ios_core_skill_countdown_subtitle: [.zhHans: "新建、修改、删除倒数日与它们的提醒", .en: "Create, edit and delete countdowns and their reminders"],
        .ios_core_skill_asset_ledger_subtitle: [.zhHans: "在「资产」页新增、更新资产与负债(房产、存款、投资、贷款…)", .en: "Add and update assets and liabilities on the Assets page (property, savings, investments, loans…)"],
        .ios_core_skill_feeds_subtitle: [.zhHans: "订阅新闻与博客(贴链接、一次多个、只说名字也行),改名、停用", .en: "Subscribe to news and blogs (paste links, several at once, or just a name), rename or pause"],
        .ios_core_skill_assets_subtitle: [.zhHans: "收藏时识别资产金额、币种、负债与利率的规则", .en: "Rules for recognizing asset values, currencies, liabilities, and interest rates when saving"],
        .ios_core_skill_duration_subtitle: [.zhHans: "没说时长时,按时长记忆给新事项建议时长(停用则不再建议)", .en: "Suggest task durations from duration memory when none is specified (disabled means no suggestions)"],
        .ios_core_skill_routine_web_subtitle: [.zhHans: "定时任务需要最新信息时的联网工具说明(仅配置 Tavily key 后生效)", .en: "Web search for routines that need current information (requires a Tavily key)"],
        .ios_core_skill_group_system: [.zhHans: "系统 skills", .en: "System skills"],
        .ios_core_skill_group_memory: [.zhHans: "记忆 skills", .en: "Memory skills"],
        .ios_core_skill_group_travel: [.zhHans: "旅行 skills", .en: "Travel skills"],
        .ios_core_skill_group_health: [.zhHans: "健康 skills", .en: "Health skills"],
        .ios_core_skill_group_news: [.zhHans: "新闻 skills", .en: "News skills"],
        .ios_core_skill_group_routine: [.zhHans: "定时任务 skills", .en: "Routine skills"],
        .ios_core_skill_group_custom: [.zhHans: "我的 skills", .en: "My skills"],
        .ios_core_skill_error_missing_frontmatter: [.zhHans: "文件开头缺少 --- 包起来的头信息(name/description)", .en: "The file is missing a front matter block (name/description) at the beginning."],
        .ios_core_skill_error_missing_name: [.zhHans: "头信息里缺少 name", .en: "The front matter is missing a name."],
        .ios_core_skill_error_missing_description: [.zhHans: "头信息里缺少 description", .en: "The front matter is missing a description."],
        .ios_core_skill_error_empty_body: [.zhHans: "正文是空的", .en: "The body is empty."],
        .ios_core_skill_error_name_too_long: [.zhHans: "name 不能超过 %lld 个字", .en: "The name can't exceed %lld characters."],
        .ios_core_skill_error_description_too_long: [.zhHans: "description 不能超过 %lld 个字", .en: "The description can't exceed %lld characters."],
        .ios_core_skill_error_body_too_long: [.zhHans: "正文不能超过 %lld 个字", .en: "The body can't exceed %lld characters."],
        .ios_core_zip_invalid: [.zhHans: "不是有效的 zip 文件", .en: "This isn't a valid ZIP file."],
        .ios_core_zip_unsupported_method: [.zhHans: "zip 里有不支持的压缩方式", .en: "This ZIP uses an unsupported compression method."],
        .ios_core_zip_decompression_failed: [.zhHans: "zip 内容解压失败", .en: "Couldn't decompress the ZIP contents."],
        .ios_core_feed_not_rss: [.zhHans: "这不是 RSS/Atom 订阅地址", .en: "This isn't an RSS or Atom feed URL."],
        .ios_core_feed_parse_failed: [.zhHans: "订阅内容解析失败:", .en: "Couldn't parse the feed:"],
        .ios_core_news_invalid_url: [.zhHans: "请输入一个有效的网址。", .en: "Enter a valid URL."],
        .ios_core_news_already_subscribed: [.zhHans: "已经订阅过「%@」了", .en: "You already subscribe to %@."],
        .ios_core_news_feed_not_found: [.zhHans: "这个网址里没找到 RSS/Atom 订阅地址。可以试试直接填博客的 feed 地址(常见的是 /feed、/rss.xml、/atom.xml)。", .en: "Couldn't find an RSS or Atom feed at this URL. Try entering the blog's feed URL directly (often /feed, /rss.xml, or /atom.xml)."],
        .ios_core_exchange_rate_failed: [.zhHans: "获取汇率失败:", .en: "Couldn't retrieve exchange rates:"],
        .ios_core_embedding_unavailable: [.zhHans: "语义检索不可用", .en: "Semantic search is unavailable."],
        .ios_core_embedding_failed: [.zhHans: "语义检索请求失败:", .en: "Semantic search failed:"],
        .ios_core_reminders_repeat_note: [.zhHans: "lodo 重复事项:%@(系统侧仅显示下一次)", .en: "lodo recurring task: %@ (only the next occurrence is shown in Reminders)"],
        .ios_core_task_fields_required: [.zhHans: "请补全事项内容和时间设置", .en: "Enter a task name and set its time."],
        .ios_core_travel_screenshot_text_missing: [.zhHans: "没从截图里认出文字。换一张更清晰的截图,或者直接把文字贴进来。", .en: "Couldn't read text from the screenshot. Try a clearer image or paste the text directly."],
        .ios_core_travel_import_items_missing: [.zhHans: "没从这段文字里读出行程项。换一段更完整的订单内容试试,或者直接手动添加。", .en: "Couldn't find any trip items in this text. Try a more complete booking or add items manually."],
        .ios_core_news_no_recent_articles: [.zhHans: "最近 24 小时订阅里没有新文章。", .en: "There are no new articles from your subscriptions in the last 24 hours."],
        .ios_core_backup_import_success: [.zhHans: "任务、记忆与 AI 对话已导入;如果设置项有变化(如 iCloud 同步),需要退出并重新打开 App 才能生效。", .en: "Tasks, memories, and AI conversations were imported. Restart the app for imported settings such as iCloud sync to take effect."],
        .ios_core_backup_import_summary: [.zhHans: "导出于 %@ · %lld 条任务 · %lld 条记忆 · %lld 条对话消息", .en: "Exported %@ · %lld tasks · %lld memories · %lld chat messages"],
        .ios_core_skill_file_not_utf8: [.zhHans: "读不出文件内容(需要 UTF-8 文本)", .en: "Couldn't read the file. It must be UTF-8 text."],
        .ios_core_skill_duplicate_name: [.zhHans: "已经有同名的 skill 了", .en: "A skill with this name already exists."],
        .ios_core_agent_memory_cancelled: [.zhHans: "已取消收藏。", .en: "Removed from saved memories."],
        .ios_core_agent_memory_saved: [.zhHans: "已收藏", .en: "Saved"],
        .ios_core_agent_memory_auto_saved: [.zhHans: "已自动记录", .en: "Recorded automatically"],
        .ios_core_agent_task_created: [.zhHans: "已新建", .en: "Created"],
        .ios_core_agent_task_updated: [.zhHans: "已修改", .en: "Updated"],
        .ios_core_agent_operation_cancelled: [.zhHans: "已取消这次操作。", .en: "This action was cancelled."],
        .ios_core_agent_question_cancelled: [.zhHans: "已取消这次提问。", .en: "This question was cancelled."],
        .ios_core_agent_operations_completed: [.zhHans: "已完成执行", .en: "Actions completed"],
        .ios_core_feed_subscription_failed: [.zhHans: "「%@」订阅失败:%@", .en: "Couldn't subscribe to %@: %@"],
        .ios_core_processing: [.zhHans: "处理中…", .en: "Working…"],
        .ios_core_thinking_busy: [.zhHans: "作业中…", .en: "Working…"],
        .ios_core_thinking_reviewing: [.zhHans: "批示中…", .en: "Reviewing…"],
        .ios_core_thinking_slacking: [.zhHans: "摸鱼中…", .en: "Taking a break…"],
        .ios_core_thinking_overtime: [.zhHans: "996中…", .en: "Working overtime…"],
        .ios_core_thinking_reasoning: [.zhHans: "思考中…", .en: "Thinking…"],
        .ios_core_thinking_reflecting: [.zhHans: "感悟中…", .en: "Reflecting…"],
        .ios_core_thinking_pondering: [.zhHans: "琢磨中…", .en: "Pondering…"],
        .ios_core_thinking_guessing: [.zhHans: "掐指一算…", .en: "Calculating…"],
        .ios_core_thinking_planning: [.zhHans: "盘算中…", .en: "Planning…"],
        .ios_core_thinking_working_hard: [.zhHans: "打工中…", .en: "On the clock…"],
        .ios_core_thinking_meeting: [.zhHans: "开会中…", .en: "In a meeting…"],
        .ios_core_speech_permission_denied: [.zhHans: "语音识别未授权,请到系统设置中开启。", .en: "Speech recognition isn't authorized. Enable it in System Settings."],
        .ios_core_microphone_permission_denied: [.zhHans: "麦克风未授权,请到系统设置中开启。", .en: "Microphone access isn't authorized. Enable it in System Settings."],
        .ios_core_speech_unavailable: [.zhHans: "语音识别暂不可用。", .en: "Speech recognition is currently unavailable."],
        .ios_core_recording_start_failed: [.zhHans: "无法启动录音:", .en: "Couldn't start recording:"],
        .ios_core_recording_file_unreadable: [.zhHans: "无法读取录音文件。", .en: "Couldn't read the recording file."],
        .ios_core_backup_invalid_file: [.zhHans: "无法识别这份备份文件", .en: "This backup file isn't recognized."],
        .ios_core_reminders_permission_failed: [.zhHans: "请求权限失败:", .en: "Permission request failed:"],
        .ios_core_reminders_export_failed: [.zhHans: "导出失败:", .en: "Export failed:"],
        .ios_notif_routine_open_reminder: [.zhHans: "到时间了,打开看看今天的内容。", .en: "It's time. Open the app to see today's content."],
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
