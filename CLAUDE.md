# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

lodo 是一个"纠缠式提醒"待办 app:到期提醒后可 完成/稍等,忽略或稍等都会每隔一个稍等间隔(默认 15 分钟)重复提醒直到完成。三个平台实现,**语义必须逐字对齐**:

- `web/` — Streamlit 演示版(参考实现,仅作演示)
- `ios/` — SwiftUI 多平台 app(iOS 17+/macOS 14+,SwiftData;最终交付目标)
- `android/` — Kotlin + Jetpack Compose + Material 3(minSdk 26)

所有 UI 文案为中文,三端逐字一致。iOS UI 只用 SwiftUI 系统控件,不自绘、不引第三方库——唯一经用户明确确认的例外是 `ContactGraphView.swift`(人脉关系图谱,`Canvas` 绘制节点连线),别拿它当先例引入其他自绘 UI。Web 相关文件(含 SQLite 数据、.env)全部放 `web/` 内,不放仓库顶层。

## 常用命令

```bash
# Web
cd web && pip install -r requirements.txt
streamlit run app.py
python -m pytest tests/                                  # 调度器测试

# iOS — 核心逻辑包可独立测试(无需模拟器)
cd ios/LodoCore && swift test
swift test --filter SchedulerTests                       # 单个测试类
# App 本体用 Xcode 打开 ios/Lodo.xcodeproj。注意:UI 已接入 iOS 26
# Liquid Glass API(#available 门控),编译需要 Xcode 26(iOS 26 SDK)。

# Android(本机 JDK 17 经 Homebrew 安装,gradle 命令前必须设 JAVA_HOME)
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
cd android
./gradlew :app:testDebugUnitTest                         # 调度器单测
./gradlew :app:testDebugUnitTest --tests "com.lodo.app.core.SchedulerTest.dueAtTime"
./gradlew :app:assembleDebug                             # APK 在 app/build/outputs/apk/debug/
```

## 跨平台对齐(改一处必须同步三处)

三端各有一份纯逻辑调度器 + 1:1 移植的同名测试用例(基准时间均为 2026-07-08 周三 09:00):

| | 调度器 | 测试 |
|---|---|---|
| web(参考实现) | `web/lodo/scheduler.py` | `web/tests/test_scheduler.py` |
| iOS | `ios/LodoCore/Sources/LodoCore/Scheduler.swift` | `ios/LodoCore/Tests/LodoCoreTests/SchedulerTests.swift` |
| Android | `android/.../core/Scheduler.kt` | `android/.../core/SchedulerTest.kt` |

关键共享语义(改动调度行为时三端及测试同步改):

- **枚举持久化字符串**三端一致:status `pending/done`、phase `start/end`、repeat_type `none/daily/weekly`
- **周几 0=周一 … 6=周日**(Swift 里 `(weekday+5)%7`,Kotlin 里 `DayOfWeek.value - 1`)
- **重复时间点**是 `"HH:MM"` 字符串列表,一天可多个;`nextOccurrence` 做 8 天前瞻
- **时长两阶段**:duration>0 的事项先提醒"该开始了"(phase start→end),结束再提醒"完成了吗"
- **markNotified 语义**:提醒发出即把 nextRemindAt 顺延一个稍等间隔(忽略也会重响)
- **重复事项完成一次**:保持 pending 并顺延到下一次发生,同时插入一条 done 历史记录
- **设置默认值**:稍等 15 分钟、全天提醒 09:00、每日汇总 21:00

**DeepSeek prompt 三端逐字一致**:`web/lodo/ai.py`、`ios/LodoCore/Sources/LodoCore/DeepSeekClient.swift`、`android/.../ai/DeepSeekClient.kt`。接口:`parse`(新建)、`edit`(改单个事项)、`command`(AI 总入口,目前仅 iOS/Android 有——携带全部待办列表;客户端必须校验 uuid 在列表内,且返回后用**最新**列表重新匹配)。iOS/Android 把 prompt 拆为 taskSchema + taskRules 拼装,web 仍是整段 `_FORMAT_AND_RULES`,文字内容一致。错误文案("未配置 DeepSeek API key…"/"调用 DeepSeek 失败:…"/"无法解析:…")三端一致。改 prompt 时同步三端。iOS 把 `command` 的总则/待办规则/记忆规则进一步拆成 `agent.md` + 两个可在设置里编辑/重置的 skill(`AgentSkillStore`,内置默认文本 + Application Support 下的覆盖文件),默认内容仍与 web/Android 逐字一致;用户主动自定义后本机 prompt 会偏离默认值,属预期行为,不算破坏三端对齐。

