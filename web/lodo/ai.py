"""DeepSeek 自然语言解析:创建("今天9点提醒我开会")与编辑("改到晚上8点")事项。"""
from __future__ import annotations

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv
from openai import OpenAI

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

DEEPSEEK_BASE_URL = "https://api.deepseek.com"
DEEPSEEK_MODEL = "deepseek-chat"

_FORMAT_AND_RULES = """返回格式(不适用的字段用默认值):
{{"title": "事项内容(去掉时间词,保留做什么)",
  "remind_at": "YYYY-MM-DD HH:MM",
  "all_day": false,
  "duration_minutes": 0,
  "repeat_type": "none",
  "repeat_days": [],
  "repeat_times": []}}

规则:
- "今天/明天/后天/周X/X月X日" 等相对时间基于当前时间换算成具体日期。
- 只说了点数没说上下午时,按常理推断(如"9点开会"在当前时间之前则理解为最近的将来时间)。
- 未提到时长时 duration_minutes 为 0;"开会一小时"之类则换算成分钟数。
- 只有日期、没有具体时间点的事项(如"明天要交报告"):all_day 设为 true,\
remind_at 用 "YYYY-MM-DD 00:00"。
- 重复事项:"每天…"时 repeat_type 为 "daily";"每周一三五…"之类时 repeat_type 为 "weekly",\
repeat_days 为选中的周几(0=周一 … 6=周日)。repeat_times 为当天的提醒时间点列表,\
可以有多个(如"每天9点和21点提醒吃药" → ["09:00", "21:00"]);重复事项 remind_at 填第一次提醒的时间。
- 无法解析出时间时,返回 {{"error": "原因"}}。"""

_SYSTEM_PROMPT = """你是提醒事项应用 lodo 的解析助手。用户会用自然语言描述一个提醒事项,\
你需要解析出结构化信息,只返回 JSON,不要任何其他文字。

当前时间:{now}(星期{weekday})

""" + _FORMAT_AND_RULES

_EDIT_PROMPT = """你是提醒事项应用 lodo 的编辑助手。给定一个现有事项和用户的修改指令,\
输出修改后的完整事项,只返回 JSON,不要任何其他文字。\
用户没有提到的字段一律保持原值;无法理解指令时返回 {{"error": "原因"}}。

当前时间:{now}(星期{weekday})

现有事项:
{task_json}

""" + _FORMAT_AND_RULES

_WEEKDAYS = "一二三四五六日"


class AIParseError(Exception):
    pass


def _client() -> OpenAI:
    api_key = os.environ.get("DEEPSEEK_API_KEY")
    if not api_key:
        raise AIParseError("未配置 DEEPSEEK_API_KEY,请在 web/.env 中填写,或使用手动创建。")
    return OpenAI(api_key=api_key, base_url=DEEPSEEK_BASE_URL)


def _complete(system_prompt: str, user_text: str) -> dict:
    """调用 DeepSeek 并校验返回的事项 JSON,失败抛 AIParseError。"""
    try:
        resp = _client().chat.completions.create(
            model=DEEPSEEK_MODEL,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_text},
            ],
            response_format={"type": "json_object"},
            temperature=0,
        )
        data = json.loads(resp.choices[0].message.content)
    except AIParseError:
        raise
    except Exception as exc:
        raise AIParseError(f"调用 DeepSeek 失败:{exc}") from exc

    if "error" in data:
        raise AIParseError(f"无法解析:{data['error']}")
    try:
        repeat_times = [str(t) for t in data.get("repeat_times") or []]
        for t in repeat_times:
            datetime.strptime(t, "%H:%M")
        return {
            "title": str(data["title"]).strip(),
            "remind_at": datetime.strptime(data["remind_at"], "%Y-%m-%d %H:%M"),
            "all_day": bool(data.get("all_day", False)),
            "duration_minutes": int(data.get("duration_minutes", 0)),
            "repeat_type": str(data.get("repeat_type", "none")),
            "repeat_days": [int(d) for d in data.get("repeat_days") or []],
            "repeat_times": repeat_times,
        }
    except (KeyError, ValueError) as exc:
        raise AIParseError(f"DeepSeek 返回格式异常:{data}") from exc


def _time_context(now: Optional[datetime]) -> dict:
    now = now or datetime.now()
    return {
        "now": now.strftime("%Y-%m-%d %H:%M"),
        "weekday": _WEEKDAYS[now.weekday()],
    }


def parse_task(text: str, now: Optional[datetime] = None) -> dict:
    """解析自然语言,返回事项字段 dict(remind_at 为 datetime)。失败抛 AIParseError。"""
    return _complete(_SYSTEM_PROMPT.format(**_time_context(now)), text)


def edit_task(current: dict, instruction: str, now: Optional[datetime] = None) -> dict:
    """按自然语言指令修改现有事项,返回修改后的完整字段 dict。

    current 为现有事项字段(parse_task 同构,remind_at 可为 datetime)。
    未提到的字段保持原值;失败抛 AIParseError。
    """
    serializable = dict(current)
    if isinstance(serializable.get("remind_at"), datetime):
        serializable["remind_at"] = serializable["remind_at"].strftime("%Y-%m-%d %H:%M")
    prompt = _EDIT_PROMPT.format(
        task_json=json.dumps(serializable, ensure_ascii=False),
        **_time_context(now),
    )
    return _complete(prompt, instruction)
