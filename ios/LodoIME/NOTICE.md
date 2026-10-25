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

## 重排器 `Reranker/`、`Sources/LodoReranker/Resources/pinyin-ime-reranker-4M.safetensors`

- 推理代码:chinese-ime-lm `reference/`(commit b97e99cb),Apache-2.0,许可全文见 `Reranker/LICENSE-chinese-ime-lm`。
  `Reranker/ffi/` 是 lodo 写的 C ABI 包装,同样 Apache-2.0。
- 权重:chinese-ime-lm `model-v1` release 的 `sentence-model.safetensors`(= Hugging Face `pinyin-ime-reranker-4M`),
  Apache-2.0,sha256 `86ac529510cb3b4968a5e6ade83ec8080f5b34a0a681e75c362accbbd387d1c1`。
- 语料署名(写在权重头 `__metadata__.attribution` 里,**再分发必须保留**,`ModelReranker.attribution` 读得到):
  Trained on the Chinese portion of C4 (ODC-BY, https://huggingface.co/datasets/allenai/c4) and LCCC (MIT, https://github.com/thu-coai/CDial-GPT).
