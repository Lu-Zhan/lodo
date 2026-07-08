"""应用设置:默认稍等间隔、每日汇总时间。存储在 settings 表。"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from .db import Database

DEFAULT_SNOOZE_MINUTES = 15
DEFAULT_ALL_DAY_TIME = "09:00"


@dataclass
class AppSettings:
    snooze_minutes: int = DEFAULT_SNOOZE_MINUTES
    all_day_time: str = DEFAULT_ALL_DAY_TIME  # 全天(仅日期)事项当天的提醒时间
    daily_digest_time: Optional[str] = None  # "HH:MM",None 表示关闭
    last_digest_date: Optional[str] = None   # "YYYY-MM-DD"


def load_settings(db: Database) -> AppSettings:
    snooze = db.get_setting("snooze_minutes", str(DEFAULT_SNOOZE_MINUTES))
    all_day_time = db.get_setting("all_day_time", DEFAULT_ALL_DAY_TIME)
    digest_time = db.get_setting("daily_digest_time") or None
    last_date = db.get_setting("last_digest_date") or None
    return AppSettings(
        snooze_minutes=int(snooze),
        all_day_time=all_day_time,
        daily_digest_time=digest_time,
        last_digest_date=last_date,
    )


def save_settings(db: Database, settings: AppSettings) -> None:
    db.set_setting("snooze_minutes", str(settings.snooze_minutes))
    db.set_setting("all_day_time", settings.all_day_time)
    db.set_setting("daily_digest_time", settings.daily_digest_time or "")


def mark_digest_shown(db: Database, date_str: str) -> None:
    db.set_setting("last_digest_date", date_str)
