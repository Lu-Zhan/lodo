#!/usr/bin/env python3
"""SQLite 回归:9→13 的 DDL/默认值/数据保留,对照 KSP 生成的新库结构。
先运行 :app:assembleDebug。本脚本不替代 Android 上的 Room MigrationTestHelper。
"""
from pathlib import Path
import re
import sqlite3

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "app/src/main/java/com/lodo/app/data/LodoDatabase.kt").read_text()
generated = ROOT / "app/build/generated/ksp/debug/kotlin/com/lodo/app/data/LodoDatabase_Impl.kt"
if not generated.exists():
    raise SystemExit("请先运行 :app:assembleDebug 生成 Room 结构")


def literals(text):
    pattern = r'execSQL\((?:"""(.*?)"""|"((?:\\.|[^"\\])*)")\)'
    return [a or b.replace('\\"', '"') for a, b in re.findall(pattern, text, re.S)]


migrations = {}
for start, end, body in re.findall(r'val MIGRATION_(\d+)_(\d+) = (.*?)(?=\n(?:val MIGRATION_|@Database)|\Z)', source, re.S):
    if not 9 <= int(start) < 13:
        continue
    sql = literals(body)
    if int(start) == 9:
        fields = re.search(r'listOf\((.*?)\)\.forEach', body, re.S).group(1)
        sql = ['ALTER TABLE finance_entries ADD COLUMN ' + field for field in re.findall(r'"([^"]+)"', fields)]
    migrations[int(start)] = sql
assert set(migrations) == {9, 10, 11, 12}, "迁移提取失败"

fresh = sqlite3.connect(":memory:")
old = sqlite3.connect(":memory:")
for sql in literals(generated.read_text()):
    if sql.startswith("CREATE TABLE") or sql.startswith("CREATE INDEX") or sql.startswith("CREATE UNIQUE INDEX"):
        fresh.execute(sql)
        old.execute(sql)

# 由新结构撤去此次新增字段/表,构造 v9 形状;保留所有既有索引。
for start in (12, 11, 10, 9):
    for sql in reversed(migrations[start]):
        added = re.match(r'ALTER TABLE (\w+) ADD COLUMN (\w+)', sql)
        table = re.match(r'CREATE TABLE IF NOT EXISTS (\w+)', sql)
        if added:
            old.execute(f'ALTER TABLE {added[1]} DROP COLUMN {added[2]}')
        elif table:
            old.execute(f'DROP TABLE {table[1]}')


def seed(table, overrides):
    columns = old.execute(f'PRAGMA table_info({table})').fetchall()
    values = {}
    for _, name, kind, required, default, pk in columns:
        values[name] = overrides.get(name, 0 if kind in ("INTEGER", "REAL") and required else "" if required else None)
    old.execute(f'INSERT INTO {table} ({",".join(values)}) VALUES ({",".join("?" for _ in values)})', list(values.values()))


seed("finance_entries", {"uuid": "card", "kind": "credit_card", "title": "旧卡", "remindEnabled": 1, "reminderCycle": "2026-07", "notes": "保留旧资料"})
seed("memories", {"uuid": "report", "title": "家人的报告", "tags": "体检报告,家人健康,health-profile:family"})
seed("tasks", {"uuid": "task", "title": "旧任务"})
for start in (9, 10, 11, 12):
    if start == 12:
        seed("checkup_entries", {"uuid": "advice", "reportUuid": "report", "profileUuid": "family", "kind": "summary", "name": "综合建议", "advice": "原报告建议", "dateDay": "2026-07-08"})
    for sql in migrations[start]:
        old.execute(sql)


def tables(db):
    return [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")]


def structure(db, table):
    return {row[1]: row[2:] for row in db.execute(f'PRAGMA table_info({table})')}


assert set(tables(old)) == set(tables(fresh))
for table in tables(fresh):
    assert structure(old, table) == structure(fresh, table), f"新建/迁移结构不同:{table}"
assert old.execute("SELECT title,remindEnabled,reminderCycle,notes,repaymentLeadDays,estimated FROM finance_entries").fetchone() == ("旧卡", 1, "2026-07", "保留旧资料", 1, 0)
assert old.execute("SELECT title,medicationUuid FROM tasks").fetchone() == ("旧任务", None)
assert old.execute("SELECT checkupDateDay,checkupProfileUuid FROM memories").fetchone() == ("2026-07-08", "family")
assert old.execute("SELECT kind,name,advice FROM checkup_entries").fetchone() == ("advice", "", "原报告建议")
print(f"PASS: v9→13, {len(tables(fresh))} tables match generated Room schema; old card/task and family report retained")
