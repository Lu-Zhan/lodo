# AI 助手(agent)端到端测试与修复报告

日期:2026-10-03　　范围:iOS / LodoCore 的 AI 助手(`command` 总入口),顺带 Android、web 的同一条 prompt

## 结论

- 新建了一套**真发请求**的 agent 测试:46 个场景,最终整套跑下来 **46/46 通过**。
- 测试过程中发现并修复了 **7 个问题**。其中 3 个是 prompt 管不住、改在客户端兜底的。
- 另外发现 Android 在 main 上**本来就编译不过**,已修复。
- 回归结果:
  - 离线单测 612 个全部通过(46 个联网用例默认跳过)。
  - iOS 模拟器构建、macOS 构建都成功。
  - Android 单测通过。
- 尚未提交到 git。

## 一、测试怎么设计的

### 1. 模型层:`AgentLiveEvalTests`

文件:`ios/LodoCore/Tests/LodoCoreTests/AgentLiveEvalTests.swift`

- **真实的部分**:用内置 key 真发请求给当前服务商(DeepSeek Flash)。prompt、解析函数 `parseCommand`、ReAct 循环都是线上同一份。
- **只换成桩的部分**:"执行工具"这一步。ReAct 循环照抄 app 的 `AgentHostView.route()`:最多 3 轮,工具调用用固定假数据作答,写回历史的格式与 app 逐字一致。被换掉的工具有记忆检索、联网搜索、抓链接、健康、行程、订阅文章、外部 skill。
- **夹具**:
  - 3 条待办:买牛奶、交房租、每周写周报
  - 1 个倒数日:结婚纪念日
  - 1 项资产:招商银行定期
  - 1 个订阅:少数派
  - 1 趟旅行:东京四日(含航班、酒店、浅草寺、晴空塔)
- **断言**:只卡"必须这样才算对"的部分,即动作类型、目标 id、关键字段(日期、时刻、重复规则、金额等),不卡措辞。
- **默认跳过**,不影响离线的 `swift test`。手动跑:

```bash
cd ios/LodoCore
LODO_LIVE_AI=1 LODO_LIVE_AI_LOG=/tmp/agent-eval.log swift test --filter AgentLiveEvalTests
```

整套大约 4–5 分钟。

- 日志里记着每个场景模型实际给了什么。
- `testDumpSystemPrompt` 会把完整 system prompt 写到 `<日志>.prompt.txt`,排查"模型为什么这么答"时先看这个。

**覆盖的场景(46 个)**

| 类别 | 场景 |
|---|---|
| 待办 | 单条新建、一句多条、每周一三五、每天、全天(只说日子)、指定项目、英文输入、相对周几(下周三)、修改、完成、完成重复事项、删除、删不存在的事项不误伤 |
| 反问 | 信息不足时反问;答完反问后续上并新建 |
| 对话与记忆 | 闲聊回答、没开联网也能直接回答、问日程从待办列表回答、收藏、查记忆(走检索)、记住偏好、新建时顺带记录、陈述一条信息时建议收藏 |
| 工具 | 联网搜索、抓链接(不当成关键词去搜)、读健康数据、搜订阅文章、读行程后回答;健康没开时不乱调 `read_health` |
| 旅行 | 规划行程(日期、天数、城市国家、summary 长度)、记录自己定好的行程(`record: true`、不补景点)、改行程(先 `read_trip`、按 id 删)、航班不能被删改、旅行页焦点下的含糊修改 |
| 倒数日 / 资产 / 订阅 | 新建、改名、删除倒数日;倒数日页焦点下的含糊新建;新建资产;更新资产;订阅链接;暂停订阅;一句话同时建倒数日和待办 |
| 多轮 | 上一轮刚建的事项、这一轮"改成4点吧";对话里提到的事项不在列表时不能改动别的事项 |

### 2. app 层:模拟器端到端

在 iOS 27 模拟器里用 `--demo-skip-onboarding --demo-agent-send "<一句话>"` 真发请求,截图核对落库和结果卡片。模拟器的数据和用户真实数据隔离。

