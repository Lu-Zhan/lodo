"""lodo — 提醒事项 Web 演示版 (Streamlit)。"""
from __future__ import annotations

import re
from datetime import date, datetime, time as dtime, timedelta
from typing import Optional

import streamlit as st

from lodo import scheduler
from lodo.ai import AIParseError, edit_task, parse_task
from lodo.db import Database
from lodo.localization import localize
from lodo.models import WEEKDAY_NAMES, Phase, RepeatType, Status, Task
from lodo.settings import load_settings, mark_digest_shown, save_settings

st.set_page_config(page_title="lodo", page_icon="⏰", layout="centered")


@st.cache_resource
def get_db() -> Database:
    return Database()


db = get_db()

if "active_reminders" not in st.session_state:
    st.session_state.active_reminders = set()   # 正在等待响应的事项 id
if "digest_date" not in st.session_state:
    st.session_state.digest_date = None          # 今日汇总卡片(值为日期字符串)
if "pending_parse" not in st.session_state:
    st.session_state.pending_parse = None        # AI 解析结果,等待确认创建
if "editing_id" not in st.session_state:
    st.session_state.editing_id = None           # 正在编辑的事项 id
if "edit_defaults" not in st.session_state:
    st.session_state.edit_defaults = {}          # 编辑面板控件的初始值
if "edit_ver" not in st.session_state:
    st.session_state.edit_ver = 0                # 递增使编辑控件重建,AI 修改后生效
if "ui_language" not in st.session_state:
    st.session_state.ui_language = "中文"
if "_previous_ui_language" not in st.session_state:
    st.session_state["_previous_ui_language"] = st.session_state.ui_language


def fmt(dt: datetime) -> str:
    language = st.session_state.get("ui_language", "中文")
    today = date.today()
    if language == "English":
        clock = dt.strftime("%I:%M %p").lstrip("0")
        if dt.date() == today:
            return f"Today at {clock}"
        if dt.date() == today + timedelta(days=1):
            return f"Tomorrow at {clock}"
        return f"{dt:%b %d, %Y} at {clock}"
    if dt.date() == today:
        return f"今天 {dt:%H:%M}"
    if dt.date() == today + timedelta(days=1):
        return f"明天 {dt:%H:%M}"
    return f"{dt:%m-%d %H:%M}"


def t(value: str) -> str:
    return localize(value, st.session_state.get("ui_language", "中文"))


def argument_if_unset(key: str, value: object, name: str = "value") -> dict:
    return {name: value} if key not in st.session_state else {}


def repeat_label(task: Task) -> str:
    if not task.is_recurring:
        return ""
    times = "/".join(task.repeat_times)
    if st.session_state.get("ui_language", "中文") != "English":
        return task.repeat_label()
    if task.repeat_type == RepeatType.DAILY:
        return f"Every day · {times}"
    weekdays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    days = ", ".join(weekdays[index] for index in sorted(task.repeat_days))
    return f"Every {days} · {times}"


def norm_time(s: str) -> Optional[str]:
    """把用户输入的时间点归一化为 "HH:MM",无效返回 None。"""
    m = re.fullmatch(r"(\d{1,2})[::](\d{2})", s.strip())
    if not m:
        return None
    hour, minute = int(m.group(1)), int(m.group(2))
    if hour > 23 or minute > 59:
        return None
    return f"{hour:02d}:{minute:02d}"


REPEAT_OPTIONS = {"不重复": RepeatType.NONE, "每天": RepeatType.DAILY, "每周": RepeatType.WEEKLY}
TIME_OPTIONS = [f"{h:02d}:00" for h in range(6, 24)]


def sync_language_widgets() -> None:
    """Carry current repeat and weekday selections across translated labels."""
    previous = st.session_state.get("_previous_ui_language", "中文")
    current = st.session_state.ui_language
    if previous == current:
        return
    previous_repeats = {localize(label, previous): repeat.value for label, repeat in REPEAT_OPTIONS.items()}
    current_repeats = {repeat.value: localize(label, current) for label, repeat in REPEAT_OPTIONS.items()}
    previous_weekdays = (
        WEEKDAY_NAMES if previous != "English"
        else ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    )
    current_weekdays = (
        WEEKDAY_NAMES if current != "English"
        else ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    )
    for key, value in list(st.session_state.items()):
        if key.endswith(f"_repeat_{previous}") and value in previous_repeats:
            prefix = key[: -len(f"_repeat_{previous}")]
            st.session_state[f"{prefix}_repeat_{current}"] = current_repeats[previous_repeats[value]]
        elif key.endswith(f"_days_{previous}") and isinstance(value, (list, tuple)):
            prefix = key[: -len(f"_days_{previous}")]
            st.session_state[f"{prefix}_days_{current}"] = [
                current_weekdays[previous_weekdays.index(day)]
                for day in value if day in previous_weekdays
            ]
    st.session_state["_previous_ui_language"] = current


