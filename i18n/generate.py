#!/usr/bin/env python3
"""从 i18n/strings.csv 生成四份本地化产物,不手写 JSON/XML/Swift/Kotlin。
运行:python3 i18n/generate.py
产物全部标注"生成文件,不要手改",改动一律回到 strings.csv 重新生成。
"""
import csv
import json
import re
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape

ROOT = Path(__file__).resolve().parent.parent
CSV_PATH = ROOT / "i18n" / "strings.csv"

IOS_VIEW_SCOPES = {"ios_view", "shared"}
IOS_CORE_SCOPES = {"ios_core", "ios_notif", "shared"}
ANDROID_UI_SCOPES = {"android_ui", "shared"}
ANDROID_CORE_SCOPES = {"android_core_ai", "android_notif", "shared"}

GENERATED_HEADER_SWIFT = (
    "// 由 i18n/generate.py 从 i18n/strings.csv 生成,不要手改。\n"
    "// 改动请回到 strings.csv 修订后重新运行脚本。\n\n"
)
GENERATED_HEADER_KOTLIN = GENERATED_HEADER_SWIFT
GENERATED_HEADER_XML = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    "<!-- 由 i18n/generate.py 从 i18n/strings.csv 生成,不要手改。 -->\n"
)


def load_rows():
    with CSV_PATH.open(encoding="utf-8") as f:
        return list(csv.DictReader(f))


