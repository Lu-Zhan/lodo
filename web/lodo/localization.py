"""UI strings for the Streamlit demo. Generated from i18n/strings.csv."""
from __future__ import annotations


ENGLISH = {
    '设置': 'Settings',
    '稍等间隔(分钟)': 'Snooze interval (minutes)',
    '稍等或忽略提醒后,多久再次提醒': 'How long to wait before reminding again after snoozing or ignoring',
    '反复提醒': 'Repeat reminders',
    '到期后每隔一个稍等间隔重复提醒,直到完成。关掉则只提醒一次(事项仍然显示为逾期,你主动点「稍等」也照样有效)': 'Repeat reminders at each snooze interval until completed. Turn off to remind once. Overdue tasks remain visible, and you can still snooze them manually.',
    '全天事项提醒时间': 'All-day reminder time',
    '只有日期、没有时间的事项,当天几点提醒': 'Time of day to remind for tasks with a date but no specific time',
    '每日待办汇总': 'Daily task summary',
    '汇总提醒时间': 'Summary reminder time',
    '免打扰时段': 'Quiet hours',
    '时段内到期事项照样显示为到期,只是不弹通知,时段结束后补发': 'Due tasks remain visible during quiet hours, but notifications are held until quiet hours end',
    '开始': 'Start',
    '结束': 'End',
    '语言 / Language': 'Language',
    '事项内容': 'Task',
    '不重复': 'Never',
    '每天': 'Every day',
    '每周': 'Every week',
    '重复': 'Repeat',
    '日期': 'Date',
    '全天': 'All day',
    '只有日期,当天 {time} 提醒': 'Date only; remind at {time}',
    '时间': 'Time',
    '周几': 'Weekdays',
    '提醒时间点(可多个,可直接输入如 08:30)': 'Reminder times (select multiple or enter a time, e.g. 08:30)',
    '时间点格式应为 HH:MM,如 08:30': 'Enter times in HH:MM format, e.g. 08:30',
    '时长(分钟,0 表示无时长)': 'Duration (minutes; 0 means no duration)',
    '分钟': 'min',
    '进行中': 'In progress',
    '自然语言创建': 'Create from natural language',
    '例如:今天9点提醒我给妈妈打电话 / 每天9点和21点提醒吃药 / 每周一三五8点健身': 'Try: remind me to call Mom today at 9 / remind me to take medicine every day at 9 and 21 / exercise every Mon, Wed, Fri at 8',
    '✨ 解析': '✨ Parse',
    'DeepSeek 解析中…': 'DeepSeek is parsing…',
    '解析结果,确认后创建:': 'Parsed task. Confirm to create:',
    '✅ 创建': '✅ Create',
    '创建': 'Create',
    '请补全事项内容和时间设置': 'Complete the task details and time settings',
    '请补全事项内容和时间设置(重复事项需选周几和时间点)': 'Complete the task details and time settings. Recurring tasks need weekdays and reminder times.',
    '取消': 'Cancel',
    '✍️ 手动创建': '✍️ Create manually',
    '今天 {time}': 'Today at {time}',
    '明天 {time}': 'Tomorrow at {time}',
    '该开始了': "It's time to start",
    '到时间了': "It's time",
    '该开始了!': 'Time to start!',
    '时间到 — 完成了吗?': "Time's up — are you done?",
    '▶️ 开始了': '▶️ Started',
    '✅ 完成': '✅ Complete',
    '✅ 已完成,下次提醒 {time}': '✅ Completed. Next reminder: {time}',
    '⏳ 稍等 {minutes} 分钟': '⏳ Snooze {minutes} min',
    '🙈 忽略': '🙈 Ignore',
    '和稍等不同:间隔逐次翻倍,直到稍等/完成/改期才重置': 'Unlike snoozing, the interval doubles after each ignore. It resets when you snooze, complete, or reschedule.',
    '📋 每日待办汇总({date})': '📋 Daily task summary ({date})',
    '🎉 今日事项全部完成!': '🎉 All tasks completed today!',
    '知道了': 'Got it',
    '📌 待办 ({count})': '📌 To do ({count})',
    '✅ 已完成': '✅ Completed',
    '暂无待办事项': 'No tasks yet',
    '编辑': 'Edit',
    '标记完成': 'Mark complete',
    '删除': 'Delete',
    'AI 修改': 'Edit with AI',
    '例如:改到明天晚上8点': 'Try: move it to 8 PM tomorrow',
    '✨ 应用': '✨ Apply',
    'DeepSeek 修改中…': 'DeepSeek is editing…',
    '💾 保存': '💾 Save',
    '还没有完成的事项': 'No completed tasks yet',
    '完成于 {time}': 'Completed {time}',
    '未配置 DEEPSEEK_API_KEY,请在 web/.env 中填写,或使用手动创建。': 'DEEPSEEK_API_KEY is not configured. Add it to web/.env or create the task manually.',
    '调用 DeepSeek 失败:': 'DeepSeek request failed:',
    '无法解析:': 'Could not parse:',
    'DeepSeek 返回格式异常:': 'DeepSeek returned an invalid response:',
}


def localize(value: str, language: str) -> str:
    """Translate visible Chinese UI text and preserve dynamic values."""
    if language != "English":
        return value
    exact = ENGLISH.get(value)
    if exact is not None:
        return exact
    for source, translated in ENGLISH.items():
        if source.endswith(":") and value.startswith(source):
            return translated + value[len(source):]
    return value
