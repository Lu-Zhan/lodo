# LodoIME 第三方许可

键盘的设置页「致谢」照这份写;改动来源时两边一起改。

## 词库 `Sources/LodoIME/Resources/PinyinLexicon.bin`

由 `ios/Tools/build_ime_dict.py` 从下面四份数据合并生成,源数据不进仓库:

| 来源 | 许可 | 用途 |
|---|---|---|
| AOSP PinyinIME `rawdict_utf16_65105_freq.txt` | Apache-2.0 | 基础词表与词频 |
| jieba `dict.txt`(fxsjy/jieba) | MIT | 扩充词量与词频 |
| mozillazg/phrase-pinyin-data | MIT | 词语注音 |
| mozillazg/pinyin-data | MIT | 单字读音 |

另含项目人工整理的 408 条古典诗句、成语及日常短语,拼音见
`Tests/LodoIMETests/Fixtures/common-phrases.tsv`。古诗采用古典原文,不含现代译注。
完整生成脚本会自动合入这些条目;已有基础词库可增量更新:

```bash
python3 -I ios/Tools/extend_ime_dict.py ios/LodoIME/Sources/LodoIME/Resources/PinyinLexicon.bin
python3 -I ios/Tools/extend_ime_dict.py ios/LodoIME/Sources/LodoIME/Resources/PinyinLexicon.bin --check
```

增量合并保留已有更高词频;删除条目或降低词频需从原始数据完整重建。
语料仅在构建时合并,键盘运行时仍查询同一份映射词库,不额外扫描文本文件。

## 常用字表 `Sources/LodoIME/CommonCharacters.swift`

《通用规范汉字表》(国务院 2013 年公布)全部 8105 字,取自
jaywcjlove/table-of-general-standard-chinese-characters 的 `data/characters.txt`,MIT,
Copyright (c) 2026 小弟调调。只用来给表外单字降权,不改词库。

## 快捷输入 `Sources/LodoIME/QuickPhrases.swift`

rq / sj / xq / nl 出日期、时间、星期、农历,思路参考雾凇拼音(iDvel/rime-ice,GPL-3.0),
代码和数据都是自己写的,没有拿它的任何文件。

## 重排器 `Reranker/`、`Sources/LodoReranker/Resources/pinyin-ime-reranker-4M.safetensors`

- 推理代码:chinese-ime-lm `reference/`(commit b97e99cb),Apache-2.0,许可全文见 `Reranker/LICENSE-chinese-ime-lm`。
  `Reranker/ffi/` 是 lodo 写的 C ABI 包装,同样 Apache-2.0。
- 权重:chinese-ime-lm `model-v1` release 的 `sentence-model.safetensors`(= Hugging Face `pinyin-ime-reranker-4M`),
  Apache-2.0,sha256 `86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1`。
- 语料署名(写在权重头 `__metadata__.attribution` 里,**再分发必须保留**,`ModelReranker.attribution` 读得到):
  Trained on the Chinese portion of C4 (ODC-BY, https://huggingface.co/datasets/allenai/c4) and LCCC (MIT, https://github.com/thu-coai/CDial-GPT).