def task_to_defaults(task: Task) -> dict:
    """把 Task 转成 task_fields / ai.edit_task 使用的字段 dict。"""
    return {
        "title": task.title,
        "remind_at": task.remind_at,
        "all_day": task.all_day,
        "duration_minutes": task.duration_minutes,
        "repeat_type": task.repeat_type.value,
        "repeat_days": task.repeat_days,
        "repeat_times": task.repeat_times,
    }


def task_fields(key: str, d: dict) -> Optional[Task]:
    """渲染事项编辑控件(手动创建 / AI 解析确认共用),返回按当前输入构造的 Task。

    输入不完整时返回 None(调用方在提交时提示)。d 提供各控件初始值。
    """
    language = st.session_state.get("ui_language", "中文")
    title = st.text_input(t("事项内容"), value=d.get("title", ""), key=f"{key}_title")
    repeat_choices = {t(label): repeat for label, repeat in REPEAT_OPTIONS.items()}
    repeat_labels = list(repeat_choices)
    default_repeat = next(
        (label for label, r in repeat_choices.items() if r.value == d.get("repeat_type", "none")),
        t("不重复"),
    )
    repeat_key = f"{key}_repeat_{language}"
    repeat_label = st.segmented_control(
        t("重复"), repeat_labels, key=repeat_key,
        **argument_if_unset(repeat_key, default_repeat, "default"),
    ) or t("不重复")
    repeat = repeat_choices[repeat_label]

    settings = load_settings(db)
    all_day = False
    repeat_days: list[int] = []
    times: list[str] = []
    remind_at: Optional[datetime] = None

    if repeat == RepeatType.NONE:
        c1, c2, c3 = st.columns([2, 2, 1], vertical_alignment="bottom")
        remind_d = c1.date_input(
            t("日期"), value=d.get("remind_at", datetime.now()).date(), key=f"{key}_date",
        )
        all_day = c3.toggle(t("全天"), value=d.get("all_day", False), key=f"{key}_allday",
                            help=t("只有日期,当天 {time} 提醒").format(time=settings.all_day_time))
        if all_day:
            hour, minute = map(int, settings.all_day_time.split(":"))
            remind_at = datetime.combine(remind_d, dtime(hour, minute))
        else:
            default_t = d.get("remind_at") or (datetime.now() + timedelta(minutes=5))
            remind_t = c2.time_input(t("时间"), value=default_t.time(), key=f"{key}_time", step=300)
            remind_at = datetime.combine(remind_d, remind_t)
    else:
        if repeat == RepeatType.WEEKLY:
            weekday_options = (
                WEEKDAY_NAMES if language != "English"
                else ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            )
            default_days = [weekday_options[i] for i in d.get("repeat_days", [])]
            days_key = f"{key}_days_{language}"
            picked = st.pills(
                t("周几"), weekday_options, selection_mode="multi",
                key=days_key, **argument_if_unset(days_key, default_days, "default"),
            )
            repeat_days = sorted(weekday_options.index(p) for p in picked)
        raw_times = st.multiselect(
            t("提醒时间点(可多个,可直接输入如 08:30)"),
            options=sorted(set(TIME_OPTIONS + d.get("repeat_times", []))),
            default=d.get("repeat_times", []),
            accept_new_options=True,
            key=f"{key}_times",
        )
        normed = [norm_time(t) for t in raw_times]
        if any(n is None for n in normed):
            st.warning(t("时间点格式应为 HH:MM,如 08:30"))
            return None
        times = sorted(set(normed))

    duration = st.number_input(
        t("时长(分钟,0 表示无时长)"), min_value=0,
        value=d.get("duration_minutes", 0), key=f"{key}_dur",
    )

    if not title.strip():
        return None
    task = Task(
        id=None, title=title.strip(),
        remind_at=remind_at or datetime.now(),
        duration_minutes=int(duration),
        all_day=all_day,
        repeat_type=repeat,
        repeat_days=repeat_days,
        repeat_times=times,
        # ignore_streak 不传,新建/编辑保存(含"改期")都用默认值 0——
        # 显式改时间等同于用户已经处理过,忽略间隔理应重置。
    )
    if task.is_recurring:
        first = scheduler.next_occurrence(task, datetime.now())
        if first is None:
            return None  # 缺周几或时间点
        task.remind_at = first
        task.next_remind_at = first
    return task