**iOS/Android 已对齐的 AI 协议**(web 演示版仍是旧的 parse/edit):`command` 为 `{"actions": [create/update/complete/delete, ...]}` 数组协议(批量、完成、删除),批量/完成/删除过确认页、单条新建/修改直达表单;关键信息缺失时的反问**两端已经分叉**——Android/web 仍是单问题的 `{"question", "options"}`(候选渲染成输入栏上方的胶囊行),iOS 换成了多问题的 `{"ask": [{"header", "question", "multi_select", "options": [{"label", "description", "recommended"}]}]}`(参考 Claude app 的提问卡片:可翻页、单选/多选、带推荐项和"其他"自由输入,答完原地变成只读记录卡,选择静默随下一轮请求回传给 AI,不冒用户气泡)。iOS 侧 `AICommandResult.clarify` 已删,连带 `AgentMessageKind.clarify`/`AgentMessage.clarifyOptions` 换成 `ask`/`askResult` + `askSnapshotData`(`AgentAskSnapshot`,老库里的 clarify 消息自动降级成纯文本气泡);UI 在 `ios/Lodo/Views/AgentAskCard.swift`,解析在 `DeepSeekClient.parseAsk`(离线单测)。Watch 屏幕小,只展示第一道题、选完带补充重新解析。**不要按"三端对齐"把 iOS 的 ask 回退成 clarify**,要动就是把 Android 也升级成 ask。`suggestDuration`/`updateMemory`(时长记忆)、`summarizeToday`(汇总正文)、`weeklyInsight`(完成洞察)、`suggestReschedule`(改期候选)双端同语义同 prompt。`suggestTodayHandling`(总览 tab 今天待办处理建议)、`summarizeTodayMemories`(总览 tab 今天新增记忆总结)是仅 iOS 的两个新函数,与 `weeklyInsight` 同构(同一套"薄包装 + 返回一句话 JSON"写法),Android 没有总览 tab,不需要跟进。`runRoutine`(定时任务,见下)同样仅 iOS、同一套写法,区别是指令来自用户而不是写死的 prompt,并且允许 ReAct 联网(`parseRoutine` 是可离线单测的纯解析函数)。`command` 的 `memorize`/`ask_memory`(收藏与记忆问答,`memoryEnabled` 开关)、`suggest_memorize`(AI 主动建议收藏,不落库、气泡上"收藏这条"按钮点了才存,和 `memorize` 走同一个 `memoryEnabled` 开关但归一化规则和 `ask_memory`/`answer` 一组——与写操作混在一句话里时会被丢弃,只在这句话*唯一*意图就是陈述一条值得记的信息时触发)目前**仅 iOS**(右下角 AI 助手统一入口),Android 尚未跟进,不要按"三端对齐"回退这段。时长记忆文件:iOS 在 Application Support,Android 在 filesDir(`DurationMemory`)。`remember_preference`(AI 在对话里静默记下用户的长期做事偏好,如"以后开会都留一小时")**仅 iOS**:落 Application Support 的 `agent-preferences.md`(`AgentPreferences`,一行一条 + 客户端去重 + 超 40 条调 `consolidatePreferences` 归纳合并),每轮 `command` 的 system prompt 里作为"用户偏好"块拼在时间上下文之后;不受 `memoryEnabled` 门控,`route()` 在进确认清单之前就把它摘走静默落盘(所以确认页/撤销都看不到它),设置 → AI 设置 → AI 偏好 可查看/编辑/重置。三份长期记忆的分工:**记忆库**存用户显式收藏的资料内容,**时长记忆**存"事项类型 → 典型时长",**偏好**存"希望 AI 以后怎么做事"——prompt 里已写明别两边都记。多 AI 服务商(DeepSeek 默认/OpenAI/通义/Kimi/智谱/自定义,key 按服务商分存)与 AI 个性(默认无/四预设/自定义,仅注入反问/汇总/洞察)双端一致。