def swift_string_literal(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def kotlin_string_literal(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("\n", "\\n") + '"'


def android_xml_string(s: str) -> str:
    escaped = xml_escape(s)
    escaped = escaped.replace("'", "\\'")
    return escaped


def gen_xcstrings(rows):
    strings = {}
    for row in rows:
        if row["scope"] not in IOS_VIEW_SCOPES:
            continue
        zh, en = row["zh"], row["en"]
        if zh in strings:
            continue
        strings[zh] = {
            "localizations": {
                # 显式给 zh-Hans 也写一条(值等于 key 本身),不能只靠
                # "sourceLanguage": "zh-Hans" 隐式兜底——实测 .environment(\.locale,
                # Locale(identifier: "zh-Hans")) 在没有显式 zh-Hans 条目时,
                # 系统语言若是英文,依然会解析成 en,隐式兜底不可靠。
                "en": {"stringUnit": {"state": "translated", "value": en}},
                "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
            }
        }
    catalog = {
        "sourceLanguage": "zh-Hans",
        "strings": strings,
        "version": "1.0",
    }
    out = ROOT / "ios" / "Lodo" / "Localizable.xcstrings"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"wrote {len(strings)} keys to {out.relative_to(ROOT)}")


def gen_ios_core_swift(rows):
    entries = []
    seen_slugs = set()
    for row in rows:
        if row["scope"] not in IOS_CORE_SCOPES:
            continue
        slug = row["slug"]
        if slug in seen_slugs:
            continue
        seen_slugs.add(slug)
        # slug 里的点号/连字符转成合法 Swift case 标识符
        case_name = re.sub(r"[^a-zA-Z0-9]", "_", slug)
        case_name = re.sub(r"_+", "_", case_name).strip("_")
        if case_name[0].isdigit():
            case_name = "k" + case_name
        entries.append((case_name, row["zh"], row["en"]))

    lines = [GENERATED_HEADER_SWIFT, "import Foundation\n", ""]
    lines.append("/// 生成表的 key;供 LodoCore 内非 View 上下文(错误文案、通知模板、")
    lines.append("/// repeatLabel 等)显式查表用,不经过 SwiftUI 的 .environment(\\.locale)。")
    lines.append("public enum LK: String, CaseIterable {")
    for case_name, _, _ in entries:
        lines.append(f"    case {case_name}")
    lines.append("}\n")
    lines.append("public enum LocalizedStrings {")
    lines.append("    private static let table: [LK: [AppLanguage: String]] = [")
    for case_name, zh, en in entries:
        lines.append(f"        .{case_name}: [.zhHans: {swift_string_literal(zh)}, .en: {swift_string_literal(en)}],")
    lines.append("    ]\n")
    lines.append("    public static func text(_ key: LK, language: AppLanguage) -> String {")
    lines.append("        table[key]?[language] ?? table[key]?[.zhHans] ?? key.rawValue")
    lines.append("    }\n")
    lines.append("    /// 反向查找:给一段中文原文(可能带动态后缀,如\"返回格式异常:未知工具 xxx\"),")
    lines.append("    /// 找最长匹配的已知前缀并把那一段替换成英文,后缀(工具名/HTTP 码等技术细节)")
    lines.append("    /// 保留原样不翻译。用于 DeepSeekError 这类把中文文案直接存进关联值的场景——")
    lines.append("    /// 没有对应表项时原样返回,不报错、不崩溃。")
    lines.append("    private static let zhToEn: [(zh: String, en: String)] = table.values.compactMap { pair in")
    lines.append("        guard let zh = pair[.zhHans], let en = pair[.en] else { return nil }")
    lines.append("        return (zh, en)")
    lines.append("    }.sorted { $0.zh.count > $1.zh.count }\n")
    lines.append("    public static func translate(_ zh: String, language: AppLanguage) -> String {")
    lines.append("        guard language == .en else { return zh }")
    lines.append("        if let exact = zhToEn.first(where: { $0.zh == zh }) { return exact.en }")
    lines.append("        for (zhPrefix, enPrefix) in zhToEn where zh.hasPrefix(zhPrefix) {")
    lines.append("            return enPrefix + zh.dropFirst(zhPrefix.count)")
    lines.append("        }")
    lines.append("        return zh")
    lines.append("    }")
    lines.append("}")

    out = ROOT / "ios" / "LodoCore" / "Sources" / "LodoCore" / "Generated" / "LocalizedStrings.generated.swift"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {len(entries)} keys to {out.relative_to(ROOT)}")


def gen_android_strings_xml(rows):
    zh_entries = []
    en_entries = []
    seen = set()
    for row in rows:
        if row["scope"] not in ANDROID_UI_SCOPES:
            continue
        slug = row["slug"]
        if slug in seen:
            continue
        seen.add(slug)
        name = re.sub(r"[^a-zA-Z0-9_]", "_", slug.replace(".", "_"))
        name = re.sub(r"_+", "_", name).strip("_")
        if name[0].isdigit():
            name = "s_" + name
        zh_entries.append((name, row["zh"]))
        en_entries.append((name, row["en"]))

    def render(entries):
        lines = [GENERATED_HEADER_XML, "<resources>"]
        lines.append('    <string name="app_name">lodo</string>')
        lines.append('    <string name="shortcut_agent_short">AI 助手</string>')
        lines.append('    <string name="shortcut_agent_long">打开 AI 助手</string>')
        lines.append('    <string name="shortcut_add_short">新建</string>')
        lines.append('    <string name="shortcut_add_long">新建事项</string>')
        for name, value in entries:
            lines.append(f'    <string name="{name}">{android_xml_string(value)}</string>')
        lines.append("</resources>")
        return "\n".join(lines) + "\n"

    zh_out = ROOT / "android" / "app" / "src" / "main" / "res" / "values" / "strings.xml"
    en_out = ROOT / "android" / "app" / "src" / "main" / "res" / "values-en" / "strings.xml"
    en_out.parent.mkdir(parents=True, exist_ok=True)
    zh_out.write_text(render(zh_entries), encoding="utf-8")
    en_out.write_text(render(en_entries), encoding="utf-8")
    print(f"wrote {len(zh_entries)} keys to {zh_out.relative_to(ROOT)} / {en_out.relative_to(ROOT)}")


def gen_android_core_kotlin(rows):
    entries = []
    seen = set()
    for row in rows:
        if row["scope"] not in ANDROID_CORE_SCOPES:
            continue
        slug = row["slug"]
        if slug in seen:
            continue
        seen.add(slug)
        entries.append((slug, row["zh"], row["en"]))

    lines = [GENERATED_HEADER_KOTLIN]
    lines.append("package com.lodo.app.core\n")
    lines.append("/** 语言;不依赖 Android Context,core/ai/notify 包内显式传参用。 */")
    lines.append("enum class Lang { ZH, EN }\n")
    lines.append("/** 生成表:core/ai/notify 包(不能 import Android 类)的非资源文本查找。 */")
    lines.append("object Strings {")
    lines.append("    private val table: Map<String, Map<Lang, String>> = mapOf(")
    for slug, zh, en in entries:
        lines.append(
            f"        {kotlin_string_literal(slug)} to mapOf("
            f"Lang.ZH to {kotlin_string_literal(zh)}, Lang.EN to {kotlin_string_literal(en)}),"
        )
    lines.append("    )\n")
    lines.append("    fun of(key: String, lang: Lang): String =")
    lines.append("        table[key]?.get(lang) ?: table[key]?.get(Lang.ZH) ?: key\n")
    lines.append("    /** 反向查找:给一段中文原文(可能带动态后缀),找最长匹配的已知前缀并")
    lines.append("     * 把那一段替换成英文,后缀(工具名/HTTP 码等技术细节)保留原样不翻译。")
    lines.append("     * 用于 DeepSeekException 这类把中文文案直接构造进异常消息的场景——")
    lines.append("     * 没有对应表项时原样返回,不报错、不崩溃。 */")
    lines.append("    private val zhToEn: List<Pair<String, String>> by lazy {")
    lines.append("        table.values.mapNotNull { pair ->")
    lines.append("            val zh = pair[Lang.ZH]; val en = pair[Lang.EN]")
    lines.append("            if (zh != null && en != null) zh to en else null")
    lines.append("        }.sortedByDescending { it.first.length }")
    lines.append("    }\n")
    lines.append("    fun translate(zh: String, lang: Lang): String {")
    lines.append("        if (lang != Lang.EN) return zh")
    lines.append("        zhToEn.firstOrNull { it.first == zh }?.let { return it.second }")
    lines.append("        zhToEn.firstOrNull { zh.startsWith(it.first) }?.let { (zhPrefix, enPrefix) ->")
    lines.append("            return enPrefix + zh.substring(zhPrefix.length)")
    lines.append("        }")
    lines.append("        return zh")
    lines.append("    }")
    lines.append("}")

    out = ROOT / "android" / "app" / "src" / "main" / "java" / "com" / "lodo" / "app" / "core" / "Strings.generated.kt"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {len(entries)} keys to {out.relative_to(ROOT)}")


def main():
    rows = load_rows()
    gen_xcstrings(rows)
    gen_ios_core_swift(rows)
    gen_android_strings_xml(rows)
    gen_android_core_kotlin(rows)


if __name__ == "__main__":
    main()
