#!/usr/bin/env python3
"""生成 lodo 键盘的拼音词库 PinyinLexicon.bin。

源数据不进仓库,先下载到一个空目录里再跑(都只用标准库,`python3 -I` 运行):

    aosp/rawdict.txt   AOSP PinyinIME jni/data/rawdict_utf16_65105_freq.txt
                       (googlesource 的 ?format=TEXT,base64 包着的 UTF-16LE)  Apache-2.0
    jieba/dict.txt     fxsjy/jieba jieba/dict.txt                                  MIT
    ppd/pinyin.txt     mozillazg/phrase-pinyin-data pinyin.txt                     MIT
    pd/pinyin.txt      mozillazg/pinyin-data pinyin.txt                            MIT

    python3 -I ios/Tools/build_ime_dict.py <源目录> ios/LodoIME/Sources/LodoIME/Resources/PinyinLexicon.bin

词频口径:每个来源各自归一成 ln(p),两个来源都有的取平均;只有 jieba 有的减一点
(它的长尾是词频 2–3 的专名,没有第二个来源佐证)。单字的读音分布用 AOSP 的
逐读音词频(「的」de 远多于 di)。

文件格式(小端)见 LodoIME/Lexicon.swift 的注释,两边改一处要同步改另一处。
"""

import base64
import math
import os
import struct
import sys
import unicodedata

# 叹词音节和声母简拼冲突(「n」既是「嗯」又是 n 开头的简拼),不收。
EXCLUDED_SYLLABLES = {"hm", "hng", "m", "n", "ng"}
MAX_WORD_CHARS = 8
JIEBA_ONLY_PENALTY = 1.0
# jieba 词频 ≤ 5 的多是专名长尾,只有一个来源又没有佐证:整键能打出来,但别在拼整句时抢位置。
JIEBA_RARE_COUNT = 5
JIEBA_RARE_PENALTY = 2.5

DIGITS = [("一", "yi"), ("二", "er"), ("三", "san"), ("四", "si"), ("五", "wu"),
          ("六", "liu"), ("七", "qi"), ("八", "ba"), ("九", "jiu")]
# 数词后面常跟的量词/单位。「十点」「五号」「三个」不在任何词库里,单字拼又会输给「试点」「唔好」。
MEASURES = [("点", "dian"), ("号", "hao"), ("个", "ge"), ("张", "zhang"), ("杯", "bei"),
            ("瓶", "ping"), ("块", "kuai"), ("本", "ben"), ("次", "ci"), ("天", "tian"),
            ("年", "nian"), ("月", "yue"), ("岁", "sui"), ("遍", "bian"), ("位", "wei"),
            ("件", "jian"), ("份", "fen"), ("碗", "wan"), ("步", "bu"), ("层", "ceng"),
            ("楼", "lou"), ("周", "zhou"), ("分", "fen"), ("元", "yuan"), ("斤", "jin"),
            ("公里", "gong li"), ("分钟", "fen zhong"), ("小时", "xiao shi"), ("星期", "xing qi")]


def is_han(s):
    return all("一" <= c <= "鿿" or "㐀" <= c <= "䶿" for c in s)


def normalize_syllable(raw):
    """带调拼音 → 键盘拼写:去声调,ü → v,lüe/nüe 按习惯写 lue/nue。"""
    s = unicodedata.normalize("NFD", raw.strip().lower())
    s = s.replace("ü", "v")
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.replace("ü", "v")
    if s in ("lve", "nve"):
        s = s[0] + "ue"
    return s


def read_aosp(path):
    raw = open(path, "rb").read()
    try:
        data = base64.b64decode(raw, validate=True)
    except Exception:
        data = raw
    text = data.decode("utf-16-le" if not data.startswith(b"\xff\xfe") else "utf-16")
    rows = []
    for line in text.splitlines():
        parts = line.lstrip("﻿").split()
        if len(parts) < 4:
            continue
        word, freq, _flag, syllables = parts[0], float(parts[1]), parts[2], parts[3:]
        rows.append((word, freq, syllables))
    return rows


