"""数据模型:事项 Task 及其状态。"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum
from typing import Optional


class Status(str, Enum):
    PENDING = "pending"
    DONE = "done"


class Phase(str, Enum):
    START = "start"  # 等待开始提醒
    END = "end"      # 已开始,等待结束提醒(仅时长 > 0 的事项)


@dataclass
class Task:
    id: Optional[int]
    title: str
    remind_at: datetime
    duration_minutes: int = 0
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
    def end_at(self) -> datetime:
        return self.remind_at + timedelta(minutes=self.duration_minutes)

    def is_due(self, now: datetime) -> bool:
        return (
            self.status == Status.PENDING
            and self.next_remind_at is not None
            and now >= self.next_remind_at
        )
