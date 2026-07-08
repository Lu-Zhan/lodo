"""SQLite 存取层。数据库文件位于 web/data/lodo.db。"""
from __future__ import annotations

import sqlite3
from datetime import datetime
from pathlib import Path
from typing import Optional

from .models import Phase, Status, Task

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
DB_PATH = DATA_DIR / "lodo.db"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    title TEXT NOT NULL,
    remind_at TEXT NOT NULL,
    duration_minutes INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'pending',
    phase TEXT NOT NULL DEFAULT 'start',
    next_remind_at TEXT NOT NULL,
    last_notified_at TEXT,
    created_at TEXT NOT NULL,
    done_at TEXT
);
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""


def _connect(db_path: Path = DB_PATH) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    # Streamlit 每次 rerun 可能在不同线程执行脚本,连接被 cache_resource 复用
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.executescript(_SCHEMA)
    return conn


def _dt(value: Optional[str]) -> Optional[datetime]:
    return datetime.fromisoformat(value) if value else None


def _row_to_task(row: sqlite3.Row) -> Task:
    return Task(
        id=row["id"],
        title=row["title"],
        remind_at=datetime.fromisoformat(row["remind_at"]),
        duration_minutes=row["duration_minutes"],
        status=Status(row["status"]),
        phase=Phase(row["phase"]),
        next_remind_at=_dt(row["next_remind_at"]),
        last_notified_at=_dt(row["last_notified_at"]),
        created_at=_dt(row["created_at"]),
        done_at=_dt(row["done_at"]),
    )


class Database:
    def __init__(self, db_path: Path = DB_PATH):
        self.conn = _connect(db_path)

    # ---- tasks ----

    def add_task(self, task: Task) -> Task:
        now = datetime.now()
        cur = self.conn.execute(
            "INSERT INTO tasks (title, remind_at, duration_minutes, status, phase,"
            " next_remind_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (
                task.title,
                task.remind_at.isoformat(),
                task.duration_minutes,
                task.status.value,
                task.phase.value,
                (task.next_remind_at or task.remind_at).isoformat(),
                now.isoformat(),
            ),
        )
        self.conn.commit()
        task.id = cur.lastrowid
        task.created_at = now
        return task

    def update_task(self, task: Task) -> None:
        self.conn.execute(
            "UPDATE tasks SET title=?, remind_at=?, duration_minutes=?, status=?,"
            " phase=?, next_remind_at=?, last_notified_at=?, done_at=? WHERE id=?",
            (
                task.title,
                task.remind_at.isoformat(),
                task.duration_minutes,
                task.status.value,
                task.phase.value,
                task.next_remind_at.isoformat(),
                task.last_notified_at.isoformat() if task.last_notified_at else None,
                task.done_at.isoformat() if task.done_at else None,
                task.id,
            ),
        )
        self.conn.commit()

    def delete_task(self, task_id: int) -> None:
        self.conn.execute("DELETE FROM tasks WHERE id=?", (task_id,))
        self.conn.commit()

    def get_task(self, task_id: int) -> Optional[Task]:
        row = self.conn.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
        return _row_to_task(row) if row else None

    def pending_tasks(self) -> list[Task]:
        rows = self.conn.execute(
            "SELECT * FROM tasks WHERE status='pending' ORDER BY next_remind_at"
        ).fetchall()
        return [_row_to_task(r) for r in rows]

    def done_tasks(self, limit: int = 100) -> list[Task]:
        rows = self.conn.execute(
            "SELECT * FROM tasks WHERE status='done' ORDER BY done_at DESC LIMIT ?",
            (limit,),
        ).fetchall()
        return [_row_to_task(r) for r in rows]

    # ---- settings ----

    def get_setting(self, key: str, default: Optional[str] = None) -> Optional[str]:
        row = self.conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return row["value"] if row else default

    def set_setting(self, key: str, value: str) -> None:
        self.conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?)"
            " ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )
        self.conn.commit()
