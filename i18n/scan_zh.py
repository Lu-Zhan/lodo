#!/usr/bin/env python3
"""一次性抓取脚本(只读源码,不改动任何文件):扫描 iOS/Android 源码里
Text(...)/Button(...)/Label(...)/.navigationTitle(...)/TextField(...) 等调用
的字面量中文字符串参数,输出去重后的候选清单供人工翻译审阅、汇总进
strings.csv。这是一次性辅助工具,不是构建流程的一部分。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CJK = re.compile(r"[一-鿿]")

# 匹配形如 Text("...")、Button("...", ...)、.navigationTitle("...")、
# Label("...", systemImage: ...)、TextField("...", text: ...)、
# contentDescription = "...", placeholder = "..." 等调用里的第一个字符串字面量。
SWIFT_PATTERNS = [
    re.compile(r'\bText\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bButton\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bLabel\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\.navigationTitle\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bTextField\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bTextEditor\([^)]*\)\s*//.*'),  # placeholder, ignore
    re.compile(r'contentDescription:\s*"((?:[^"\\]|\\.)*)"'),
    # 2026-08:补 Toggle/Picker/Section/Stepper/DisclosureGroup——第一轮漏了这几个
    # SwiftUI 控件,导致设置页里好几处标题(振动反馈/汇总展示币种等)没接上
    # String Catalog,模拟器验证时才发现。以后加新控件字面量务必先跑一遍这个
    # 脚本核对差集,不要只信任 Text/Button 这几个"常见"入口。
    re.compile(r'\bToggle\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bPicker\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bSection\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bStepper\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bDisclosureGroup\(\s*"((?:[^"\\]|\\.)*)"'),
]

KOTLIN_PATTERNS = [
    re.compile(r'\bText\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bText\(\s*text\s*=\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'contentDescription\s*=\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\blabel\s*=\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'placeholder\s*=\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bmessage\s*=\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bactionLabel\s*=\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\btitle\s*=\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bSectionHeader\(\s*"((?:[^"\\]|\\.)*)"'),
    re.compile(r'\bEmptyState\([^,]+,\s*"((?:[^"\\]|\\.)*)"'),
]


def scan(root: Path, patterns, glob: str):
    hits = {}
    for path in sorted(root.glob(glob)):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for lineno, line in enumerate(lines, start=1):
            if not CJK.search(line):
                continue
            for pat in patterns:
                for m in pat.finditer(line):
                    text = m.group(1) if m.groups() else ""
                    if text and CJK.search(text):
                        rel = path.relative_to(ROOT)
                        hits.setdefault(text, []).append(f"{rel}:{lineno}")
    return hits


def main():
    ios_hits = scan(ROOT / "ios" / "Lodo", SWIFT_PATTERNS, "**/*.swift")
    android_hits = scan(
        ROOT / "android" / "app" / "src" / "main" / "java" / "com" / "lodo" / "app" / "ui",
        KOTLIN_PATTERNS, "**/*.kt")

    all_zh = sorted(set(ios_hits) | set(android_hits))
    print(f"# iOS 命中 {len(ios_hits)} 条唯一字符串,Android 命中 {len(android_hits)} 条")
    print(f"# 并集去重后共 {len(all_zh)} 条")
    print("zh\tin_ios\tin_android\tsample_locations")
    for zh in all_zh:
        in_ios = "1" if zh in ios_hits else ""
        in_android = "1" if zh in android_hits else ""
        locs = (ios_hits.get(zh, []) + android_hits.get(zh, []))[:3]
        print(f"{zh}\t{in_ios}\t{in_android}\t{'; '.join(locs)}")


if __name__ == "__main__":
    sys.exit(main())
