# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

lodo 是一个"纠缠式提醒"待办 app:到期提醒后可 完成/稍等,忽略或稍等都会每隔一个稍等间隔(默认 15 分钟)重复提醒直到完成。三个平台实现,**语义必须逐字对齐**:

- `web/` — Streamlit 演示版(参考实现,仅作演示)
- `ios/` — SwiftUI 多平台 app(iOS 17+/macOS 14+,SwiftData;最终交付目标)
- `android/` — Kotlin + Jetpack Compose + Material 3(minSdk 31——为端上 AI/Gemini Nano 的 AICore SDK 硬性要求从 26 提高,详见下文"端上 AI"）

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

**iOS/Android 已对齐的 AI 协议**(web 演示版仍是旧的 parse/edit):`command` 为 `{"actions": [create/update/complete/delete, ...]}` 数组协议(批量、完成、删除),批量/完成/删除过确认页;**单条新建两端已分叉**——Android 仍是可编辑表单、保存后才落库,iOS 改成和单条修改一样**默认直接落库**(用户在对话里说的就是要加这件事,多点一次确认没带来信息量),结果卡片右边给一颗 ✕ 兜底,老对话里已经存下的 `taskProposal` 提案卡仍照常渲染、按钮照常可用(`AgentTaskSnapshot.createdUUID` 区分:新流程的新建结果带它、给 ✕,老流程确认过的结果没有、不给按钮);单条修改**不弹确认**,AI 一解析完直接落库(iOS/Android 都复用批量执行同款的 `UndoOp.updated`/`Updated` 撤销快照机制兜底解析错误——iOS 结果卡片上带撤销按钮[箭头图标,语义是「改回原样」,和新建那颗 ✕「这条别要了」有意区分],Android 是 Snackbar 撤销)。iOS 的 `memorize`/`auto_memorize` 结果卡片同理带 ✕(删条目走 `MemoryPipeline.delete`,连向量分片一起清,并把那条消息原地改写成「已取消收藏。」——条目没了卡片本来也渲染不出来)。`suggest_memorize` 不在此列:那是 AI 主动建议、用户没要求,仍然点了「收藏这条」才落库。关键信息缺失时的反问**两端已经分叉**——Android/web 仍是单问题的 `{"question", "options"}`(候选渲染成输入栏上方的胶囊行),iOS 换成了多问题的 `{"ask": [{"header", "question", "multi_select", "options": [{"label", "description", "recommended"}]}]}`(参考 Claude app 的提问卡片:可翻页、单选/多选、带推荐项和"其他"自由输入,答完原地变成只读记录卡,选择静默随下一轮请求回传给 AI,不冒用户气泡;**卡片待答期间 iOS 把整条输入区收起来**——问题摆着等选、底下再留个输入框是两个并行入口,想自由回答用卡片自带的「其他」,不想答点卡片上的取消)。iOS 侧 `AICommandResult.clarify` 已删,连带 `AgentMessageKind.clarify`/`AgentMessage.clarifyOptions` 换成 `ask`/`askResult` + `askSnapshotData`(`AgentAskSnapshot`,老库里的 clarify 消息自动降级成纯文本气泡);UI 在 `ios/Lodo/Views/AgentAskCard.swift`,解析在 `DeepSeekClient.parseAsk`(离线单测)。Watch 屏幕小,只展示第一道题、选完带补充重新解析。**不要按"三端对齐"把 iOS 的 ask 回退成 clarify**,要动就是把 Android 也升级成 ask。`suggestDuration`/`updateMemory`(时长记忆)、`summarizeToday`(汇总正文)、`weeklyInsight`(完成洞察)、`suggestReschedule`(改期候选)双端同语义同 prompt。`suggestTodayHandling`(总览 tab 今天待办处理建议)、`summarizeTodayMemories`(总览 tab 今天新增记忆总结)是仅 iOS 的两个新函数,与 `weeklyInsight` 同构(同一套"薄包装 + 返回一句话 JSON"写法),Android 没有总览 tab,不需要跟进。`runRoutine`(定时任务,见下)同样仅 iOS、同一套写法,区别是指令来自用户而不是写死的 prompt,并且允许 ReAct 联网(`parseRoutine` 是可离线单测的纯解析函数)。`command` 的 `memorize`/`ask_memory`(收藏与记忆问答,`memoryEnabled` 开关)、`suggest_memorize`(AI 主动建议收藏,不落库、气泡上"收藏这条"按钮点了才存,和 `memorize` 走同一个 `memoryEnabled` 开关但归一化规则和 `ask_memory`/`answer` 一组——与写操作混在一句话里时会被丢弃,只在这句话*唯一*意图就是陈述一条值得记的信息时触发)目前**仅 iOS**(侧栏「AI 助手」页统一入口),Android 尚未跟进,不要按"三端对齐"回退这段。`auto_memorize`(对话中顺带提到的重点事实/事件,如"班主任喜欢收贺卡",不是用户明确要求收藏,也不用像 `suggest_memorize` 那样等用户点按钮确认,可以和其他操作同时出现在一句话里,例如一边新建待办一边顺带记下一件事)同样**仅 iOS**,和 `suggest_memorize` 共用 `memoryEnabled` 开关但不参与其归一化分组(不会因为混了写操作被丢弃,这点和 `memorize` 同组)。`title`/`text` 由 `command` 这轮请求直接给出,`MemoryPipeline.saveAutoMemory` 跳过 `memorize()` 那次额外的整理调用直接落成 `ready` 状态(省一次网络请求),打保留标签 `MemoryItem.autoTagName`("AI记录")与用户主动收藏/确认过的记忆区分开,正常显示不参与资产/人脉那套隐藏筛选,也被排除在 `MemoryTagManageView` 的改名/删除列表之外(和 `assetTagName` 同样的保护);这个标签也被排除在 `memorize()` 的 `existingTags` 提示之外,避免常规收藏整理时被复用混淆。`saveAutoMemory` 客户端去重(同 `AgentPreferences.append` 的"互相包含即算重复"判定):新内容是已有某条自动记录的更完整表述(包含旧摘要且更长,如过敏原后来又多了一种)时原地更新那条,不新开一条;新内容被已有摘要包含(纯重复提及)时跳过。route() 里和 `remember_preference` 同一套"先摘出来静默落盘,再走剩下的动作"处理,不进确认页、不参与撤销。时长记忆文件:iOS 在 Application Support,Android 在 filesDir(`DurationMemory`)。`remember_preference`(AI 在对话里静默记下用户的长期做事偏好,如"以后开会都留一小时")**仅 iOS**:落 Application Support 的 `agent-preferences.md`(`AgentPreferences`,一行一条 + 客户端去重 + 超 40 条调 `consolidatePreferences` 归纳合并),每轮 `command` 的 system prompt 里作为"用户偏好"块拼在时间上下文之后;不受 `memoryEnabled` 门控,`route()` 在进确认清单之前就把它摘走静默落盘(所以确认页/撤销都看不到它),设置 → AI 设置 → AI 偏好 可查看/编辑/重置。三份长期记忆的分工:**记忆库**存用户显式收藏的资料内容,**时长记忆**存"事项类型 → 典型时长",**偏好**存"希望 AI 以后怎么做事"——prompt 里已写明别两边都记。多 AI 服务商(DeepSeek 默认/GPT-5.6 Luna/Qwen3.5 Flash/OpenAI/通义/Kimi/智谱/自定义,key 按服务商分存)与 AI 个性(默认无/四预设/自定义,仅注入反问/汇总/洞察)双端一致。**"使用内置 API Key"是仅 iOS 的能力**(`BuiltInAPIKey.key(for:)`,按服务商查内置 key,目前 DeepSeek、GPT-5.6 Luna、Qwen3.5 Flash 三家有;后两个都走同一个 RunAPI 账号的 OpenAI 兼容接口 `https://runapi.host/v1/chat/completions`,只是 `model` 字段不同,都是带 reasoning 的模型,响应里会带 `reasoning_tokens`,单次请求耗时可能到十几秒,RunAPI 那边偶发过网关层 5xx/模型未开通的报错,不算 App 侧的 bug),真实 key 存在 gitignored 的 `BuiltInAPIKey.swift` 里不进仓库;Android 没有内置 key 机制,所有服务商都要求用户自己填 key,不算破坏三端对齐。

**iOS/Android 已对齐的新增能力**(本轮同步):
- **AI 批量操作撤销**:`command` 批量确认执行后可撤销,回复"撤销"(或固定短语变体)不经 AI、本地直接处理;实现在 iOS 是 `AgentHostView.performUndo`(`UndoOp` 定义仍在 `TodoListView.swift` 顶层),Android 是 `TodoViewModel.UndoOp`/`undoLastBatch`,均按"新建→删除、修改/完成→用之前快照覆盖回去、删除→用快照重新插入"的思路逐条回滚,重复事项完成一次插入的历史记录也会一并清掉。**呈现方式两端有意不同**(见下方架构差异):iOS 有持久多 thread 对话,撤销记录按 thread 隔离,气泡上带按钮;Android 的 AI 弹层一次性/无持久对话,不需要 thread 隔离,撤销走系统 Snackbar 的"撤销"操作按钮,Snackbar 带一个批次编号(`lastUndoToken`),点撤销时核对编号——如果这条 Snackbar 还没消失、又执行完新的一批覆盖了 `lastUndo`,点陈旧 Snackbar 不会误撤销新那批,而是提示"已被覆盖"。Android 的"确认执行"按钮执行入口(`performPendingActions`)第一步就把 `pendingActions` 取走清空,防止快速重复点击并发执行两次;撤销快照(`before`)在真正落库前即时查一次 `TaskRepository.current(uuid)`,不用弹层打开时那份可能已经过时的列表快照——等待确认期间目标事项可能已被通知按钮/Siri 并发改动,用陈旧快照撤销会把并发的改动覆盖掉。
- **联网搜索 + `answer` 动作**:`command` 新增 ReAct 工具 `{"thought", "tool": "web_search", "query"}`(配置了 Tavily key 才开启,`AppSettings`/`SettingsRepository` 里的 `webSearchEnabled`/`webSearchConfigured()`)与 `{"action": "answer", "text"}`(一般性问题的直接回答,与待办操作互斥,归一化规则同 `memorize`/`ask_memory`:混着写操作时丢弃,全是 answer 时只留第一条)。Tavily 是接入的搜索服务(`https://api.tavily.com/search`),key 按"服务商"同一套机制分存(iOS `KeychainHelper.apiKey(for: "Tavily")`,Android `SettingsRepository.apiKey("Tavily")`)。**ReAct 循环机制两端不同**:iOS 有多轮对话历史,搜索结果作为独立 history 条目喂回模型;Android `command` 没有 history 参数,搜索结果直接拼进下一轮用户消息文本里,最多 3 轮,语义等价。
- **抓取链接内容(`web_fetch`)**:与 `web_search` 同一个开关(`webSearchEnabled`)、同一个 skill 文案里追加。ReAct 工具 `{"thought", "tool": "web_fetch", "url"}`,用户消息里出现具体 http/https 链接且想了解链接内容时用,与 `web_search` 二选一(前者抓指定链接,后者搜关键词),不把链接当搜索词。**实现两端不同**:iOS 复用记忆收藏已有的 `ContentExtractor.extract(url:)`(WebKit 的 HTML→NSAttributedString 转换,`ios/Lodo/AI/ContentExtractor.swift`);Android 没有等价基础设施,`WebSearchClient.fetchUrl` 自己写了个简单的标签剥离(去 script/style/注释/标签、折叠空白,没引第三方 HTML 解析库),效果比 iOS 朴素但够 AI 理解页面大意。两端都截断到 8000 字符量级(iOS 沿用 `MemorySearch.maxSourceChars`,Android 本地常量同值)。
- **AI 思考强度**:设置项 `thinkingLevel`(off/low/medium/high,默认 medium),通过 `reasoning_effort` 字段传给支持推理的服务商/模型,只作用于 `command`(AI 助手对话入口),不影响 parse/edit/汇总等后台小请求。不支持的服务商会忽略这个多余字段。
- **AI 助手对话可中途取消**:请求进行中(含 ReAct 多轮)输入区发送按钮换成取消,点了直接 `Task.cancel()`;iOS 已做(`AgentView.sendTask`),Android 的 AI 弹层暂未跟进同款取消入口,不算破坏对齐(Android 请求普遍更快、弹层本身可以直接划掉退出)。
- **`suggestDuration` 消费点已双端对齐**:`suggestDuration`(时长记忆建议)双端函数本身同 prompt;"新建缺时长时主动 consult 这份记忆"这个消费点,iOS 是 Siri 快捷指令(`LodoIntents.swift`)+ 主聊天入口(`AgentHostView+Routing.swift` 的 `route()`),Android 是"快速添加页"(`TodoViewModel.addParse`)+ 主聊天入口(`TodoViewModel.agentRoute` 里 `AIAction.Create` 单条分支,同文件参考 `addParse` 已有写法补上)——两端各自的两个入口都已消费,不再有缺口。

**Android 记忆/收藏系统与周边能力已跟进**(核心子集,不是逐字段照抄 iOS):数据层 `MemoryEntity`/`MemoryDao`/`MemoryRepository`(`android/.../data/`),纯文字/链接收藏 + AI 整理(`DeepSeekClient.memorize`/`askMemory`,prompt 去掉了 iOS 独有的资产字段抽取指令,因为 Android 资产落库走结构化表单不经这条 AI 整理路径),`command` 协议新增 `memorize`/`ask_memory`/`suggest_memorize` action 与 `search_memory` ReAct 工具(`memoryEnabled` 门控,和 `webSearchEnabled` 同一个"能力开关传参"模式,不是设置页开关);检索退化成纯关键词(`core/MemorySearch.kt`,无端上 embedding,和 iOS"没有 embedding 时退化成关键词搜索"是同一个合法降级路径,不是残缺实现)。资产/人脉两个子功能同 iOS 思路——不是独立 `MemoryKind`,是打了保留标签(`assetTagName`="资产"/`contactTagName`="人脉")的记忆条目,额外字段直接落在 `MemoryEntity` 上;区别于 iOS 的是这两类走结构化表单直接落库(不经 AI 整理,省一次网络请求,离线也能记)。人脉关系图谱(`ContactRelationshipEntity` 无向边 + `core/ContactGraphLayout.kt` 确定性圆形布局,单测 `ContactGraphLayoutTest`,UI 是 `ContactGraphScreen.kt` 用 Compose `Canvas` 画节点连线——这是仓库里除 iOS `ContactGraphView` 外唯二的自绘 UI 例外)、通讯录导入导出(`ContactsBridge.kt`,零权限的单个路径:选择导入用系统 contact picker,导出走 `ACTION_INSERT` 确认页;批量导入导出需要 `READ_CONTACTS`/`WRITE_CONTACTS` 权限,Android 暂未跟进,iOS 独有)、zip 全量备份(`data/Backup.kt`,待办+记忆+人脉关系边一起打包,导入按 uuid 去重合并不覆盖;`version 1` 的老备份没有 `contactRelationships` 字段,导入时按空数组处理不影响其余部分)均已实现。仍为 iOS 独有:AI 对话多附件与"从记忆库选择"(Android 记忆系统目前只服务 `command` 协议与记忆 tab 本身,还没接入 agent 弹层的附件选择)。

**Android 定时任务已跟进**,触发机制是平台差异(不是需要对齐的地方):数据层 `RoutineEntity`/`RoutineRunEntity`,触发时间计算复用 `Scheduler.nextOccurrence`(把例行任务包成一次性 `TaskData` 求下一次触发,不另写一套);iOS 靠 `BGAppRefreshTask` + 预排通知兜底,Android 用 `WorkManager` 15 分钟周期检查(`RoutineCheckWorker`,15 分钟是系统允许的最小周期,同样是"尽力而为"不追求精确触发);执行只做单轮直接作答(`DeepSeekClient.runRoutine`),不像 iOS 那样带 ReAct 联网,是这一轮的明确简化;UI 在设置 → 定时任务。**定时任务不进备份 zip**,两端一致(iOS `BackupData` 没有对应结构,Android `Backup.kt` 同样没有)。

**Android 端上 AI(Gemini Nano,`ai/GeminiNanoClient.kt`)已跟进**,对应 iOS Foundation Models(`FoundationModelsClient`)在产品里的同一个位置——"不联网、不需要 API key 的本机模型",底层技术不同(Apple Foundation Models vs Google AICore SDK)是平台差异。**这项能力把 Android 的 `minSdk` 从 26 提到了 31**(AICore SDK 硬性要求,用户已确认接受掉 Android 8.0-11 支持);AICore 目前是实验阶段 SDK(`0.0.1-exp01`),端上模型只在少数 Pixel 机型真正可用,`GeminiNanoClient.isAvailable`/`generate` 失败一律返回 `false`/`null` 静默降级,不抛错误打断主流程——设置页"端上 AI"栏目点"检测"才探测一次,不在 app 启动时自动测。

**Android Siri Intents 等价物**:Google Assistant App Actions,`res/xml/shortcuts.xml` 里的 `<capability android:name="actions.intent.CREATE_TASK">` 声明(对应 iOS `LodoIntents.swift` 的 `AddTaskIntent`),语音说出的标题通过 `MainActivity.consumeRouteIntent` 的 `"create_task"` 分支送进 agent 输入框走正常解析确认流程,不跳过确认直接落库。**这条声明未经真机验证**——需要 Google 的 App Actions Test Tool 加登录 Google 账号的真机/模拟器,和没有真机的环境下无法验证 Siri Intents 是同一类限制。

**Android 桌面小组件已跟进**(`widget/ReminderWidgetProvider.kt`),经典 `AppWidgetProvider`/`RemoteViews`(不是 Glance,维持"UI 只用系统控件"的一贯做法),展示最近一条待办;系统周期刷新(30 分钟,平台允许的最小值),没有像 iOS `WidgetBridge.sync` 那样"数据变更后主动推刷新"的实时联动,是platform 触发机制差异,不是缺口。

仍为 iOS 独有(有基础设施依赖或架构差异,Android 未跟进不算破坏对齐):应用内实时语音听写(Android 用系统 `RecognizerIntent` 对话框代替;agent 入口 iOS 是侧栏里的「AI 助手」行(它本身就是四个平级页面之一)、Android 是顶栏 ✨ 按钮;Android 汇总正文在触发时现算,iOS 是前台排定时的快照)、CloudKit 自动同步(Android 换设备靠手动 zip 导入导出,不是自动云同步)。总览页(待办/记忆之外的第三个页面,`OverviewView`,默认落地页;聚合到期提醒+今天待办[`TaskRowView` 复用待办页同一套可向左滑完成/改期/稍等/删除、点击编辑的行]、`suggestTodayHandling`/`summarizeTodayMemories` 两句 AI 内容按天缓存)同样仅 iOS——依赖记忆数据层与已有的 DeepSeekClient 调用组合出的一个聚合视图,Android 没有对应设计,不算破坏三端对齐。

**iOS 导航是左滑抽屉,不是标签栏**(仅 iOS,Android 是底部导航 + 顶栏 ✨,不需要跟进):总览/待办事项/记忆/AI 四个页面完全平级,`AppShellView` 是唯一的导航外壳——窄屏(iPhone)侧栏是抽屉,整页往右拖唤出、内容整块推移压暗,也可以点导航栏左上角的 ☰(`sidebarToolbarButton()`,经 `\.sidebarChrome` 这个 Environment 下发,四个页面不用各加 init 参数);宽屏(iPad 常规宽度/macOS)侧栏常驻并排(判据是 `usesRegularLayout`,macOS 直接按平台定死——那边 `horizontalSizeClass` 可能是 nil,按 `== .regular` 判会掉进抽屉分支)。**抽屉推开时页面导航栏上的项要整条撤掉**,不只是 ☰:工具栏挂在 NavigationStack 上、不跟着内容平移,留着会浮在已经露出来的侧栏上面还能点(待办页「项目视图」、记忆页那一串都按 `sidebarChrome?.hidesChrome` 门控;新增页面工具栏时记得跟上)。`hidesChrome` 的判据不能只看 `showSidebar`——收起动画播完之前也得压住,所以 `closeSidebar` 用带 `completionCriteria` 的 `withAnimation`,回调里才放开 `isClosingSidebar`。**唤出手势是整页任意位置往右拖**(`.simultaneousGesture`,`sidebarDrag()` 第一帧就按"横向为主 + 方向对"定死归属,纵向滚动照常让给列表;`@GestureState` 只用来兜底——系统中断手势时不走 `onEnded`,靠它把拖到一半的位移归零)。横向可滑控件(`HorizontalChipRow`)会经 `SidebarDragExclusionKey` 这个 preference 申报自己的矩形,起手点落在里面的拖拽抽屉直接不接管,否则"往右看下一个胶囊"会顺手把抽屉拖出来;它只在当前显示的那个页面申报(`\.sectionIsActive`,四个页面是叠在 ZStack 里的,不筛的话隐藏页的胶囊行会在别的页面留下一块死区)。收回抽屉的拖拽只挂在遮罩上,**不要挂到侧栏面板上**——面板里那个 List 自己有向左滑的行操作(删除对话、标签常驻),会和它抢同一个方向。为了不和它抢方向,**全 app 没有任何 `swipeActions(edge: .leading)`**——行操作一律收在向左滑那一侧,主操作(完成/转为待办/立即运行/未完成)排在最靠外当 full swipe、删除排在里面;新增行视图时别再往 leading 挂东西。记忆页工具栏左上只有 ☰(人脉态多两颗:关系图谱、批量导出),右上是收藏「+」菜单——**没有筛选按钮**,标签/资产/人脉一律从侧栏进(`consumeTagFilter`,每次覆盖不叠加),列表顶部那行「清除筛选:xx」是取消筛选的唯一入口;按来源格式(文字/链接/文件)筛这个能力随筛选浮层一起去掉了,它当时只有那个浮层一个入口。记忆页 push 进条目详情后整个手势让开(`swipeGestureEnabled`,那时左边缘归系统返回手势,所以 `memoryPath` 提到外壳持有)。抽屉容器在 `compactLayout` 的 ZStack 上挂 `.ignoresSafeArea(.container)`——**必须挂在那一层**,挂在 `sectionStack` 上时 `clipShape` 仍按安全区内的 frame 裁,推开的卡上下各短一截;只忽略 `.container`(默认的 `.all` 连键盘区一起吃,AI 输入栏会被键盘盖住)。代价是被吃掉的那截安全区要手动还:侧栏底部那排浮层按钮用 `deviceBottomInset` 加回来(和 `deviceTopInset` 同一套,量它的 GeometryReader 挂了 `.ignoresSafeArea(.keyboard)`,不然键盘一弹起量到的就是键盘高度),页面内容用 `safeAreaInset` 补 `pageBottomRefill = deviceBottomInset - keyboardInset`——`keyboardInset` 是在忽略了容器安全区的那棵子树里量出来的(那里剩下的底部安全区只有键盘),**不监听 keyboardWillShow/Hide**:那是进程级通知,浮动键盘不占底部安全区也照发,交互式收键盘的中间态也没法用一个布尔表达。ZStack 还要垫一层 `panelBackground`,不然侧栏只有 300pt 宽、圆角缺口右边露的是窗口纯白。侧栏(`AppSidebarView`)自上而下是四个页面导航行(记忆行下面嵌一段记忆标签:常驻的平铺、其余收进默认折叠的"更多标签",行左滑切换常驻,常驻集合存在 `AppSettings.sidebarPinnedTagsKey`)、「最近」对话历史、底部浮层(左「设置」——全 app 唯一设置入口、右「新建对话」)。四个页面用 ZStack 叠着只显示当前那个(切回来时筛选胶囊/滚动位置还在,和原来 TabView 一样),但没打开过的不构建(总览页一挂载就会发起 AI 请求)。AI 页的路由/暂存态(`pendingActions`、撤销快照)归 `AgentHostView` + `AgentHostView+Routing.swift`,不再寄生在 `TodoListView` 上。

## 各端架构差异(有意为之,勿"统一")

- **提醒引擎**:web 靠页面轮询;iOS 预排 8 条本地通知链(`NotificationManager`,完成/稍等时 rebuild);Android 每事项只挂**一个**精确闹钟,`ReminderReceiver` 触发时发通知→markNotified 入库→重排下一个,自我延续(requestCode = uuid.hashCode())。Android 的完成/稍等两条路径(界面按钮、通知按钮)都走 `TaskRepository`。
- **定时任务的触发(仅 iOS)**:iOS 不允许 app 后台跑定时器,所以和纠缠提醒一样两条腿走路——① `BGAppRefreshTask`(`LodoApp` 的 `.backgroundTask`,标识符 `com.lodo.app.routine`,已写进 `ios/Support/Info.plist` 的 `BGTaskSchedulerPermittedIdentifiers` + `UIBackgroundModes: fetch`)在接近计划时间时被系统唤醒,跑完**当场把结果推成通知**;② 系统不保证唤醒,所以另预排"到点提醒"通知兜底(最多 6 条,`RoutineRunner.dueBudget`,系统 64 条上限里纠缠链已占 48),到点提示打开 app,回前台时 `ContentView` 的 scenePhase 立刻补跑。**前台补跑不推通知**(人已经在看 app 了),只有后台跑完才推。同一时间槽只跑一次(`AIRoutine.lastScheduledSlot`),错过超过 6 小时(`RoutineSchedule.catchUpWindow`)就跳过等下一次。
- **iOS 分层**:`LodoCore` 是纯 Swift SPM 包(无 UI 依赖),app 层的 `TaskItem`(SwiftData)与 `TaskData` 互转后调用调度器。Android 对应:`com.lodo.app.core` 保持纯 Kotlin/JVM(无 Android import),`TaskEntity`(Room)↔`TaskData` 互转。**不要往 core 里引平台依赖**,否则单测跑不了。
- **API key 存储**:web 用 `web/.env`;iOS 用钥匙串(`KeychainHelper`);Android 用 AndroidKeyStore AES/GCM 加密后存 DataStore(`KeystoreCipher`)。
- **iOS 26 接入模式**:部署目标保持 iOS 17/macOS 14,新 API 一律 `#available(iOS 26.0, macOS 26.0, *)` 运行时门控 + 旧写法回退(见 `ios/Lodo/Views/LiquidGlass.swift`)。导航容器本身不再有版本分叉——抽屉是自绘容器 + 系统 List,iOS 17 到 26 同一套代码。Liquid Glass 只用于独立主操作和系统 chrome,List 行内按钮保持 bordered。
- **编辑保存**都会重置 phase=start、nextRemindAt=remindAt;Android 的 `applyEdit` 有 PENDING 守卫。
- **`command` payload 解析可离线单测**:iOS `DeepSeekClient.parseCommand`、Android `DeepSeekClient.parseCommandResult` 都是从网络请求里拆出来的纯函数(给 JSON payload,不发请求),测试见 `ios/LodoCore/Tests/LodoCoreTests/CommandParseTests.swift`、`android/app/src/test/java/com/lodo/app/ai/CommandParseTest.kt`。Android 纯 JVM 单测跑 `org.json` 需要 `testImplementation("org.json:json:...")`(`build.gradle.kts`)覆盖掉 `android.jar` 里全员 throw 的桩实现,否则解析逻辑测不了。
- **Xcode 工程用文件夹同步组**:`ios/Lodo/` 下新增文件自动纳入 app target,`ios/LodoWidget/` 归小组件 target,无需改 pbxproj。`ios/Support/` 放两个 target 的 Info.plist 与 entitlements(不在同步组内)。
- **iOS 小组件(LodoWidgetExtension,仅 iOS)**:SwiftData 库放 App Group `group.com.lodo.app`(`AppGroup.storeURL`,首启从默认位置迁移);app 侧 `WidgetBridge.sync` 在每次数据变更后把"即将到来"快照写进 App Group 并刷新小组件;小组件右侧"+"通过 `lodo://add` 深链弹出快速添加页。app 的 entitlements 只挂 iPhone SDK,macOS 无签名要求也能访问 Group Container。