# ---------------- 侧边栏:设置 ----------------

settings = load_settings(db)

with st.sidebar:
    st.selectbox(t("语言 / Language"), ["中文", "English"], key="ui_language",
                 on_change=sync_language_widgets)
    st.header(f"⚙️ {t('设置')}")
    snooze = st.number_input(
        t("稍等间隔(分钟)"), min_value=1, max_value=240,
        help=t("稍等或忽略提醒后,多久再次提醒"), key="settings_snooze_interval",
        **argument_if_unset("settings_snooze_interval", settings.snooze_minutes),
    )
    repeat_on = st.toggle(
        t("反复提醒"),
        help=t("到期后每隔一个稍等间隔重复提醒,直到完成。关掉则只提醒一次"
               "(事项仍然显示为逾期,你主动点「稍等」也照样有效)"),
        key="settings_repeat_reminder",
        **argument_if_unset("settings_repeat_reminder", settings.repeat_reminder),
    )
    ad_h, ad_m = map(int, settings.all_day_time.split(":"))
    all_day_key = "settings_all_day_time"
    all_day_t = st.time_input(t("全天事项提醒时间"), step=300,
                              help=t("只有日期、没有时间的事项,当天几点提醒"),
                              key=all_day_key,
                              **argument_if_unset(all_day_key, dtime(ad_h, ad_m)))
    digest_on = st.toggle(t("每日待办汇总"), key="settings_daily_digest",
                          **argument_if_unset("settings_daily_digest", settings.daily_digest_time is not None))
    digest_time_val = None
    if digest_on:
        default_t = (
            dtime.fromisoformat(settings.daily_digest_time)
            if settings.daily_digest_time else dtime(21, 0)
        )
        digest_key = "settings_digest_time"
        digest_time_val = st.time_input(t("汇总提醒时间"), step=300, key=digest_key,
                                        **argument_if_unset(digest_key, default_t))

    quiet_on = st.toggle(t("免打扰时段"),
                         help=t("时段内到期事项照样显示为到期,只是不弹通知,时段结束后补发"),
                         key="settings_quiet_hours",
                         **argument_if_unset("settings_quiet_hours", settings.quiet_hours_enabled))
    qh_s, qh_e = map(int, settings.quiet_hours_start.split(":"))
    qe_h, qe_m = map(int, settings.quiet_hours_end.split(":"))
    q_col1, q_col2 = st.columns(2)
    quiet_start_val = q_col1.time_input(
        t("开始"), step=300, key="quiet_start", disabled=not quiet_on,
        **argument_if_unset("quiet_start", dtime(qh_s, qh_e)),
    )
    quiet_end_val = q_col2.time_input(
        t("结束"), step=300, key="quiet_end", disabled=not quiet_on,
        **argument_if_unset("quiet_end", dtime(qe_h, qe_m)),
    )

    new_digest = digest_time_val.strftime("%H:%M") if digest_time_val else None
    new_all_day = all_day_t.strftime("%H:%M")
    new_quiet_start = quiet_start_val.strftime("%H:%M")
    new_quiet_end = quiet_end_val.strftime("%H:%M")
    if (
        snooze != settings.snooze_minutes
        or repeat_on != settings.repeat_reminder
        or new_digest != settings.daily_digest_time
        or new_all_day != settings.all_day_time
        or quiet_on != settings.quiet_hours_enabled
        or new_quiet_start != settings.quiet_hours_start
        or new_quiet_end != settings.quiet_hours_end
    ):
        settings.snooze_minutes = int(snooze)
        settings.repeat_reminder = repeat_on
        settings.daily_digest_time = new_digest
        settings.all_day_time = new_all_day
        settings.quiet_hours_enabled = quiet_on
        settings.quiet_hours_start = new_quiet_start
        settings.quiet_hours_end = new_quiet_end
        save_settings(db, settings)

st.title("⏰ lodo")

# ---------------- 创建事项 ----------------

nl_col, btn_col = st.columns([5, 1], vertical_alignment="bottom")
nl_text = nl_col.text_input(
    t("自然语言创建"),
    placeholder=t("例如:今天9点提醒我给妈妈打电话 / 每天9点和21点提醒吃药 / 每周一三五8点健身"),
    key="natural_language_task",
)
if btn_col.button(t("✨ 解析"), width="stretch") and nl_text.strip():
    try:
        with st.spinner(t("DeepSeek 解析中…")):
            st.session_state.pending_parse = parse_task(nl_text.strip())
    except AIParseError as exc:
        st.session_state.pending_parse = None
        st.error(t(str(exc)))