**iOS/Android 已对齐的新增能力**(本轮同步):
- **AI 批量操作撤销**:`command` 批量确认执行后可撤销,回复"撤销"(或固定短语变体)不经 AI、本地直接处理;实现在 iOS 是 `TodoListView.UndoOp`/`performUndo`,Android 是 `TodoViewModel.UndoOp`/`undoLastBatch`,均按"新建→删除、修改/完成→用之前快照覆盖回去、删除→用快照重新插入"的思路逐条回滚,重复事项完成一次插入的历史记录也会一并清掉。**呈现方式两端有意不同**(见下方架构差异):iOS 有持久多 thread 对话,撤销记录按 thread 隔离,气泡上带按钮;Android 的 AI 弹层一次性/无持久对话,不需要 thread 隔离,撤销走系统 Snackbar 的"撤销"操作按钮,Snackbar 带一个批次编号(`lastUndoToken`),点撤销时核对编号——如果这条 Snackbar 还没消失、又执行完新的一批覆盖了 `lastUndo`,点陈旧 Snackbar 不会误撤销新那批,而是提示"已被覆盖"。Android 的"确认执行"按钮执行入口(`performPendingActions`)第一步就把 `pendingActions` 取走清空,防止快速重复点击并发执行两次;撤销快照(`before`)在真正落库前即时查一次 `TaskRepository.current(uuid)`,不用弹层打开时那份可能已经过时的列表快照——等待确认期间目标事项可能已被通知按钮/Siri 并发改动,用陈旧快照撤销会把并发的改动覆盖掉。
- **联网搜索 + `answer` 动作**:`command` 新增 ReAct 工具 `{"thought", "tool": "web_search", "query"}`(配置了 Tavily key 才开启,`AppSettings`/`SettingsRepository` 里的 `webSearchEnabled`/`webSearchConfigured()`)与 `{"action": "answer", "text"}`(一般性问题的直接回答,与待办操作互斥,归一化规则同 `memorize`/`ask_memory`:混着写操作时丢弃,全是 answer 时只留第一条)。Tavily 是接入的搜索服务(`https://api.tavily.com/search`),key 按"服务商"同一套机制分存(iOS `KeychainHelper.apiKey(for: "Tavily")`,Android `SettingsRepository.apiKey("Tavily")`)。**ReAct 循环机制两端不同**:iOS 有多轮对话历史,搜索结果作为独立 history 条目喂回模型;Android `command` 没有 history 参数,搜索结果直接拼进下一轮用户消息文本里,最多 3 轮,语义等价。
- **抓取链接内容(`web_fetch`)**:与 `web_search` 同一个开关(`webSearchEnabled`)、同一个 skill 文案里追加。ReAct 工具 `{"thought", "tool": "web_fetch", "url"}`,用户消息里出现具体 http/https 链接且想了解链接内容时用,与 `web_search` 二选一(前者抓指定链接,后者搜关键词),不把链接当搜索词。**实现两端不同**:iOS 复用记忆收藏已有的 `ContentExtractor.extract(url:)`(WebKit 的 HTML→NSAttributedString 转换,`ios/Lodo/AI/ContentExtractor.swift`);Android 没有等价基础设施,`WebSearchClient.fetchUrl` 自己写了个简单的标签剥离(去 script/style/注释/标签、折叠空白,没引第三方 HTML 解析库),效果比 iOS 朴素但够 AI 理解页面大意。两端都截断到 8000 字符量级(iOS 沿用 `MemorySearch.maxSourceChars`,Android 本地常量同值)。
- **AI 思考强度**:设置项 `thinkingLevel`(off/low/medium/high,默认 medium),通过 `reasoning_effort` 字段传给支持推理的服务商/模型,只作用于 `command`(AI 助手对话入口),不影响 parse/edit/汇总等后台小请求。不支持的服务商会忽略这个多余字段。
- **AI 助手对话可中途取消**:请求进行中(含 ReAct 多轮)输入区发送按钮换成取消,点了直接 `Task.cancel()`;iOS 已做(`AgentView.sendTask`),Android 的 AI 弹层暂未跟进同款取消入口,不算破坏对齐(Android 请求普遍更快、弹层本身可以直接划掉退出)。
- **已知不对齐,留意**:`suggestDuration`(时长记忆建议)双端函数本身同 prompt,但"新建缺时长时主动 consult 这份记忆"这个消费点,Android 的"快速添加页"(`addParse`)和主聊天入口(`agentRoute`)都没做——只有前者做了;iOS 原来也只有 Siri 快捷指令(`LodoIntents.swift`)做了,这轮补上了主聊天入口(`TodoListView+Agent.swift` 的 `route()`)。也就是说现在 iOS 主聊天新建缺时长会主动带出历史建议,Android 主聊天(`agentRoute`)还不会——这是一个待补的真实缺口,不是有意为之的架构差异,后续要顺手补的话改 `TodoViewModel.agentRoute` 里 `AIAction.Create` 分支,参考同文件 `addParse` 已有的写法。

