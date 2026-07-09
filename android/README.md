# lodo Android 版

Kotlin + Jetpack Compose + Material 3 实现的 lodo 提醒事项应用,功能与 `ios/` 版对齐(省略了 iOS 特有的系统"提醒事项"同步标签页):

- 待办事项 CRUD,支持全天事项、每天/每周多时间点重复、有时长事项的开始→结束两阶段提醒
- 纠缠式提醒:到期后不管是点"稍等一会"还是直接忽略,都会每隔一个稍等间隔再次提醒,直到完成
- 通知上的 完成 / 稍等一会 按钮与 app 内按钮走同一套业务逻辑
- 每日待办汇总通知(可选)
- DeepSeek 自然语言创建与编辑事项(需自备 API key)

## 构建

本目录是标准 Gradle 项目(Gradle 8.11.1 wrapper 已内置),用 **Android Studio**(自带 JDK 17,Ladybug 或更新版本)打开即可:

1. Android Studio → Open → 选择本 `android/` 目录,等待 Gradle sync 完成(首次会下载 Gradle 发行版和依赖)。
2. 跑单元测试(调度器逻辑,1:1 移植自 iOS LodoCoreTests):
   ```
   ./gradlew :app:testDebugUnitTest
   ```
3. 构建安装包:
   ```
   ./gradlew :app:assembleDebug
   ```
   产物在 `app/build/outputs/apk/debug/`,或直接在 Studio 里点 Run 装到真机/模拟器。

最低支持 Android 8.0(API 26),target API 35。

## 首次运行

- Android 13+ 会弹通知权限请求,请允许,否则收不到提醒。
- Android 12/12L 上如果在系统设置里关闭了「闹钟和提醒」权限,提醒会降级为最多延迟 10 分钟的非精确闹钟;设置页会出现开启入口。
- 要使用 AI 自然语言创建/编辑,在「设置 → AI(DeepSeek)」里填入 DeepSeek API key(`sk-…`),key 经 AndroidKeyStore 加密后存储在本机。

## 手工验证清单

- 新建一个 1 分钟后的事项 → 到点收到通知;点「稍等一会」或直接忽略,过一个稍等间隔(默认 15 分钟,设置里可改)再次提醒;点「完成」后不再提醒。
- 有时长的事项:先提醒"该开始了",点「开始了」后在时长结束时再提醒"时间到 — 完成了吗?"。
- 重复事项完成一次后仍留在待办列表,并显示下一次提醒时间;"已完成"列表里多一条历史记录。
- 重启手机后提醒仍能触发(BootReceiver 重排闹钟)。

## 结构

```
app/src/main/java/com/lodo/app/
├── core/      调度纯逻辑(无 Android 依赖,对应 ios/LodoCore),JVM 单测覆盖
├── data/      Room 持久化、DataStore 设置、TaskRepository 业务层
├── ai/        DeepSeek 客户端 + AndroidKeyStore 加密
├── notify/    精确闹钟 + 通知引擎(自续链式提醒)
└── ui/        Compose Material 3 界面(待办 / 设置)
```
