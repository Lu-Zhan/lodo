"""调度核心逻辑单元测试(伪造时间,不依赖真实时钟)。"""
import sys
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from lodo import scheduler
from lodo.models import Phase, RepeatType, Status, Task
from lodo.settings import AppSettings

T0 = datetime(2026, 7, 8, 9, 0)


def make_task(**kw):
    defaults = dict(id=1, title="测试", remind_at=T0)
    defaults.update(kw)
    return Task(**defaults)


def test_due_at_time():
    t = make_task()
    assert not t.is_due(T0 - timedelta(minutes=1))
    assert t.is_due(T0)
    assert scheduler.due_tasks([t], T0) == [t]


def test_ignored_reminder_fires_again_after_snooze():
    t = make_task()
    scheduler.mark_notified(t, T0, 15)  # 弹出提醒,用户忽略
    assert not t.is_due(T0 + timedelta(minutes=14))
    assert t.is_due(T0 + timedelta(minutes=15))


def test_explicit_snooze():
    t = make_task()
    scheduler.mark_notified(t, T0, 15)
    scheduler.snooze(t, T0 + timedelta(minutes=2), 15)  # 2 分钟后点"稍等"
    assert t.next_remind_at == T0 + timedelta(minutes=17)
    assert t.status == Status.PENDING


def test_complete_zero_duration():
    t = make_task()
    scheduler.advance(t, T0 + timedelta(minutes=1))
    assert t.status == Status.DONE
    assert t.done_at == T0 + timedelta(minutes=1)


def test_duration_task_two_phase():
    t = make_task(duration_minutes=30)
    # 开始提醒 → 用户点"开始了"(晚了 5 分钟才开始)
    start_at = T0 + timedelta(minutes=5)
    scheduler.advance(t, start_at)
    assert t.status == Status.PENDING
    assert t.phase == Phase.END
    # 结束提醒基于实际开始时间 + 时长
    assert t.next_remind_at == start_at + timedelta(minutes=30)
    assert t.is_due(start_at + timedelta(minutes=30))
    # 结束提醒 → 点"完成"
    scheduler.advance(t, start_at + timedelta(minutes=31))
    assert t.status == Status.DONE


def test_digest_fires_once_per_day():
    s = AppSettings(daily_digest_time="21:00", last_digest_date=None)
    day = datetime(2026, 7, 8, 20, 59)
    assert not scheduler.should_show_digest(s, day)
    assert scheduler.should_show_digest(s, day.replace(hour=21, minute=0))
    s.last_digest_date = "2026-07-08"  # 已弹过
    assert not scheduler.should_show_digest(s, day.replace(hour=22))
    # 第二天再次触发
    assert scheduler.should_show_digest(s, datetime(2026, 7, 9, 21, 0))


def test_daily_multiple_times():
    t = make_task(repeat_type=RepeatType.DAILY, repeat_times=["09:00", "21:00"])
    # 9:00 当口 → 下一次是当天 21:00
    assert scheduler.next_occurrence(t, T0) == T0.replace(hour=21)
    # 21:00 之后 → 次日 9:00
    assert scheduler.next_occurrence(t, T0.replace(hour=22)) == T0.replace(hour=9) + timedelta(days=1)


def test_weekly_selected_days():
    # 2026-07-08 是周三(weekday=2);选周一、周五 8:00
    t = make_task(repeat_type=RepeatType.WEEKLY, repeat_days=[0, 4], repeat_times=["08:00"])
    nxt = scheduler.next_occurrence(t, T0)
    assert nxt == datetime(2026, 7, 10, 8, 0)  # 本周五
    nxt2 = scheduler.next_occurrence(t, nxt)
    assert nxt2 == datetime(2026, 7, 13, 8, 0)  # 下周一


def test_weekly_without_days_is_invalid():
    t = make_task(repeat_type=RepeatType.WEEKLY, repeat_times=["08:00"])
    assert scheduler.next_occurrence(t, T0) is None


def test_recurring_advance_schedules_next():
    t = make_task(repeat_type=RepeatType.DAILY, repeat_times=["09:00"])
    finished = scheduler.advance(t, T0 + timedelta(minutes=3))
    assert finished
    assert t.status == Status.PENDING  # 重复事项本体不标记 done
    assert t.next_remind_at == T0 + timedelta(days=1)


def test_recurring_with_duration_two_phase():
    t = make_task(repeat_type=RepeatType.DAILY, repeat_times=["09:00"], duration_minutes=20)
    assert not scheduler.advance(t, T0)      # 开始了 → 进入 end 阶段
    assert t.phase == Phase.END
    assert scheduler.advance(t, T0 + timedelta(minutes=20))  # 完成一次
    assert t.status == Status.PENDING
    assert t.phase == Phase.START
    assert t.next_remind_at == T0 + timedelta(days=1)


def test_digest_disabled():
    s = AppSettings(daily_digest_time=None)
    assert not scheduler.should_show_digest(s, datetime(2026, 7, 8, 23, 59))


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for fn in fns:
        fn()
        print(f"ok  {fn.__name__}")
    print(f"\n{len(fns)} tests passed")
