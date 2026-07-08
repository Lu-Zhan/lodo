"""lodo — 提醒事项 Web 演示版 (Streamlit)。"""
from __future__ import annotations

from datetime import date, datetime, time as dtime, timedelta

import streamlit as st

from lodo import scheduler
from lodo.ai import AIParseError, parse_task
from lodo.db import Database
from lodo.models import Phase, Status, Task
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


def fmt(dt: datetime) -> str:
    today = date.today()
    if dt.date() == today:
        return f"今天 {dt:%H:%M}"
    if dt.date() == today + timedelta(days=1):
        return f"明天 {dt:%H:%M}"
    return f"{dt:%m-%d %H:%M}"


# ---------------- 侧边栏:设置 ----------------

settings = load_settings(db)

with st.sidebar:
    st.header("⚙️ 设置")
    snooze = st.number_input(
        "稍等间隔(分钟)", min_value=1, max_value=240, value=settings.snooze_minutes,
        help="稍等或忽略提醒后,多久再次提醒",
    )
    digest_on = st.toggle("每日待办汇总", value=settings.daily_digest_time is not None)
    digest_time_val = None
    if digest_on:
        default_t = (
            dtime.fromisoformat(settings.daily_digest_time)
            if settings.daily_digest_time else dtime(21, 0)
        )
        digest_time_val = st.time_input("汇总提醒时间", value=default_t, step=300)

    new_digest = digest_time_val.strftime("%H:%M") if digest_time_val else None
    if snooze != settings.snooze_minutes or new_digest != settings.daily_digest_time:
        settings.snooze_minutes = int(snooze)
        settings.daily_digest_time = new_digest
        save_settings(db, settings)

st.title("⏰ lodo")

# ---------------- 创建事项 ----------------

nl_col, btn_col = st.columns([5, 1], vertical_alignment="bottom")
nl_text = nl_col.text_input(
    "自然语言创建", placeholder="例如:今天9点提醒我给妈妈打电话 / 明天下午3点开会一小时",
)
if btn_col.button("✨ 解析", use_container_width=True) and nl_text.strip():
    try:
        with st.spinner("DeepSeek 解析中…"):
            st.session_state.pending_parse = parse_task(nl_text.strip())
    except AIParseError as exc:
        st.session_state.pending_parse = None
        st.error(str(exc))

if st.session_state.pending_parse:
    p = st.session_state.pending_parse
    with st.container(border=True):
        st.markdown("**解析结果,确认后创建:**")
        c1, c2, c3 = st.columns(3)
        title = c1.text_input("事项", value=p["title"], key="parse_title")
        remind_d = c2.date_input("日期", value=p["remind_at"].date(), key="parse_date")
        remind_t = c3.time_input("时间", value=p["remind_at"].time(), key="parse_time", step=300)
        duration = st.number_input(
            "时长(分钟,0 表示无时长)", min_value=0, value=p["duration_minutes"], key="parse_dur",
        )
        ok_col, cancel_col = st.columns(2)
        if ok_col.button("✅ 创建", type="primary", use_container_width=True):
            db.add_task(Task(
                id=None, title=title,
                remind_at=datetime.combine(remind_d, remind_t),
                duration_minutes=int(duration),
            ))
            st.session_state.pending_parse = None
            st.rerun()
        if cancel_col.button("取消", use_container_width=True):
            st.session_state.pending_parse = None
            st.rerun()

with st.expander("✍️ 手动创建"):
    with st.form("manual_create", clear_on_submit=True):
        m_title = st.text_input("事项内容")
        c1, c2, c3 = st.columns(3)
        m_date = c1.date_input("日期", value=date.today())
        default_time = (datetime.now() + timedelta(minutes=5)).time().replace(second=0, microsecond=0)
        m_time = c2.time_input("时间", value=default_time, step=300)
        m_dur = c3.number_input("时长(分钟)", min_value=0, value=0)
        if st.form_submit_button("创建", type="primary") and m_title.strip():
            db.add_task(Task(
                id=None, title=m_title.strip(),
                remind_at=datetime.combine(m_date, m_time),
                duration_minutes=int(m_dur),
            ))
            st.rerun()


# ---------------- 轮询 + 提醒 + 列表(每 10 秒自动刷新) ----------------

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
            if starting:
                st.markdown(f"### 🔔 {task.title}")
                st.caption(f"计划 {fmt(task.remind_at)} 开始,时长 {task.duration_minutes} 分钟 — 该开始了!")
                done_label = "▶️ 开始了"
            elif task.phase == Phase.END:
                st.markdown(f"### 🔔 {task.title}")
                st.caption("时间到 — 完成了吗?")
                done_label = "✅ 完成"
            else:
                st.markdown(f"### 🔔 {task.title}")
                st.caption(f"计划时间 {fmt(task.remind_at)}")
                done_label = "✅ 完成"
            c1, c2 = st.columns(2)
            if c1.button(done_label, key=f"done_{task.id}", type="primary", use_container_width=True):
                scheduler.advance(task, datetime.now())
                db.update_task(task)
                st.session_state.active_reminders.discard(task.id)
                st.rerun(scope="fragment")
            if c2.button(f"⏳ 稍等 {settings.snooze_minutes} 分钟", key=f"snooze_{task.id}", use_container_width=True):
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
                    dur = f"(时长 {t.duration_minutes} 分钟)" if t.duration_minutes else ""
                    st.markdown(f"- **{t.title}** — {fmt(t.next_remind_at)}{dur}")
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
            c1, c2, c3 = st.columns([6, 1, 1], vertical_alignment="center")
            dur = f" · {task.duration_minutes} 分钟" if task.duration_minutes else ""
            phase_note = " · 进行中" if task.phase == Phase.END else ""
            c1.markdown(f"**{task.title}**  \n:gray[{fmt(task.next_remind_at)}{dur}{phase_note}]")
            if c2.button("✓", key=f"list_done_{task.id}", help="标记完成"):
                task.status = Status.DONE
                task.done_at = datetime.now()
                db.update_task(task)
                st.rerun(scope="fragment")
            if c3.button("🗑", key=f"list_del_{task.id}", help="删除"):
                db.delete_task(task.id)
                st.rerun(scope="fragment")
    with tab_done:
        done = db.done_tasks()
        if not done:
            st.caption("还没有完成的事项")
        for task in done:
            st.markdown(f"~~{task.title}~~ :gray[完成于 {fmt(task.done_at)}]")


reminder_and_lists()
