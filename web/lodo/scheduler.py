"""提醒调度核心逻辑。

纯函数操作 Task 对象,不直接读写数据库,由调用方(UI 层)负责持久化,
便于用伪造时间做单元测试。
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

from .models import Phase, RepeatType, Status, Task
from .settings import AppSettings


def due_tasks(tasks: list[Task], now: datetime) -> list[Task]:
    """返回此刻应当弹出提醒的事项。"""
    return [t for t in tasks if t.is_due(now)]


def mark_notified(task: Task, now: datetime, snooze_minutes: int) -> Task:
    """弹出提醒的同时把下次提醒自动顺延——忽略提醒也会在间隔后再次提醒。"""
    task.last_notified_at = now
    task.next_remind_at = now + timedelta(minutes=snooze_minutes)
    return task


def snooze(task: Task, now: datetime, snooze_minutes: int) -> Task:
    """用户点"稍等"。"""
    task.next_remind_at = now + timedelta(minutes=snooze_minutes)
    return task


def next_occurrence(task: Task, after: datetime) -> Optional[datetime]:
    """重复事项在 after 之后的下一次提醒时间。

    每日:每天在 repeat_times 各提醒一次;
    每周:仅在 repeat_days 选中的周几提醒。
    """
    if not task.is_recurring or not task.repeat_times:
        return None
    if task.repeat_type == RepeatType.WEEKLY and not task.repeat_days:
        return None
    days = set(range(7)) if task.repeat_type == RepeatType.DAILY else set(task.repeat_days)
    times = sorted(task.repeat_times)
    for offset in range(8):  # 最多一周内必有下一次
        day = after.date() + timedelta(days=offset)
        if day.weekday() not in days:
            continue
        for hhmm in times:
            hour, minute = map(int, hhmm.split(":"))
            candidate = datetime.combine(day, datetime.min.time()).replace(hour=hour, minute=minute)
            if candidate > after:
                return candidate
    return None


def advance(task: Task, now: datetime) -> bool:
    """用户对提醒做出肯定响应。返回 True 表示完成了一次(或整个)事项。

    - 时长 > 0 且处于开始阶段:表示"开始做了",转入结束阶段,
      在实际开始时间 + 时长后提醒确认完成,返回 False。
    - 其余情况即完成:一次性事项标记 done;重复事项排到下一次提醒。
    """
    if task.phase == Phase.START and task.duration_minutes > 0:
        task.phase = Phase.END
        task.next_remind_at = now + timedelta(minutes=task.duration_minutes)
        return False
    nxt = next_occurrence(task, now)
    if nxt is not None:
        task.phase = Phase.START
        task.remind_at = nxt
        task.next_remind_at = nxt
    else:
        task.status = Status.DONE
        task.done_at = now
    return True


def should_show_digest(settings: AppSettings, now: datetime) -> bool:
    """每日汇总:设置了时间、当天已到点、且今天还没弹过。"""
    if not settings.daily_digest_time:
        return False
    today = now.strftime("%Y-%m-%d")
    if settings.last_digest_date == today:
        return False
    hour, minute = map(int, settings.daily_digest_time.split(":"))
    digest_at = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    return now >= digest_at
