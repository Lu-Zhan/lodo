# lodo 键盘 v2:好用的中英文输入 + AI 键 + 快速记录(仅 iOS)

## Context

用户想给 lodo 加一个"好用的"中/英文键盘,并能在键盘上直接用到 lodo。2026-09 做过一版(`dde3727` 加、`699aa63` 删),CLAUDE.md 写着"别再加回来"——用户这次明确要重做,删掉的原因是:**打字体验太差、维护成本高、AI 面板不好用**。新版要逐条避开这三点。

### 调研:metasequoiaime/chinese-ime-lm 是什么

- **不是完整输入法,只是"候选重排器"**:字级 Transformer,在拼音解码器已经拼装出的候选之间挑一个。拼音切分、词库、解码都要自己做。
- 发布的权重(**Apache-2.0**):`pinyin-ime-reranker-4M`(4.5 MB,按键路径 p95 8.6 ms)、`25M`(25.5 MB,停顿时用)。语料 C4(ODC-BY)+ LCCC(MIT),署名写在 safetensors `__metadata__.attribution` 里,再分发必须保留 → 设置页「致谢」加一条。
- 推理参考实现 `reference/`:Rust,**Apache-2.0**,无 unsafe,只依赖 serde/serde_json/thiserror,rust 1.75。仓库其余部分 GPL-3.0(不碰)。
- **实测结论决定了怎么接**(docs/measurements.md):
  - 词典对整个键的精确命中(带词频)**别让模型覆盖**——任何权重都掉分(0.719 → ≤0.690)。
  - 模型价值只在**解码器拼装的整句候选**上(0.000 → 0.189;整句集 41 → 49/52)。
  - 门控 API:`Reranker::best_where(已上屏文本, 候选, |i| CandidateFacts { answers_key, trusted_dictionary_hit })`,两个事实由引擎自己算:候选是否吃满当前键、是否为未经纠错的词典命中。
  - 只有覆盖整个键的候选之间可比(别按字数筛,`xian` 的「现」和「西安」都覆盖全键)。
- 结论:**打字好不好用,大头在词库 + 切分/解码 + 用户学习;重排器是锦上添花**,用在整句拼装上。
- MSIME 主仓库有现成 iOS 键盘,但 GPL-3.0,不用。

### 调研:现成 iOS 键盘(代码 + UI/UX 参考)

| 项目 | 许可 | 能怎么用 |
|---|---|---|
| **仓输入法 Hamster**(imfuxiao/Hamster,★1.6k) | **MIT**(v2.1.0 起;此后闭源商业化,最后开源推送 2025-05) | **键盘 UI 层直接拿来用**:`Packages/HamsterKeyboardKit` = 早期 MIT 版 KeyboardKit 的 fork + 中文键盘视图(UIKit 按键、callout 长按气泡、手势、触感/音效反馈、候选栏 `CandidateWords`、分类符号键盘、中英状态切换)。引擎是 librime,要换成 LodoIME 的适配层。 |
| KeyboardKit(★1.9k) | 现为**闭源**商业许可 | 不用新版;Hamster 里那份是它变闭源前的 MIT 代码(保留其 LICENSE) |
| 水杉 MSIME iOS 宿主 / fcitx5-ios / 鼠须管 | GPL-3.0 | **只看交互、不抄代码** |
| 系统键盘 | — | 按键尺寸、间距、圆角、按下气泡、空格滑动移光标——布局度量的基准 |
| 微信输入法 / 搜狗 / 百度 / Gboard / 落格(闭源) | — | UX 参考:微信输入法的「问 AI」面板与剪贴板;Gboard 候选栏工具条;落格的极简视觉 |

结论:**UI 不再自己从零写**(旧版 761 行 SwiftUI 自绘是"维护成本高"的主因),以 HamsterKeyboardKit 为底子做 vendored fork。

## 方案总览

新建三块:
1. `ios/LodoIME/` —— 纯 Swift SPM 包(拼音引擎,无 UIKit),独立 `swift test`。不塞进 LodoCore(LodoCore 要编 watchOS,词库与引擎跟它无关)。
2. `ios/LodoIME/Reranker/` —— chinese-ime-lm `reference/` 的 C ABI 包装 crate + 构建脚本,产出 `LodoReranker.xcframework`(iOS 真机 + 模拟器 arm64)。**可选依赖**:引擎在没有它时也完整可用。
3. `LodoKeyboardExtension` target(`ios/LodoKeyboard/` 文件夹同步组)+ 主 app 侧 `KeyboardBridge`。