仍为 iOS 独有(有基础设施依赖,Android 未跟进不算破坏对齐):记忆/收藏系统整体(`MemoryItem`/`记忆` tab,`memorize`/`ask_memory` 由此而来)、资产管理与人脉关系(联系人)两个子功能(都不是独立 `MemoryKind`,是打了保留标签的记忆条目——资产标签 `资产` 挂 `assetValue`,联系人标签 `联系人` 挂昵称/电话/邮箱/生日/喜好/头像/多文件附件这组字段,同一套隐藏/筛选模式;人脉之间的"关系"是独立模型 `ContactRelationship`,无向单条边,靠 uuid 互相引用而非 SwiftData `@Relationship`——和仓库里其余多值/跨记录引用如 `tags`/聊天附件 `attachmentMemoryUUIDs` 同一个思路)、关系图谱可视化(`ContactGraphView`,记忆 tab 筛选出"联系人"后左上角入口,`ContactGraphLayout.circlePositions` 纯布局数学在 LodoCore 可单测、确定性圆形布局不做力导向仿真)、AI 对话多附件与"从记忆库选择"、zip 全量备份导入导出——这几项都依赖 iOS 独有的记忆数据层或 SwiftData/CloudKit,Android 没有对应基础设施,移植前需要先补上整个记忆系统,范围远超"同步一个功能"。已完成待办的历史检索(`ask_memory`/`search_memory` 现在除了记忆条目也会检索 `status == "done"` 的 `TaskItem` 历史行,让"上次做过 X 吗"这类问题能被回答)只是打通检索通路,不是记忆系统本身,`TaskItem` 数据模型/提醒引擎完全不受影响,理论上 Android 也能照做,只是目前还没跟进。另外仍为 iOS 独有:苹果智能(Foundation Models 端侧,`FoundationModelsClient`)、桌面小组件、Siri App Intents、应用内实时语音听写(Android 用系统 RecognizerIntent 对话框代替;agent 入口 iOS 是主页下拉、Android 是顶栏 ✨ 按钮;Android 汇总正文在触发时现算,iOS 是前台排定时的快照)。**定时任务**(用户自定义的 AI 例行任务:到点自动跑一句自己写的指令,如"总结今日待办""看天气给穿搭建议""今日市场动态")也仅 iOS——依赖 BGTaskScheduler 与这套通知基础设施,Android 要跟进得改用 WorkManager 另写一套,不算破坏三端对齐。数据层 `AIRoutine`/`AIRoutineRun`(LodoCore,SwiftData + CloudKit)+ 纯逻辑 `RoutineSchedule`(触发时间计算,8 天前瞻/回看,周几与时间点格式和 `Scheduler.nextOccurrence` 完全一致,单测 `RoutineScheduleTests`);执行层 `ios/Lodo/Core/RoutineRunner.swift`;UI 在设置 → 定时任务(`RoutineListView`/`RoutineEditView`),结果同时进"总览"的今日例行区。**注意:定时任务不进备份 zip**(`BackupData` 没有对应结构),换设备靠 CloudKit 同步。总览 tab(待办/记忆之外新增的第三个 tab,`OverviewView`,默认打开;聚合到期提醒+今天待办[`TaskRowView` 复用待办 tab 同一套可直接滑动完成/改期/稍等/删除、点击编辑的行]、`suggestTodayHandling`/`summarizeTodayMemories` 两句 AI 内容按天缓存)同样仅 iOS——依赖上面这套记忆数据层与已有的 DeepSeekClient 调用,Android 没有对应基础设施,不算破坏三端对齐。

