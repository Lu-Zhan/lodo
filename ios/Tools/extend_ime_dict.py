#!/usr/bin/env python3
"""合入人工常用语料；用法: python3 -I extend_ime_dict.py dictionary.bin [--check]。

幂等合并保留已有的更高词频。删除条目或降低词频时应运行完整 build_ime_dict.py。
"""
import argparse
from pathlib import Path
import struct


def extend(path, check=False):
    data = path.read_bytes()
    assert data[:4] == b"LDIM"
    version, count, size = struct.unpack_from("<III", data, 4)
    assert version == 1
    names = data[16:16 + size].decode("ascii").split("\0")
    assert len(names) == count
    index = {name: i for i, name in enumerate(names)}
    start = (16 + size + 3) & ~3
    count, blob_size = struct.unpack_from("<II", data, start)
    blob_start = start + 8 + count * 4
    assert blob_start + blob_size == len(data)
    rows = {}
    for i in range(count):
        offset, = struct.unpack_from("<I", data, start + 8 + i * 4)
        at = blob_start + offset
        n = data[at]
        ids = struct.unpack_from(f"<{n}H", data, at + 1)
        cost, length = struct.unpack_from("<HB", data, at + 1 + n * 2)
        word = data[at + 4 + n * 2:at + 4 + n * 2 + length]
        rows[(ids, word)] = cost
    corpus = Path(__file__).resolve().parents[1] / "LodoIME/Tests/LodoIMETests/Fixtures/common-phrases.tsv"
    seen = set()
    costs = {"poetry": 950, "idiom": 900, "phrase": 850}
    for line in corpus.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        category, word, pinyin = line.split("\t")
        syllables = pinyin.split()
        assert 1 <= len(word) == len(syllables) <= 16, word
        assert all("\u4e00" <= ch <= "\u9fff" for ch in word), word
        key = (tuple(index[s] for s in syllables), word.encode())
        assert key not in seen, word
        seen.add(key)
        rows[key] = min(rows.get(key, 65535), costs[category])
    blob = bytearray()
    offsets = []
    for ids, cost, word in sorted((ids, cost, word) for (ids, word), cost in rows.items()):
        offsets.append(len(blob))
        blob += struct.pack("<B", len(ids)) + struct.pack(f"<{len(ids)}H", *ids)
        blob += struct.pack("<HB", cost, len(word)) + word
    output = data[:start] + struct.pack("<II", len(rows), len(blob))
    output += struct.pack(f"<{len(offsets)}I", *offsets) + blob
    if check:
        if output != data:
            raise SystemExit("词库与常用语料不同步，请重新生成")
    else:
        path.write_bytes(output)
    print(f"curated={len(seen)} entries={len(rows)} bytes={len(output)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dictionary", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    extend(args.dictionary, args.check)
