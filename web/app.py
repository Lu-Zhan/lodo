"""lodo — 提醒事项 Web 演示版 (Streamlit)。"""
from __future__ import annotations

import re
from datetime import date, datetime, time as dtime, timedelta
from typing import Optional

import streamlit as st

from lodo import scheduler
from lodo.ai import AIParseError, edit_task, parse_task
from lodo.db import Database
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


def fmt(dt: datetime) -> str:
    today = date.today()
    if dt.date() == today:
        return f"今天 {dt:%H:%M}"
    if dt.date() == today + timedelta(days=1):
        return f"明天 {dt:%H:%M}"
    return f"{dt:%m-%d %H:%M}"


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
    title = st.text_input("事项内容", value=d.get("title", ""), key=f"{key}_title")
    repeat_labels = list(REPEAT_OPTIONS)
    default_repeat = next(
        (label for label, r in REPEAT_OPTIONS.items() if r.value == d.get("repeat_type", "none")),
        "不重复",
    )
    repeat_label = st.segmented_control(
        "重复", repeat_labels, default=default_repeat, key=f"{key}_repeat",
    ) or "不重复"
    repeat = REPEAT_OPTIONS[repeat_label]

    settings = load_settings(db)
    all_day = False
    repeat_days: list[int] = []
    times: list[str] = []
    remind_at: Optional[datetime] = None

    if repeat == RepeatType.NONE:
        c1, c2, c3 = st.columns([2, 2, 1], vertical_alignment="bottom")
        remind_d = c1.date_input(
            "日期", value=d.get("remind_at", datetime.now()).date(), key=f"{key}_date",
        )
        all_day = c3.toggle("全天", value=d.get("all_day", False), key=f"{key}_allday",
                            help=f"只有日期,当天 {settings.all_day_time} 提醒")
        if all_day:
            hour, minute = map(int, settings.all_day_time.split(":"))
            remind_at = datetime.combine(remind_d, dtime(hour, minute))
        else:
            default_t = d.get("remind_at") or (datetime.now() + timedelta(minutes=5))
            remind_t = c2.time_input("时间", value=default_t.time(), key=f"{key}_time", step=300)
            remind_at = datetime.combine(remind_d, remind_t)
    else:
        if repeat == RepeatType.WEEKLY:
            default_days = [WEEKDAY_NAMES[i] for i in d.get("repeat_days", [])]
            picked = st.pills(
                "周几", WEEKDAY_NAMES, selection_mode="multi",
                default=default_days, key=f"{key}_days",
            )
            repeat_days = sorted(WEEKDAY_NAMES.index(p) for p in picked)
        raw_times = st.multiselect(
            "提醒时间点(可多个,可直接输入如 08:30)",
            options=sorted(set(TIME_OPTIONS + d.get("repeat_times", []))),
            default=d.get("repeat_times", []),
            accept_new_options=True,
            key=f"{key}_times",
        )
        normed = [norm_time(t) for t in raw_times]
        if any(n is None for n in normed):
            st.warning("时间点格式应为 HH:MM,如 08:30")
            return None
        times = sorted(set(normed))

    duration = st.number_input(
        "时长(分钟,0 表示无时长)", min_value=0,
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
    st.header("⚙️ 设置")
    snooze = st.number_input(
        "稍等间隔(分钟)", min_value=1, max_value=240, value=settings.snooze_minutes,
        help="稍等或忽略提醒后,多久再次提醒",
    )
    ad_h, ad_m = map(int, settings.all_day_time.split(":"))
    all_day_t = st.time_input("全天事项提醒时间", value=dtime(ad_h, ad_m), step=300,
                              help="只有日期、没有时间的事项,当天几点提醒")
    digest_on = st.toggle("每日待办汇总", value=settings.daily_digest_time is not None)
    digest_time_val = None
    if digest_on:
        default_t = (
            dtime.fromisoformat(settings.daily_digest_time)
            if settings.daily_digest_time else dtime(21, 0)
        )
        digest_time_val = st.time_input("汇总提醒时间", value=default_t, step=300)

    new_digest = digest_time_val.strftime("%H:%M") if digest_time_val else None
    new_all_day = all_day_t.strftime("%H:%M")
    if (
        snooze != settings.snooze_minutes
        or new_digest != settings.daily_digest_time
        or new_all_day != settings.all_day_time
    ):
        settings.snooze_minutes = int(snooze)
        settings.daily_digest_time = new_digest
        settings.all_day_time = new_all_day
        save_settings(db, settings)

st.title("⏰ lodo")

# ---------------- 创建事项 ----------------

nl_col, btn_col = st.columns([5, 1], vertical_alignment="bottom")
nl_text = nl_col.text_input(
    "自然语言创建",
    placeholder="例如:今天9点提醒我给妈妈打电话 / 每天9点和21点提醒吃药 / 每周一三五8点健身",
)
if btn_col.button("✨ 解析", width="stretch") and nl_text.strip():
    try:
        with st.spinner("DeepSeek 解析中…"):
            st.session_state.pending_parse = parse_task(nl_text.strip())
    except AIParseError as exc:
        st.session_state.pending_parse = None
        st.error(str(exc))

if st.session_state.pending_parse:
    with st.container(border=True):
        st.markdown("**解析结果,确认后创建:**")
        task = task_fields("p", st.session_state.pending_parse)
        ok_col, cancel_col = st.columns(2)
        if ok_col.button("✅ 创建", type="primary", width="stretch"):
            if task is None:
                st.warning("请补全事项内容和时间设置")
            else:
                db.add_task(task)
                st.session_state.pending_parse = None
                st.rerun()
        if cancel_col.button("取消", width="stretch"):
            st.session_state.pending_parse = None
            st.rerun()

with st.expander("✍️ 手动创建"):
    task = task_fields("m", {})
    if st.button("创建", type="primary", key="m_submit"):
        if task is None:
            st.warning("请补全事项内容和时间设置(重复事项需选周几和时间点)")
        else:
            db.add_task(task)
            st.rerun()


# ---------------- 轮询 + 提醒 + 列表(每 10 秒自动刷新) ----------------

def task_caption(task: Task) -> str:
    parts = [fmt(task.next_remind_at)]
    if task.is_recurring:
        parts.append(task.repeat_label())
    elif task.all_day:
        parts.append("全天")
    if task.duration_minutes:
        parts.append(f"{task.duration_minutes} 分钟")
    if task.phase == Phase.END:
        parts.append("进行中")
    return " · ".join(parts)


@st.fragment(run_every="10s")
def reminder_and_lists() -> None:
    now = datetime.now()
    settings = load_settings(db)
    pending = db.pending_tasks()

    # 到期检查:弹出提醒并自动顺延(忽略也会在间隔后再次提醒)
    for task in scheduler.due_tasks(pending, now):
        scheduler.mark_notified(task, now, settings.snooze_minutes)
        db.update_task(task)
        st.session_state.active_reminders.add(task.id)
        verb = "该开始了" if task.phase == Phase.START and task.duration_minutes > 0 else "到时间了"
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
                st.caption(f"{task_caption(task)} — 该开始了!")
                done_label = "▶️ 开始了"
            elif task.phase == Phase.END:
                st.caption("时间到 — 完成了吗?")
                done_label = "✅ 完成"
            else:
                st.caption(task_caption(task))
                done_label = "✅ 完成"
            c1, c2 = st.columns(2)
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
                    st.toast(f"✅ 已完成,下次提醒 {fmt(task.next_remind_at)}")
                st.rerun(scope="fragment")
            if c2.button(f"⏳ 稍等 {settings.snooze_minutes} 分钟", key=f"snooze_{task.id}", width="stretch"):
                scheduler.snooze(task, datetime.now(), settings.snooze_minutes)
                db.update_task(task)
                st.session_state.active_reminders.discard(task.id)
                st.rerun(scope="fragment")

    # ---- 每日汇总卡片 ----
    if st.session_state.digest_date:
        with st.container(border=True):
            st.markdown(f"### 📋 每日待办汇总({st.session_state.digest_date})")
            if pending:
                for t in pending:
                    st.markdown(f"- **{t.title}** — {task_caption(t)}")
            else:
                st.markdown("🎉 今日事项全部完成!")
            if st.button("知道了", key="digest_dismiss"):
                st.session_state.digest_date = None
                st.rerun(scope="fragment")

    # ---- 列表 ----
    tab_todo, tab_done = st.tabs([f"📌 待办 ({len(pending)})", "✅ 已完成"])
    with tab_todo:
        if not pending:
            st.caption("暂无待办事项")
        for task in pending:
            c1, c2, c3, c4 = st.columns([6, 1, 1, 1], vertical_alignment="center")
            c1.markdown(f"**{task.title}**  \n:gray[{task_caption(task)}]")
            if c2.button("✏️", key=f"list_edit_{task.id}", help="编辑"):
                if st.session_state.editing_id == task.id:
                    st.session_state.editing_id = None
                else:
                    st.session_state.editing_id = task.id
                    st.session_state.edit_defaults = task_to_defaults(task)
                    st.session_state.edit_ver += 1
                st.rerun(scope="fragment")
            if c3.button("✓", key=f"list_done_{task.id}", help="标记完成"):
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
            if c4.button("🗑", key=f"list_del_{task.id}", help="删除"):
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
                        "AI 修改",
                        placeholder="例如:改到明天晚上8点 / 时长改成30分钟 / 改成每天早晚各提醒一次",
                        key=f"ai_instr_{task.id}",
                    )
                    if ai_c2.button("✨ 应用", key=f"ai_apply_{task.id}", width="stretch") and instr.strip():
                        current = task_to_defaults(edited) if edited else st.session_state.edit_defaults
                        try:
                            with st.spinner("DeepSeek 修改中…"):
                                st.session_state.edit_defaults = edit_task(current, instr.strip())
                            st.session_state.edit_ver += 1
                            st.rerun(scope="fragment")
                        except AIParseError as exc:
                            st.error(str(exc))
                    s_col, x_col = st.columns(2)
                    if s_col.button("💾 保存", type="primary", key=f"save_{task.id}", width="stretch"):
                        if edited is None:
                            st.warning("请补全事项内容和时间设置(重复事项需选周几和时间点)")
                        else:
                            edited.id = task.id
                            db.update_task(edited)
                            st.session_state.editing_id = None
                            st.session_state.active_reminders.discard(task.id)
                            st.rerun(scope="fragment")
                    if x_col.button("取消", key=f"cancel_{task.id}", width="stretch"):
                        st.session_state.editing_id = None
                        st.rerun(scope="fragment")
    with tab_done:
        done = db.done_tasks()
        if not done:
            st.caption("还没有完成的事项")
        for task in done:
            st.markdown(f"~~{task.title}~~ :gray[完成于 {fmt(task.done_at)}]")


reminder_and_lists()