| 用例 | 结果 |
|---|---|
| 新建任务 | 正常 |
| 新建倒数日(带撤销、跳转小条) | 正常 |
| 新增资产 | 正常 |
| 收藏 | 正常 |
| 规划京都三日(年份、天数正确,「写入行程」按钮可用) | 正常 |
| 闲聊回答 | 正常 |
| 一句话"完成任务 + 删倒数日" | 正常:倒数日直接执行带撤销,完成任务进确认清单 |
| 订阅阮一峰博客 | 失败:站点返回 403,见第三节 |

## 二、发现并修复的问题

### 1. 张冠李戴:改错事项(严重)

- **现象**:
  - 用户说的事项不在待办列表里时,模型会拿列表里另一件顶上。
  - "不在列表里"的情况包括:已完成、超出带进 prompt 的 50 条、在别的设备上删了。
  - 实测"改成4点吧"把「买牛奶」整个改成了「给妈妈打电话」,3/3 复现。
  - 单条修改是直接落库的,等于静默覆盖了一件无关的事。
- **修复**:
  - **prompt**:写明"绝不能拿列表里另一件不相干的事项顶替,要么新建,要么反问"。
  - **客户端兜底**:新增 `DeepSeekClient.guardMisdirectedUpdates`。光改 prompt 挡不住,因为模型仍会给出 update。
  - 兜底规则:update 把标题换成毫不相干的另一件事(新旧标题没有一处相邻两字相同),且用户这句话里根本没提到原事项时,改成新建,原事项不动。
  - 用户点名改名("把买牛奶改成…")会提到原标题,不受影响。
  - 单测 `MisdirectedUpdateGuardTests`。
- **已知限制**:模型只改了另一件事的**时间**、没改标题时,和"把买牛奶改成4点"分不出来。这种情况只在所指事项不在列表里时出现;正常使用时上一轮新建的事项一定在列表里,对应场景稳定通过。

### 2. 规划行程年份算错、天数多一天

- **现象**:"下个月10号出发,京都三天"被排成 **2025**-11-10(当前是 2026 年),而且排成了 4 天。
- **修复**:
  - **prompt**:日期一律按「当前时间」换算;"玩 N 天"就是起止相差 N-1 天,附例子。
  - **客户端兜底**:`parseTripPlan(now:)`,规划(非记录)的行程整份落在今天之前时,按整年往后挪,行程项跟着挪。
  - 记录(`record: true`)的行程可能本来就是过去的,原样保留。
  - 解析函数一律把 `now` 当参数传入,单测固定日期。原有几条单测的样例日期是 2026 年 7 月,已经变成"过去",顺手改成固定 `now`。
  - 新增单测 `testPastPlanShiftedForwardByYears`、`testRecordedPastTripKeepsDates`。

### 3. 每周重复的周几偏一位(偶发)

- **现象**:"每周一三五"偶尔给出 `[1, 3, 5]`,即周二四六。提醒会落在错的日子上。
- **修复**:todo skill 里写明"周一是 0 不是 1",并给出例子:每周一三五 → [0, 2, 4]、每周二四 → [1, 3]、每个周末 → [5, 6]。

### 4. 只说日子却不是全天(稳定复现)

- **现象**:"后天要交水电费"3/3 被排成 09:00 的定时事项。
- **原因**:prompt 里有"只有日期就是全天"的规则,但字段模板把 `"all_day": false` 写成了示例值,模型把它当成默认值。
- **修复**:
  - 模板改成 `"all_day": true/false`。
  - 规则补上"不要自己补 09:00 之类的时刻(全天事项按用户设置的全天提醒时间提醒)"。
  - 这条规则三端原本逐字一致,web、Android 同步改了。

### 5. "记一下…"被当成规划

- **现象**:"记一下:下周五去成都两天,住春熙路的亚朵,周六上午去大熊猫基地"返回的规划没有 `record: true`,被当成需要确认的 AI 建议。
- **修复**:tripPlanner skill 里加上这句话作为例子,并写明判据:说的是"记一下/记录/记下来",或已经给出了具体酒店、几点去哪,就是记录。

### 6. 偶发"找不到要操作的事项"