## 各端架构差异(有意为之,勿"统一")

- **提醒引擎**:web 靠页面轮询;iOS 预排 8 条本地通知链(`NotificationManager`,完成/稍等时 rebuild);Android 每事项只挂**一个**精确闹钟,`ReminderReceiver` 触发时发通知→markNotified 入库→重排下一个,自我延续(requestCode = uuid.hashCode())。Android 的完成/稍等两条路径(界面按钮、通知按钮)都走 `TaskRepository`。
- **定时任务的触发(仅 iOS)**:iOS 不允许 app 后台跑定时器,所以和纠缠提醒一样两条腿走路——① `BGAppRefreshTask`(`LodoApp` 的 `.backgroundTask`,标识符 `com.lodo.app.routine`,已写进 `ios/Support/Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes: fetch`)在接近计划时间时被系统唤醒,跑完**当场把结果推成通知**;② 系统不保证唤醒,所以另预排"到点提醒"通知兜底(最多 6 条,`RoutineRunner.dueBudget`,系统 64 条上限里纠缠链已占 48),到点提示打开 app,回前台时 `ContentView` 的 scenePhase 立刻补跑。**前台补跑不推通知**(人已经在看 app 了),只有后台跑完才推。同一时间槽只跑一次(`AIRoutine.lastScheduledSlot`),错过超过 6 小时(`RoutineSchedule.catchUpWindow`)就跳过等下一次。
- **iOS 分层**:`LodoCore` 是纯 Swift SPM 包(无 UI 依赖),app 层的 `TaskItem`(SwiftData)与 `TaskData` 互转后调用调度器。Android 对应:`com.lodo.app.core` 保持纯 Kotlin/JVM(无 Android import),`TaskEntity`(Room)↔`TaskData` 互转。**不要往 core 里引平台依赖**,否则单测跑不了。
- **API key 存储**:web 用 `web/.env`;iOS 用钥匙串(`KeychainHelper`);Android 用 AndroidKeyStore AES/GCM 加密后存 DataStore(`KeystoreCipher`)。
- **iOS 26 接入模式**:部署目标保持 iOS 17/macOS 14,新 API 一律 `#available(iOS 26.0, macOS 26.0, *)` 运行时门控 + 旧写法回退(见 `ios/Lodo/Views/LiquidGlass.swift`、`ContentView.swift` 的三级门控)。Liquid Glass 只用于独立主操作和系统 chrome,List 行内按钮保持 bordered。
- **编辑保存**都会重置 phase=start、nextRemindAt=remindAt;Android 的 `applyEdit` 有 PENDING 守卫。
- **`command` payload 解析可离线单测**:iOS `DeepSeekClient.parseCommand`、Android `DeepSeekClient.parseCommandResult` 都是从网络请求里拆出来的纯函数(给 JSON payload,不发请求),测试见 `ios/LodoCore/Tests/LodoCoreTests/CommandParseTests.swift`、`android/app/src/test/java/com/lodo/app/ai/CommandParseTest.kt`。Android 纯 JVM 单测跑 `org.json` 需要 `testImplementation("org.json:json:...")`(`build.gradle.kts`)覆盖掉 `android.jar` 里全员 throw 的桩实现,否则解析逻辑测不了。
- **Xcode 工程用文件夹同步组**:`ios/Lodo/` 下新增文件自动纳入 app target,`ios/LodoWidget/` 归小组件 target,无需改 pbxproj。`ios/Support/` 放两个 target 的 Info.plist 与 entitlements(不在同步组内)。
- **iOS 小组件(LodoWidgetExtension,仅 iOS)**:SwiftData 库放 App Group `group.com.lodo.app`(`AppGroup.storeURL`,首启从默认位置迁移);app 侧 `WidgetBridge.sync` 在每次数据变更后把"即将到来"快照写进 App Group 并刷新小组件;小组件右侧"+"通过 `lodo://add` 深链弹出快速添加页。app 的 entitlements 只挂 iPhone SDK,macOS 无签名要求也能访问 Group Container。