if st.session_state.pending_parse:
    with st.container(border=True):
        st.markdown(f"**{t('解析结果,确认后创建:')}**")
        task = task_fields("p", st.session_state.pending_parse)
        ok_col, cancel_col = st.columns(2)
        if ok_col.button(t("✅ 创建"), type="primary", width="stretch"):
            if task is None:
                st.warning(t("请补全事项内容和时间设置"))
            else:
                db.add_task(task)
                st.session_state.pending_parse = None
                st.rerun()
        if cancel_col.button(t("取消"), width="stretch"):
            st.session_state.pending_parse = None
            st.rerun()

with st.expander(t("✍️ 手动创建")):
    task = task_fields("m", {})
    if st.button(t("创建"), type="primary", key="m_submit"):
        if task is None:
            st.warning(t("请补全事项内容和时间设置(重复事项需选周几和时间点)"))
        else:
            db.add_task(task)
            st.rerun()


# ---------------- 轮询 + 提醒 + 列表(每 10 秒自动刷新) ----------------

def task_caption(task: Task) -> str:
    parts = [fmt(task.next_remind_at)]
    if task.is_recurring:
        parts.append(repeat_label(task))
    elif task.all_day:
        parts.append(t("全天"))
    if task.duration_minutes:
        parts.append(f"{task.duration_minutes} {t('分钟')}")
    if task.phase == Phase.END:
        parts.append(t("进行中"))
    return " · ".join(parts)


