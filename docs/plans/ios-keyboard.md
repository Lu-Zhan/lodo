# lodo iOS 键盘(中文拼音 + AI 键)实施计划

状态:代码已实现(2026-09-26),待真机与模拟器键盘界面验收。分支 `agent-first`。

## 目标

- 给 lodo 加一个 iOS 自定义键盘扩展,先做**中文拼音全键盘**,外观参考系统键盘,支持 iOS 26/27 的 Liquid Glass 风格。
- 候选栏**最左边一颗 AI 键**:点开 AI 输入框,能查询 lodo 里的内容(记忆库/任务),把总结结果写进**剪贴板**。
- AI 输入框里说"记一下 xxx""待办 xxx"这类录入型的话,**直接在 lodo 里形成**记忆/任务,结果卡片参考现有 AI 助手页的设计。

## 总体架构

键盘扩展**不直接打开 SwiftData 数据库**,沿用 Share 扩展/小组件的路子,经 App Group(`group.com.lodo.app`)交换数据:

- **读**:主 app 在进后台/回前台时写一份快照 `keyboard-snapshot.json`(记忆条目的标题/摘要/标签/原文摘录 + 未完成任务),键盘只读快照。
- **写**:键盘把「新建任务」「收藏记忆」落进收件箱,主 app 回前台/后台刷新时入库:
  - 记忆:复用现有 `Memory/Inbox`(`text` 类型;新增 `auto` 类型对应 `saveAutoMemory`)。
  - 任务:新收件箱 `Keyboard/Tasks/<uuid>.json`(`ParsedTask` JSON),app 侧走 `TaskActions.create`,通知链/小组件/日历同步照常。

不直接写库的理由:键盘扩展内存上限低;主 app 开着 CloudKit 镜像,两进程同时写有风险;通知链 `NotificationManager` 在 app 里,键盘排不了提醒。

## 步骤

1. **Xcode target**(已完成)
   - `LodoKeyboardExtension`(`com.lodo.app.keyboard`),文件夹同步组 `ios/LodoKeyboard/`,链接 LodoCore,嵌入主 app。
   - `Support/LodoKeyboardInfo.plist`(`com.apple.keyboard-service`,`PrimaryLanguage = zh-Hans`,`RequestsOpenAccess = true`)。
   - `Support/LodoKeyboard.entitlements`(App Group + 钥匙串共享组);主 app 的 `Support/Lodo.entitlements` 加同一个 `keychain-access-groups`(即主 app 现有默认组,已存 key 不受影响)。

2. **拼音引擎(LodoCore 纯逻辑,单测 `PinyinIMETests`)**
   - 音节表与切分:最少切段优先(`xian` 默认「先」)、支持 `'` 分隔、首字母简拼(`zg` → 中国)、末段按前缀匹配。
   - 候选:用户词 → 整句词 → 较短前缀词 → 首音节单字。
   - 组合态:可分段逐次选字,拼完一次性上屏;全音节的上屏结果学进用户词库(下次排前)。

3. **词库生成**
   - `ios/Tools/generate_pinyin_dict.swift`:系统 `CFStringTransform` 给 GB2312 6763 字 + 常用词表注音,叠加高频字排序与常见多音字补充。
   - 产物 `ios/LodoKeyboard/PinyinDictionary.txt`(随扩展打包)。

4. **键盘 UI(`ios/LodoKeyboard/`,SwiftUI)**
   - 候选栏 + QWERTY 三行 + 底行(123 / 🌐 / 空格 / 确认);123 数字页、#+= 符号页,中文标点。
   - 删除长按连删,按键放大气泡,Shift 输英文大写(双击锁定)。
   - iOS 26/27:键盘底板 Liquid Glass、按键大圆角平面键;旧系统回退;版本门控收进封装。
   - 🌐 用系统 `handleInputModeList`。

5. **AI 键与 AI 面板**
   - 候选栏最左 ✨ → 顶部变 AI 输入框,打字进框(不进宿主 app),回车 = 发送。
   - 复用 `DeepSeekClient.command`(同 prompt/协议,开记忆能力);ReAct `search_memory` 在快照上做关键词检索(`MemorySearch.rank`),最多 3 轮。
   - 结果处理:
     - `answer` / `ask_memory` → 总结写进**剪贴板**,卡片带「插入」「重新复制」。
     - `create` 单条 → 默认直接加入 lodo,卡片带 ✕ 撤销(入库前可撤);多条 → 确认清单。
     - `memorize` / `auto_memorize` → 直接收藏,卡片带 ✕ 撤销;`suggest_memorize` → 点「收藏这条」才存。
     - `ask` → 选项按钮,选完带补充重发(同 Watch)。
     - 修改/完成/删除/规划行程 → 提示去 lodo 里做。
   - 没开「允许完全访问」时,AI 面板说明原因与开启路径。

6. **主 app 侧**
   - `Lodo/Core/KeyboardBridge.swift`:写快照 + 镜像 AI 相关设置(服务商/模型/自定义端点/内置 key 开关/思考强度/个性/语言/skill 开关)到 App Group,键盘启动时读回;消费任务收件箱。
   - `ContentView` 回前台/进后台、`RoutineRunner` 后台刷新里挂上。
   - `MemoryPipeline.consumeInbox` 新增 `auto` 类型。
   - 设置页加「lodo 键盘」说明行。

7. **收尾**
   - `swift test`(429 个通过);`xcodebuild` 编 app + 键盘 target(通过);模拟器键盘与 AI 面板截图待验收(当前运行环境缺少 Simulator 图形应用,无法在系统设置中启用第三方键盘)。
   - 更新 CLAUDE.md;不提交,等用户看过。

## 已确认的取舍 / 限制

1. 键盘里新建的任务要**等打开 lodo(或系统后台刷新)才入库、才排上提醒**;卡片如实写「打开 lodo 后生效」。
2. 词库质量不及系统输入法:无第三方词库,靠系统注音 + 高频字/常用词 + 使用学习。
3. 按键属自绘 UI,登记为 CLAUDE.md 里经用户确认的例外(与 `ContactGraphView` 并列)。
4. 键盘里用默认 skill 文本、不带 AI 偏好(那两份在主 app 私有目录)。
5. 完全访问、钥匙串共享、剪贴板、真实联网需真机验证,模拟器只验界面与编译。