- **现象**:id 本身是对的,但模型抄回来时格式有偏差(大小写、空白、花括号等),客户端精确比对失败,正确的指令被拒。
- **修复**:
  - 新增 `DeepSeekClient.canonicalID`:忽略大小写、首尾空白、花括号和 `[id:…]` 外壳,对回列表里原样的字符串。
  - 待办、倒数日、资产、订阅四处 id 校验都改用它。
  - 编造的 id 照样拒绝。
  - 报错文案带上模型给的 id,方便排查。
  - 单测 `CanonicalIDTests`。

### 7. 英文界面冒中文

- **现象**:应用内语言为英文时,AI 结果卡片上写着「明天 3:00 PM」;任务页的「今天 / 明天 / 昨天」分组标题、定时任务的「已停用」也是中文。
- **原因**:这几处用 `LocalizedStrings.translate("…")`。它查的是从 `strings.csv` 生成的表,而这几个词不在生成范围(shared / ios_core)里,查不到就原样返回中文。
- **修复**:
  - 全量扫了 18 处 `translate` 字面量调用,其中 7 处(4 个词)查不到。
  - 改成 `String(localized:bundle:.appLanguage())`,走 String Catalog,这几个词那边都有英文。
  - 模拟器里确认已显示 "Tomorrow 3:00 PM"。

## 三、其他发现

- **Android 编译失败(测试前就存在)**:`TodoViewModel.kt` 用了 `com.lodo.app.ui.localizedParsedTaskCaption` 却没 import,`compileDebugKotlin` 直接报错。这正好在 Android AI 助手的结果展示路径上。已补 import,单测通过。
- **订阅阮一峰博客失败**:该站点对所有非浏览器请求返回 403(Cloudflare 验证),带浏览器 User-Agent 也一样。app 侧修不了,结果卡片如实报了错误。CLAUDE.md 里已经把它列为"推荐订阅别加回去"的站点。
- **web 测试没跑**:本机系统 Python 和 `web/.venv` 都没装 pytest,没有往用户环境里装东西。web 的改动只有 prompt 里一行文字,确认了 `ai.py` 语法正确、新规则已生效。

## 四、改动清单

| 文件 | 改动 |
|---|---|
| `ios/LodoCore/Tests/LodoCoreTests/AgentLiveEvalTests.swift` | 新增,端到端测试 |
| `ios/LodoCore/Sources/LodoCore/DeepSeekClient.swift` | `guardMisdirectedUpdates`、`canonicalID`、`parseTripPlan(now:)`、`parseCommand(now:)` |
| `ios/LodoCore/Sources/LodoCore/AgentSkillStore.swift` | prompt:不许顶替、周几例子、全天规则与模板、天数换算、记录判据 |
| `ios/LodoCore/Sources/LodoCore/CountdownCommand.swift`、`LibraryCommand.swift` | id 校验改用 `canonicalID` |
| `ios/LodoCore/Tests/LodoCoreTests/CommandParseTests.swift` | 新增 `MisdirectedUpdateGuardTests`、`CanonicalIDTests` |
| `ios/LodoCore/Tests/LodoCoreTests/TripPlanTests.swift`、`LibraryCommandTests.swift` | 固定 `now`;新增年份校正两条用例 |
| `ios/Lodo/Core/LocalizedContent.swift`、`Views/TodoListView.swift`、`Views/DoneListView.swift` | 今天/明天/昨天/已停用改走 String Catalog |
| `android/.../ai/DeepSeekClient.kt`、`web/lodo/ai.py` | 全天规则同步 |
| `android/.../ui/todo/TodoViewModel.kt` | 补 import,修复编译 |
| `CLAUDE.md` | 记录测试的用法和本轮修复(别改回去的几条) |

## 五、后续建议

- **什么时候跑**:改 prompt 或解析之后跑一遍这套测试。模型有随机性,单个场景偶发失败时,先把同一条重跑 3 次再下结论。
- **测试里没覆盖到的**:
  - 撤销:依赖同一次运行里的上下文,跨重启测不了。
  - 点按钮确认的流程:「写入行程」、确认清单。
  - 照片附件。
  - 定时任务那条 `runRoutine` 路径。
  - 需要的话,可以用 UI 测试或模拟器点击补上。
- **Android / web**:只同步了全天那一条规则。周几例子、"不许顶替"等改动是 iOS 侧的,Android 的 todo prompt 本来就和 iOS 分叉了。要做三端对齐,需要单独评估。
