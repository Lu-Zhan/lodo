"""数据模型:事项 Task 及其状态。"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta
from enum import Enum
from typing import Optional


class Status(str, Enum):
    PENDING = "pending"
    DONE = "done"


class Phase(str, Enum):
    START = "start"  # 等待开始提醒
    END = "end"      # 已开始,等待结束提醒(仅时长 > 0 的事项)


class RepeatType(str, Enum):
    NONE = "none"
    DAILY = "daily"
    WEEKLY = "weekly"


WEEKDAY_NAMES = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


@dataclass
class Task:
    id: Optional[int]
    title: str
    remind_at: datetime
    duration_minutes: int = 0
    all_day: bool = False                    # 仅日期,无具体时间
    repeat_type: RepeatType = RepeatType.NONE
    repeat_days: list[int] = field(default_factory=list)   # 每周重复:0=周一 … 6=周日
    repeat_times: list[str] = field(default_factory=list)  # 重复事项的提醒时间点 "HH:MM"
    status: Status = Status.PENDING
    phase: Phase = Phase.START
    next_remind_at: Optional[datetime] = None
    last_notified_at: Optional[datetime] = None
    created_at: Optional[datetime] = None
    done_at: Optional[datetime] = None

    def __post_init__(self) -> None:
        if self.next_remind_at is None:
            self.next_remind_at = self.remind_at

    @property
    def is_recurring(self) -> bool:
        return self.repeat_type != RepeatType.NONE

    def repeat_label(self) -> str:
        """重复规则的可读描述,如"每周一、三 09:00/21:00"。"""
        if not self.is_recurring:
            return ""
        times = "/".join(self.repeat_times)
        if self.repeat_type == RepeatType.DAILY:
            return f"每天 {times}"
        days = "、".join(WEEKDAY_NAMES[d][1] for d in sorted(self.repeat_days))
        return f"每周{days} {times}"

    def is_due(self, now: datetime) -> bool:
        return (
            self.status == Status.PENDING
            and self.next_remind_at is not None
            and now >= self.next_remind_at
        )
