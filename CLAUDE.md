# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目定位

lodo 是一个"纠缠式提醒"待办 app:到期提醒后可 完成/稍等,忽略或稍等都会每隔一个稍等间隔(默认 15 分钟)重复提醒直到完成。三个平台实现,**语义必须逐字对齐**:

- `web/` — Streamlit 演示版(参考实现,仅作演示)
- `ios/` — SwiftUI 多平台 app(iOS 17+/macOS 14+,SwiftData;最终交付目标)
- `android/` — Kotlin + Jetpack Compose + Material 3(minSdk 26)

所有 UI 文案为中文,三端逐字一致。iOS UI 只用 SwiftUI 系统控件,不自绘、不引第三方库。Web 相关文件(含 SQLite 数据、.env)全部放 `web/` 内,不放仓库顶层。

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

**DeepSeek prompt 三端逐字一致**:`web/lodo/ai.py`、`ios/Lodo/AI/DeepSeekClient.swift`、`android/.../ai/DeepSeekClient.kt`。接口:`parse`(新建)、`edit`(改单个事项)、`command`(AI 总入口,目前仅 iOS/Android 有——携带全部待办列表;客户端必须校验 uuid 在列表内,且返回后用**最新**列表重新匹配)。iOS/Android 把 prompt 拆为 taskSchema + taskRules 拼装,web 仍是整段 `_FORMAT_AND_RULES`,文字内容一致。错误文案("未配置 DeepSeek API key…"/"调用 DeepSeek 失败:…"/"无法解析:…")三端一致。改 prompt 时同步三端。

**iOS/Android 已对齐的 AI 协议**(web 演示版仍是旧的 parse/edit):`command` 为 `{"actions": [create/update/complete/delete, ...]}` 数组协议(批量、完成、删除),关键信息缺失时返回 `{"question", "options"}` 反问,批量/完成/删除过确认页、单条新建/修改直达表单;`suggestDuration`/`updateMemory`(时长记忆)、`summarizeToday`(汇总正文)、`weeklyInsight`(完成洞察)、`suggestReschedule`(改期候选)双端同语义同 prompt。时长记忆文件:iOS 在 Application Support,Android 在 filesDir(`DurationMemory`)。多 AI 服务商(DeepSeek 默认/OpenAI/通义/Kimi/智谱/自定义,key 按服务商分存)与 AI 个性(默认无/四预设/自定义,仅注入反问/汇总/洞察)双端一致。仍为 iOS 独有:苹果智能(Foundation Models 端侧,`FoundationModelsClient`)、桌面小组件、Siri App Intents、应用内实时语音听写(Android 用系统 RecognizerIntent 对话框代替;agent 入口 iOS 是主页下拉、Android 是顶栏 ✨ 按钮;Android 汇总正文在触发时现算,iOS 是前台排定时的快照)。

## 各端架构差异(有意为之,勿"统一")

- **提醒引擎**:web 靠页面轮询;iOS 预排 8 条本地通知链(`NotificationManager`,完成/稍等时 rebuild);Android 每事项只挂**一个**精确闹钟,`ReminderReceiver` 触发时发通知→markNotified 入库→重排下一个,自我延续(requestCode = uuid.hashCode())。Android 的完成/稍等两条路径(界面按钮、通知按钮)都走 `TaskRepository`。
- **iOS 分层**:`LodoCore` 是纯 Swift SPM 包(无 UI 依赖),app 层的 `TaskItem`(SwiftData)与 `TaskData` 互转后调用调度器。Android 对应:`com.lodo.app.core` 保持纯 Kotlin/JVM(无 Android import),`TaskEntity`(Room)↔`TaskData` 互转。**不要往 core 里引平台依赖**,否则单测跑不了。
- **API key 存储**:web 用 `web/.env`;iOS 用钥匙串(`KeychainHelper`);Android 用 AndroidKeyStore AES/GCM 加密后存 DataStore(`KeystoreCipher`)。
- **iOS 26 接入模式**:部署目标保持 iOS 17/macOS 14,新 API 一律 `#available(iOS 26.0, macOS 26.0, *)` 运行时门控 + 旧写法回退(见 `ios/Lodo/Views/LiquidGlass.swift`、`ContentView.swift` 的三级门控)。Liquid Glass 只用于独立主操作和系统 chrome,List 行内按钮保持 bordered。
- **编辑保存**都会重置 phase=start、nextRemindAt=remindAt;Android 的 `applyEdit` 有 PENDING 守卫。
- **Xcode 工程用文件夹同步组**:`ios/Lodo/` 下新增文件自动纳入 app target,`ios/LodoWidget/` 归小组件 target,无需改 pbxproj。`ios/Support/` 放两个 target 的 Info.plist 与 entitlements(不在同步组内)。
- **iOS 小组件(LodoWidgetExtension,仅 iOS)**:SwiftData 库放 App Group `group.com.lodo.app`(`AppGroup.storeURL`,首启从默认位置迁移);app 侧 `WidgetBridge.sync` 在每次数据变更后把"即将到来"快照写进 App Group 并刷新小组件;小组件右侧"+"通过 `lodo://add` 深链弹出快速添加页。app 的 entitlements 只挂 iPhone SDK,macOS 无签名要求也能访问 Group Container。