@st.fragment(run_every="10s")
def reminder_and_lists() -> None:
    now = datetime.now()
    settings = load_settings(db)
    pending = db.pending_tasks()

    # 到期检查:弹出提醒并自动顺延(忽略也会在间隔后再次提醒)
    for task in scheduler.due_tasks(pending, now):
        # 关掉「反复提醒」时 mark_notified 不顺延 next_remind_at,事项会一直
        # 停在到期状态;这里靠 last_notified_at 去重,免得每次轮询都再弹一次。
        # 这个判断对开着的情况同样成立(顺延之后 last < next),不用分支。
        if task.last_notified_at is not None and task.last_notified_at >= task.next_remind_at:
            continue
        scheduler.mark_notified(task, now, settings.snooze_minutes,
                                repeat_enabled=settings.repeat_reminder)
        db.update_task(task)
        st.session_state.active_reminders.add(task.id)
        verb = t("该开始了") if task.phase == Phase.START and task.duration_minutes > 0 else t("到时间了")
        st.toast(f"⏰ {task.title} — {verb}", icon="⏰")

    # 每日汇总到点
    if scheduler.should_show_digest(settings, now):
        today = now.strftime("%Y-%m-%d")
        mark_digest_shown(db, today)
        st.session_state.digest_date = today

    # 清理已不存在/已完成的提醒卡片
    pending = db.pending_tasks()
    pending_ids = {t.id for t in pending}
    st.session_state.active_reminders &= pending_ids

    # ---- 提醒卡片 ----
    active = [t for t in pending if t.id in st.session_state.active_reminders]
    for task in active:
        with st.container(border=True):
            starting = task.phase == Phase.START and task.duration_minutes > 0
            st.markdown(f"### 🔔 {task.title}")
            if starting:
                st.caption(f"{task_caption(task)} — {t('该开始了!')}")
                done_label = t("▶️ 开始了")
            elif task.phase == Phase.END:
                st.caption(t("时间到 — 完成了吗?"))
                done_label = t("✅ 完成")
            else:
                st.caption(task_caption(task))
                done_label = t("✅ 完成")
            c1, c2, c3 = st.columns(3)
            if c1.button(done_label, key=f"done_{task.id}", type="primary", width="stretch"):
                finished = scheduler.advance(task, datetime.now())
                db.update_task(task)
                st.session_state.active_reminders.discard(task.id)
                if finished and task.status == Status.PENDING:
                    # 重复事项完成一次:记入历史,并提示下次时间
                    db.add_task(Task(
                        id=None, title=task.title, remind_at=task.remind_at,
                        status=Status.DONE, done_at=datetime.now(),
                    ))
                    st.toast(t("✅ 已完成,下次提醒 {time}").format(time=fmt(task.next_remind_at)))
                st.rerun(scope="fragment")
            if c2.button(t("⏳ 稍等 {minutes} 分钟").format(minutes=settings.snooze_minutes),
                         key=f"snooze_{task.id}", width="stretch"):
                scheduler.snooze(task, datetime.now(), settings.snooze_minutes)
                db.update_task(task)
                st.session_state.active_reminders.discard(task.id)
                st.rerun(scope="fragment")
            if c3.button(t("🙈 忽略"), key=f"ignore_{task.id}", width="stretch",
                        help=t("和稍等不同:间隔逐次翻倍,直到稍等/完成/改期才重置")):
                scheduler.ignore(task, datetime.now(), settings.snooze_minutes)
                db.update_task(task)
                st.session_state.active_reminders.discard(task.id)
                st.rerun(scope="fragment")

    # ---- 每日汇总卡片 ----
    if st.session_state.digest_date:
        with st.container(border=True):
            st.markdown(f"### {t('📋 每日待办汇总({date})').format(date=st.session_state.digest_date)}")
            if pending:
                for summary_task in pending:
                    st.markdown(f"- **{summary_task.title}** — {task_caption(summary_task)}")
            else:
                st.markdown(t("🎉 今日事项全部完成!"))
            if st.button(t("知道了"), key="digest_dismiss"):
                st.session_state.digest_date = None
                st.rerun(scope="fragment")

    # ---- 列表 ----
    tab_todo, tab_done = st.tabs([t("📌 待办 ({count})").format(count=len(pending)), t("✅ 已完成")])
    with tab_todo:
        if not pending:
            st.caption(t("暂无待办事项"))
        for task in pending:
            c1, c2, c3, c4 = st.columns([6, 1, 1, 1], vertical_alignment="center")
            c1.markdown(f"**{task.title}**  \n:gray[{task_caption(task)}]")
            if c2.button("✏️", key=f"list_edit_{task.id}", help=t("编辑")):
                if st.session_state.editing_id == task.id:
                    st.session_state.editing_id = None
                else:
                    st.session_state.editing_id = task.id
                    st.session_state.edit_defaults = task_to_defaults(task)
                    st.session_state.edit_ver += 1
                st.rerun(scope="fragment")
            if c3.button("✓", key=f"list_done_{task.id}", help=t("标记完成")):
                task.ignore_streak = 0
                nxt = scheduler.next_occurrence(task, datetime.now())
                if nxt is not None:
                    db.add_task(Task(
                        id=None, title=task.title, remind_at=task.remind_at,
                        status=Status.DONE, done_at=datetime.now(),
                    ))
                    task.phase = Phase.START
                    task.remind_at = nxt
                    task.next_remind_at = nxt
                else:
                    task.status = Status.DONE
                    task.done_at = datetime.now()
                db.update_task(task)
                st.rerun(scope="fragment")
            if c4.button("🗑", key=f"list_del_{task.id}", help=t("删除")):
                db.delete_task(task.id)
                st.rerun(scope="fragment")

            # ---- 编辑面板(手动 + AI 指令) ----
            if st.session_state.editing_id == task.id:
                with st.container(border=True):
                    edited = task_fields(
                        f"e{task.id}v{st.session_state.edit_ver}",
                        st.session_state.edit_defaults,
                    )
                    ai_c1, ai_c2 = st.columns([5, 1], vertical_alignment="bottom")
                    instr = ai_c1.text_input(
                        t("AI 修改"),
                        placeholder=t("例如:改到明天晚上8点"),
                        key=f"ai_instr_{task.id}",
                    )
                    if ai_c2.button(t("✨ 应用"), key=f"ai_apply_{task.id}", width="stretch") and instr.strip():
                        current = task_to_defaults(edited) if edited else st.session_state.edit_defaults
                        try:
                            with st.spinner(t("DeepSeek 修改中…")):
                                st.session_state.edit_defaults = edit_task(current, instr.strip())
                            st.session_state.edit_ver += 1
                            st.rerun(scope="fragment")
                        except AIParseError as exc:
                            st.error(t(str(exc)))
                    s_col, x_col = st.columns(2)
                    if s_col.button(t("💾 保存"), type="primary", key=f"save_{task.id}", width="stretch"):
                        if edited is None:
                            st.warning(t("请补全事项内容和时间设置(重复事项需选周几和时间点)"))
                        else:
                            edited.id = task.id
                            db.update_task(edited)
                            st.session_state.editing_id = None
                            st.session_state.active_reminders.discard(task.id)
                            st.rerun(scope="fragment")
                    if x_col.button(t("取消"), key=f"cancel_{task.id}", width="stretch"):
                        st.session_state.editing_id = None
                        st.rerun(scope="fragment")
    with tab_done:
        done = db.done_tasks()
        if not done:
            st.caption(t("还没有完成的事项"))
        for task in done:
            st.markdown(f"~~{task.title}~~ :gray[{t('完成于 {time}').format(time=fmt(task.done_at))}]")


reminder_and_lists()