## 第 0 步:词库与许可核实(动手前先做)

候选词库来源(都要逐个打开 LICENSE 核实后再用,结论写进 `ios/LodoKeyboard/NOTICE.md`):
- AOSP Google 拼音 `rawdict_utf16_65105_freq.txt`(Apache-2.0,约 6.5 万词带词频)——基础。
- jieba `dict.txt`(MIT,约 35 万词带词频)——扩充词量与词频。
- mozillazg `phrase-pinyin-data` / `pinyin-data`(MIT)——给 jieba 词注音、多音字。
- 不用雾凇/rime-ice(GPL-3)、不用维基派生语料。

生成工具 `ios/Tools/build_ime_dict.py`(离线跑,源数据不进仓库,只提交产物):合并、去重、词频归一成 log 概率、过滤生僻/脏词,产出紧凑二进制 `PinyinLexicon.bin`(按音节键排序 + 首音节索引,`Data(.alwaysMapped)` 映射读取,不整份进内存)。目标 25–35 万词、≤ 10 MB。

## 第 1 步:拼音引擎 `LodoIME`(解决"打字体验差")

旧版只有 6800 条、最少切段贪心,这是体验差的根源。新版:

- **音节表**写死完整 ~410 个全拼音节(不从词库反推)。
- **切分成词图**:列出键的所有合法切分(`xian` → xian / xi'an),`'` 强制分段,末段允许不完整音节(前缀补全)。
- **简拼**:声母简拼(`zg`→中国、`zhg`、`bjdx`→北京大学)混合全拼。
- **模糊音**(设置开关,默认关):z/zh c/ch s/sh n/l in/ing en/eng an/ang。
- **纠错**:相邻键误触、`ign`↔`ing` 类交换;纠错产生的候选标 `correctedFrom`(重排器门控要用)。
- **解码**:词图上 Viterbi(词频 log 概率 + 切分惩罚),出 top-k 整句;候选顺序:用户词 → 全键词典命中 → 整句拼装 → 前缀词 → 单字。
- **重排门控**严格照 measurements.md:只对 `answersKey == true` 的候选比;`trustedDictionaryHit`(词典来源且未纠错)的首选不让模型覆盖;只有首选是拼装/回退来的才调重排器。键入路径用 4M,输入停顿 ~300 ms 后不跑 25M(体积和内存不划算,先不打包)。
- **用户学习**:上屏的词/整句计数加权(带衰减),存键盘自己的容器(不需要完全访问)。
- **英文**:英文模式用 `UITextChecker` 补全 + `requestSupplementaryLexicon`;中文模式下候选栏第一格永远保留原始字母串(可直接上英文),键入串命中英文词表时额外给一个英文候选(`iphone` → iPhone)。
- **评测**:`LodoIMETests` 单测 + 可选基准 `LODO_IME_EVAL=1 swift test --filter IMEEvalTests`:
  - 下载 chinese-ime-lm `eval/quanpin-words-v1.tsv`(2.5 万词级)与 `sentences-v1.tsv`(60 整句)到临时目录跑,**不提交进仓库**;报 top-1/top-3,救回与弄坏分开报。
  - 另写一份 lodo 自己的 200 句日常句(含 lodo 场景:提醒、航班、地址)提交进测试资源。
  - 验收线:词级 top-1 ≥ 0.70(对标 MSIME 引擎 0.719),整句有重排比无重排不弄坏。

## 第 2 步:重排器接入

- `ios/LodoIME/Reranker/ffi/`:一个小 crate 依赖上游 `reference/`(git 固定 commit),导出 `lodo_rr_load(path) / lodo_rr_best_where(ctx, candidates, facts) / lodo_rr_free`。
- `ios/Tools/build_reranker.sh`:`cargo build --target aarch64-apple-ios / aarch64-apple-ios-sim` → `xcodebuild -create-xcframework`;产物提交进仓库(体积小),本机不装 Rust 也能编 app。
- 权重 `pinyin-ime-reranker-4M.safetensors` 进键盘扩展资源;不同步、不下载。
- Swift 侧 `Reranker` 协议 + `NoopReranker`,单测用假实现,引擎逻辑不依赖 xcframework。
- 实测键盘扩展内存(目标常驻 < 40 MB)与单次决策延迟(< 15 ms),超了就只在停顿时重排。

## 第 3 步:键盘 UI(解决"维护成本高")

- **把 Hamster 2.1.0 的 `Packages/HamsterKeyboardKit` vendored 进 `ios/LodoKeyboardKit/`**(固定 tag,保留 Hamster 与 KeyboardKit 两份 MIT LICENSE,`NOTICE.md` 署名):
  - 留:UIKit 按键视图、布局 provider、callout、手势(滑动换键、删除加速、空格移光标)、反馈、候选栏、符号键盘、Appearance。
  - 删:Rime 相关(RimeContext、方案部署、Runestone 编辑器、GCDWebServer/ZIPFoundation 等 Hamster 主 app 用的依赖)、九宫格/双拼/自定义方案配置(第一版只做全拼 26 键)。
  - 加:`LodoIMEInputEngine` 适配层,把 HamsterKeyboardKit 原来调 Rime 的接口(输入键、取候选、选候选、上屏)接到 LodoIME。
  - 第 0 步先花半天确认 Rime 耦合有多深;如果 View 层和 RimeContext 缠得太紧,退回"只借鉴它的按键/callout/手势代码,外壳自己写"。
- 布局:候选栏(横排 + 下拉展开全部)/ 26 键全拼 / 123 / #+= / 中英文标点切换 / 深浅色 / iPhone + iPad 尺寸。
- **Hamster 的外观是 iOS 15 时代的系统键盘(带阴影的白键)**,Appearance 层整个重写成 iOS 27 风格,见下一节。

### iOS 27 Apple 设计(用户要求)

SDK 核实(本机 iPhoneOS 27.0 SDK):**没有给键盘扩展的新 API**;能用的是 iOS 26 起的 `UIGlassEffect`(regular/clear、`isInteractive`、`tintColor`)、`UIGlassContainerEffect`(相邻玻璃合并,`spacing`)、`UIButton.Configuration.glass()/prominentGlass()`。所以"像 iOS 27 系统键盘"靠我们自己用这几样还原,**风格基准 = iOS 27 模拟器/真机上系统中文键盘的截图**(量按键尺寸、行距、圆角、字号、按下状态,写进 `KeyboardMetrics`,不凭印象写数)。

HIG 原文约束(apple-hig,2026-09-12 快照)与落地:
| HIG | 落地 |
|---|---|
| 「Use Liquid Glass for controls and navigation … floating above content」;「Use Liquid Glass effects sparingly on custom controls」 | **整块键盘底板一层 `UIGlassEffect(.regular)`**;按键本身**不各套一块玻璃**,用 vibrancy 填充(`UIVibrancyEffect` 的 fill/secondaryFill)做平面圆角键,同系统键盘的做法;候选栏与键区在同一块玻璃里 |
| 「Use regular when … components contain significant text, such as alerts, sidebars, or popovers」 | 长按气泡、候选展开页、AI 面板、快速记录面板用 regular 玻璃;不用 clear |
| 「appearance can change with preferred-look, reduced-transparency, and increased-contrast settings」 | 减弱透明度 → 不透明系统键盘底色;增强对比度 → 键加描边;沿用 app 里 `DesignMetrics.reducesTransparency` 的判断口径 |
| 「Use system-defined vibrant colors over any material」 | 键帽字用 vibrancy label,不写死黑白;强调色(✨/记 键、选中候选)用 `lodoAccent` 的 accent 值 |
| 「Provide an obvious, easy way to switch keyboards」;「Avoid duplicating system keyboard features … Emoji/Globe and Dictation keys automatically appear beneath」 | 只在 `needsInputModeSwitchKey == true` 时画 🌐 键(`handleInputModeList`);**不做自己的听写键** |
| 「Play the standard keyboard sound while people type (`playInputClick()`)」 | 输入视图实现 `UIInputViewAudioFeedback`,按键调 `playInputClick()` |
| 「Consider an in-app keyboard tutorial … Avoid help content within the keyboard itself」 | 启用说明/完全访问说明放在 app 设置页「lodo 键盘」里;键盘里只留一行"需要在设置里开启完全访问"的状态提示 |

- 门控:部署目标保持 iOS 17,`#available(iOS 26)` 用玻璃,更早系统回退 `UIBlurEffect` + 实心键;封装收进 `KeyboardAppearance` 一处,和 app 里 `LiquidGlass.swift` 同一套约定;留 `#available(iOS 27)` 分支位置给真机比对后需要的差异。
- 动效:按下/抬起、气泡弹出用临界阻尼弹簧,不回弹(同 app 的 `PressFeedback` 口径);减弱动态效果时关掉气泡缩放。
- 第 0 步先验证一件事:iOS 27 上第三方键盘把 inputView 背景设透明时,系统会不会自己垫一层键盘背板(会的话就不再叠我们自己的底板玻璃,避免玻璃叠玻璃)。
- **自绘按键是 UI 例外**,写进 CLAUDE.md 与 `ContactGraphView` 并列,注明不能当先例。
- 维护面收窄:键盘 target 只有 引擎桥 + 键盘视图 + 两个 lodo 功能;**不镜像主 app 的整套 AI 能力**。

## 第 4 步:lodo 功能(解决"AI 面板不好用")

需要「允许完全访问」(App Group 读写、联网);没开时这两颗键说明原因,打字本身不受影响。

**快速记录(候选栏左侧「记」)**——不走 AI、离线可用、零等待:
- 取文字:选中文字(`documentProxy.selectedText`)→ 否则剪贴板 → 否则弹一行输入框。
- 两个按钮:**存为任务** = `ParsedTask.asInbox`(进「收集」,不定时间、不提醒)写 `Keyboard/Tasks/<uuid>.json`;**存为记忆** = 写现有 `Memory/Inbox`(app 里照常 AI 整理)。
- 结果一行「已存进 lodo 收集,打开 lodo 后入库 · 撤销」(撤销 = 删掉还没被消费的那个文件)。

**AI 键(候选栏左侧 ✨)**——只做一件事:**问 lodo,答案插进当前输入框**:
- 一行问题框 → `DeepSeekClient.command`,能力只开 记忆检索(`search_memory` 在快照上跑 `MemorySearch.rank`)+ `answer`/`ask_memory`;`create`/`memorize` 一类写操作按快速记录同一个收件箱落地;其他动作(修改/删除/行程…)一行「这个去 lodo 里做」,不做卡片、不做确认清单。
- 结果只有一张:正文 + 「插入」(`insertText`)+「复制」;`ask` 只取第一题的选项做成胶囊(同 Watch)。
- 关思考(`thinking: false`),追求速度;流式复用 `AgentStream`。

**主 app 侧**(以旧版 `git show dde3727:ios/Lodo/Core/KeyboardBridge.swift` 为底子改):
- `KeyboardBridge.writeSnapshot`:回前台/进后台写 `keyboard-snapshot.json`(记忆标题/摘要/标签/摘录 + 未完成任务标题)。**隐私过滤沿用 Spotlight/AI 出口的口径**:健康、体检、用药、经期、资产(且尊重「AI 与资产隔离」)一律不进。
- AI 设置镜像:服务商/模型/端点/内置 key 开关/语言写进 App Group;API key 走钥匙串共享组(主 app 与扩展都加 `keychain-access-groups`)。
- 收件箱消费:把 `AppGroup.consumeKeyboardLeftovers`(`ios/Lodo/Core/WidgetBridge.swift:32`)改成常驻的 `consumeKeyboardInbox`——**不再删 `Keyboard/` 目录和快照**,只删处理过的文件;复用 `TaskActions.create` + `WidgetBridge.sync`/`CalendarSync.sync`。调用点 `ContentView.swift:40` 保留,另挂 `RoutineRunner` 后台刷新。
- 设置页「lodo 键盘」一行:启用步骤、完全访问说明、模糊音开关、致谢(chinese-ime-lm 署名 + 词库许可)。

## 关键文件

- 新:`ios/LodoIME/`(Package.swift、Sources/LodoIME/{Syllables,Lattice,Decoder,Lexicon,UserDictionary,Reranker}.swift、Tests)、`ios/LodoIME/Reranker/ffi/`、`ios/Tools/build_ime_dict.py`、`ios/Tools/build_reranker.sh`
- 新:`ios/LodoKeyboardKit/`(vendored HamsterKeyboardKit,裁剪 + `LodoIMEInputEngine` 适配层)
- 新:`ios/LodoKeyboard/`(KeyboardViewController、QuickRecordPanel、AskPanel、资源、NOTICE.md)、`ios/Support/LodoKeyboardInfo.plist`、`ios/Support/LodoKeyboard.entitlements`
- 改:`ios/Lodo.xcodeproj/project.pbxproj`(新 target + 本地包 + xcframework)、`ios/Lodo/Core/WidgetBridge.swift`、`ios/Lodo/Views/ContentView.swift`、`ios/Lodo/Views/SettingsView.swift`、`ios/Support/Lodo.entitlements`、`i18n/strings.csv` + `Localizable.xcstrings`(手工按 Xcode 格式插词条,不跑 generate.py)
- 改:`CLAUDE.md`——删掉「iOS 自定义键盘已删除…别再加回来」那段,换成新键盘一节(引擎分层、重排门控规则、隐私过滤、UI 例外、收件箱)

## 分阶段交付(每阶段可停下来看)

1. 词库 + 引擎 + 评测数字(不碰 UI)→ 给用户看 top-1 数字再决定往下走。
2. 重排器 xcframework + 有/无重排对比。
3. 键盘 target(只有打字)→ 真机试打。
4. 快速记录 + AI 键 + 主 app 桥。

## 验证

- `cd ios/LodoIME && swift test`;`LODO_IME_EVAL=1 swift test --filter IMEEvalTests` 出评测报表。
- `cd ios/LodoCore && swift test`(收件箱/快照改动不破坏现有用例)。
- `xcodebuild` 编主 app + 键盘扩展(iOS 模拟器 + 真机 generic)。
- iOS 27 模拟器上和系统中文键盘并排截图(浅色/深色/减弱透明度/增强对比度四种),核对尺寸与材质。
- DEBUG 参数 `--demo-keyboard`:在主 app 里嵌入键盘视图 + 假 `textDocumentProxy`,模拟器上截图核对布局、候选、快速记录、AI 面板(模拟器里启用第三方键盘那一步上次就做不了)。
- 真机才能验的(如实标注):完全访问开关、钥匙串共享、App Group 写入后 app 入库、扩展内存上限、真实打字手感与延迟。

## 进度与偏离(2026-10-24)

- 第 1、2 步完成,数字见 CLAUDE.md「iOS lodo 键盘」一节。
- **Hamster 的许可要以 main 分支为准**:`2.1.0` tag 还是 GPL-3,MIT 是 2025-02-26 的提交 `8ab16ce` 才换的。
- **第 3 步没有 vendor HamsterKeyboardKit**,走了计划里留的退路(自己写外壳):它连同依赖的 HamsterKit/HamsterUIKit 有 3.1 万行,View/Controller 层直接调 `rimeContext` 75 处、`hamsterConfiguration` 铺在 40 多处,外观又是 iOS 15 时代、本来就要整个重写。搬进来要维护的代码远比自己写的多。现在键盘 UI(`LodoKeyboardUI`)约 900 行,判断逻辑在可单测的 `LodoKeyboardModel` 里(连同扩展转接层和 demo 一共约 1500 行);触摸归属(一个视图统一收触摸、按最近键判定、多指快打时先提交前一颗)借鉴了 Hamster/KeyboardKit 的做法,没有拷代码。
- 背板验证("iOS 27 上透明 inputView 系统会不会垫背板")在模拟器上做不了:改 `AppleKeyboards` 偏好后软键盘仍不弹。改用 `UIInputView(.keyboard)` 让系统画背板、我们不叠玻璃,真机上再确认。
- `--demo-keyboard` 没有放进主 app,改成独立的 `LodoKeyboardDemo` target(免得主 app 多背一份词库和模型)。
- 第 4 步完成。和计划不同:AI 的回答盖在键区上(计划里是另起一张卡),键盘只在打开面板那一下长高一行;「偏好」(`remember_preference`)在键盘里静默忽略——偏好文件在主 app 的容器里,扩展写不到。
- 2026-10-25 真机试用后:去掉「记」快速记录键(用户要求,只留 ✨);候选栏压矮到 38pt,给按键让高度。