def read_jieba(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        parts = line.split()
        if len(parts) >= 2 and is_han(parts[0]):
            out[parts[0]] = out.get(parts[0], 0) + int(parts[1])
    return out


def read_colon_pinyin(path):
    """pinyin-data(U+XXXX: 读音,…  # 字)与 phrase-pinyin-data(词: 音 音)两种格式。"""
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.split("#")[0].strip()
        if not line or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        if key.startswith("U+"):
            ch = chr(int(key[2:], 16))
            out[ch] = [normalize_syllable(v) for v in value.split(",") if v.strip()]
        else:
            out[key] = [normalize_syllable(v) for v in value.split()]
    return out


def main(src, dest):
    aosp = read_aosp(os.path.join(src, "aosp/rawdict.txt"))
    syllables = sorted({s for _, _, ss in aosp for s in ss} - EXCLUDED_SYLLABLES)
    valid = set(syllables)

    jieba = read_jieba(os.path.join(src, "jieba/dict.txt"))
    phrases = read_colon_pinyin(os.path.join(src, "ppd/pinyin.txt"))
    chars = read_colon_pinyin(os.path.join(src, "pd/pinyin.txt"))

    aosp_total = sum(f for w, f, _ in aosp)
    jieba_total = sum(jieba.values())

    # 单字各读音的份额(AOSP 逐读音计数),用来给没有现成注音的词挑读音。
    char_reading = {}
    for w, f, ss in aosp:
        if len(w) == 1 and ss[0] in valid:
            char_reading.setdefault(w, {})
            char_reading[w][ss[0]] = char_reading[w].get(ss[0], 0) + f

    def dominant_reading(ch):
        readings = char_reading.get(ch)
        if readings:
            total = sum(readings.values())
            best = max(readings, key=readings.get)
            if readings[best] / total >= 0.85:
                return best
        alts = [r for r in dict.fromkeys(chars.get(ch, [])) if r in valid]
        if len(alts) == 1:
            return alts[0]
        return None

    # (词, 拼音元组) → ln p
    entries = {}

    def put(word, pys, logp):
        key = (word, tuple(pys))
        if key not in entries or entries[key] < logp:
            entries[key] = logp

    known_pinyin = {}
    for w, f, ss in aosp:
        if not is_han(w) or any(s not in valid for s in ss) or len(ss) != len(w):
            continue
        lp_a = math.log(f / aosp_total)
        if len(w) > 1:
            known_pinyin.setdefault(w, set()).add(tuple(ss))
            if w in jieba:
                lp = (lp_a + math.log(jieba[w] / jieba_total)) / 2
            else:
                lp = lp_a
        else:
            lp = lp_a
        put(w, ss, lp)

    for w, ss in phrases.items():
        if is_han(w) and len(w) == len(ss) and all(s in valid for s in ss):
            known_pinyin.setdefault(w, set()).add(tuple(ss))

    min_jieba = math.log(min(jieba.values()) / jieba_total) - JIEBA_ONLY_PENALTY
    dropped = 0
    derived = 0
    for w, count in jieba.items():
        if len(w) < 2 or len(w) > MAX_WORD_CHARS:
            continue
        lp = math.log(count / jieba_total) - JIEBA_ONLY_PENALTY
        if count <= JIEBA_RARE_COUNT:
            lp -= JIEBA_RARE_PENALTY
        readings = known_pinyin.get(w)
        if readings:
            if not any((w, r) in entries for r in readings):
                for r in readings:
                    put(w, r, lp)
            continue
        # 没有现成注音:先按已知词最长匹配,剩下的字只认读音明确的。
        pys, i, ok = [], 0, True
        while i < len(w):
            for j in range(min(len(w), i + 4), i + 1, -1):
                sub = w[i:j]
                if sub in known_pinyin:
                    pys.extend(sorted(known_pinyin[sub])[0])
                    i = j
                    break
            else:
                r = dominant_reading(w[i])
                if r is None:
                    ok = False
                    break
                pys.append(r)
                i += 1
        if ok:
            put(w, pys, lp)
            derived += 1
        else:
            dropped += 1

    # 只在注音库里有的成语/词:给 jieba 的最低词频。
    for w, rs in known_pinyin.items():
        if len(w) <= MAX_WORD_CHARS and not any((w, r) in entries for r in rs):
            for r in rs:
                put(w, r, min_jieba)

    # 数词(1–99、整百整千)和「数词 + 量词」。
    numerals = []
    for d, py in DIGITS:
        numerals.append((d, [py]))
    numerals.append(("十", ["shi"]))
    for d, py in DIGITS:
        numerals.append(("十" + d, ["shi", py]))
        numerals.append((d + "十", [py, "shi"]))
        for e, epy in DIGITS:
            numerals.append((d + "十" + e, [py, "shi", epy]))
    for d, py in DIGITS + [("两", "liang")]:
        for unit, upy in (("百", "bai"), ("千", "qian"), ("万", "wan")):
            numerals.append((d + unit, [py, upy]))
    number_lp = math.log(2000 / jieba_total)
    for text, pys in numerals:
        if len(text) > 1:
            put(text, pys, number_lp)
    counters = [(t, p) for t, p in numerals if len(t) <= 2] + [("两", ["liang"]), ("几", ["ji"]), ("半", ["ban"])]
    for text, pys in counters:
        for m, mpy in MEASURES:
            put(text + m, pys + mpy.split(), number_lp)

    # 单字兜底:pinyin-data 里有、AOSP 没收的读音,给很低的分。
    for ch, rs in chars.items():
        if not is_han(ch):
            continue
        for r in dict.fromkeys(rs):
            if r in valid and (ch, (r,)) not in entries:
                put(ch, (r,), min_jieba - 2)

    index = {s: i for i, s in enumerate(syllables)}
    rows = []
    for (word, pys), lp in entries.items():
        cost = min(65535, max(0, int(round(-lp * 100))))
        rows.append((tuple(index[p] for p in pys), cost, word.encode("utf-8")))
    rows.sort()

    blob = bytearray()
    offsets = []
    for ids, cost, word in rows:
        offsets.append(len(blob))
        blob += struct.pack("<B", len(ids))
        blob += struct.pack(f"<{len(ids)}H", *ids)
        blob += struct.pack("<HB", cost, len(word))
        blob += word

    syllable_blob = "\0".join(syllables).encode("ascii")
    out = bytearray(b"LDIM")
    out += struct.pack("<III", 1, len(syllables), len(syllable_blob))
    out += syllable_blob
    while len(out) % 4:
        out += b"\0"
    out += struct.pack("<II", len(rows), len(blob))
    out += struct.pack(f"<{len(offsets)}I", *offsets)
    out += blob
    with open(dest, "wb") as fh:
        fh.write(out)

    print(f"syllables={len(syllables)} entries={len(rows)} derived={derived} "
          f"dropped={dropped} bytes={len(out)}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
