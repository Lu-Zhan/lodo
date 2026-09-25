import Foundation

/// AI 解析/编辑得到的事项字段,创建与编辑表单共用的值包。
public struct ParsedTask: Codable, Equatable {
    public var title: String
    public var remindAt: Date
    public var allDay: Bool
    public var durationMinutes: Int
    public var repeatType: RepeatType
    public var repeatDays: [Int]
    public var repeatTimes: [String]
    /// 这件事属于哪个项目/主题;AI 推断不出来或用户没填时为 nil。
    public var project: String?

    public init(title: String, remindAt: Date, allDay: Bool, durationMinutes: Int,
                repeatType: RepeatType, repeatDays: [Int], repeatTimes: [String],
                project: String? = nil) {
        self.title = title
        self.remindAt = remindAt
        self.allDay = allDay
        self.durationMinutes = durationMinutes
        self.repeatType = repeatType
        self.repeatDays = repeatDays
        self.repeatTimes = repeatTimes
        self.project = project
    }
}

extension ParsedTask {
    /// 从现有事项取当前字段值(编辑表单预填、AI 修改的"现有事项"上下文共用)。
    public init(from task: TaskItem) {
        self.init(title: task.title, remindAt: task.remindAt, allDay: task.allDay,
                  durationMinutes: task.durationMinutes, repeatType: task.repeatType,
                  repeatDays: task.repeatDays, repeatTimes: task.repeatTimes,
                  project: task.project)
    }

    /// 展示用说明文字,如"今天 21:00 · 每天 07:00/21:00 · 45 分钟"——对齐
    /// `TaskItem.caption`/`TaskData.repeatLabel` 的格式,但基于 `remindAt` 本身
    /// (新建/修改提案阶段还没有事项实体,没有"下一次触发"这个概念)。
    public var caption: String {
        var parts = [TaskItem.format(remindAt)]
        if repeatType != .none {
            let times = repeatTimes.joined(separator: "/")
            if repeatType == .daily {
                parts.append("每天 \(times)")
            } else {
                let days = repeatDays.sorted()
                    .map { String(weekdayNames[$0].dropFirst()) }
                    .joined(separator: "、")
                parts.append("每周\(days) \(times)")
            }
        } else if allDay {
            parts.append("全天")
        }
        if durationMinutes > 0 { parts.append("\(durationMinutes) 分钟") }
        return parts.joined(separator: " · ")
    }
}

/// AI 总入口解析出的单个操作。
/// memorize/askMemory/autoMemorize 仅在 command(memoryEnabled: true) 时会出现
/// (iOS/macOS 主 app;Watch 无记忆数据层,不开启)。answer(直接回话)不受任何
/// 开关门控,聊天入口随时可能出现——包括 Watch;webSearchEnabled 只决定它答之前
/// 能不能先联网查一下。
public enum AIAction {
    case create(ParsedTask)
    case update(uuid: String, task: ParsedTask)
    case complete(uuid: String)
    case delete(uuid: String)
    case memorize(text: String)
    case askMemory(question: String)
    /// 与待办/记忆都无关的一般性问题,直接给用户的回答(可能是联网搜索后给出的)。
    case answer(text: String)
    /// AI 主动建议收藏(不是用户明确要求),前端展示成一个"收藏这条"按钮,
    /// 点了才真正落库——和 memorize 的区别是这条不会自动执行。
    case suggestMemorize(text: String)
    /// 用户的长期做事偏好(如"开会默认留 60 分钟"),静默写进 `AgentPreferences`,
    /// 以后每轮 command 都带进 prompt。和 memorize 的区别:那个存的是资料内容本身,
    /// 这个改的是 AI 以后怎么做事。
    case rememberPreference(text: String)
    /// 对话中顺带提到的重点事实/事件(如"班主任喜欢收贺卡"),不是用户明确要求
    /// 收藏,也不需要 suggestMemorize 那样等用户点按钮——直接静默落库,打
    /// `MemoryItem.autoTagName` 区分。title/text 由本轮 command 顺带给出,
    /// 不再像 memorize 那样额外调用一次整理接口,省一次网络请求。
    case autoMemorize(title: String, text: String)
    /// AI 自动规划的一份行程(tripPlanEnabled 时才会出现)。**不直接落库**:
    /// 聊天里展示成规划卡片,用户点「写入行程」才写进「旅行」页。
    case planTrip(TripPlanProposal)
    /// 调整已经记下的某次旅行(travelEnabled 时才会出现):删/加/改行程项。
    /// **直接执行**,结果卡片带撤销——和单条修改待办同一个取舍。
    case editTrip(TripEdit)
}

/// AI 总入口的返回:操作列表、关键信息缺失时的反问(一次可问多道,每道带
/// 选项说明与推荐项),或 ReAct 循环里的中间步骤(还没准备好给最终答案,
/// 先要执行一个只读工具)。
public enum AICommandResult {
    case actions([AIAction])
    case ask([AskQuestion])
    case toolCall(thought: String, tool: AITool)
}

/// ReAct 循环里可调用的只读工具;enum 设计是为了以后加新工具不用改循环机制。
/// 只读是硬性要求——写操作(新建/修改/完成/删除)永远只能是最终答案的一部分,
/// 不能在推理过程中未经确认就被模型自己调用。
public enum AITool {
    case searchMemory(question: String)
    case webSearch(query: String)
    /// 用户直接给了一个链接、需要看链接内容本身(而不是搜关键词)时用;
    /// 与 webSearch 共用 webSearchEnabled 开关与 skill 文案。
    case webFetch(url: String)
    /// 读本机健康数据(步数/睡眠/心率等)的日级汇总,回答"我这周睡得怎么样"
    /// 这类问题。只读且只拿汇总统计——原始逐条记录不出本机,更不进 prompt。
    case readHealth(days: Int)
    /// 读某次旅行的行程,回答"我下周去东京的航班几点"这类问题。
    /// name 为空表示"当前/最近的那次旅行",由调用方决定挑哪一趟。
    case readTrip(name: String)
}

/// 定时任务(`AIRoutine`)跑一次的返回:最终要展示给用户的文字,或
/// ReAct 循环里的中间步骤(先联网查一下再给结果)。工具复用 `AITool`——
/// 定时任务只会用到其中的联网两个,不涉及记忆检索。
public enum AIRoutineOutcome {
    case text(String)
    case toolCall(thought: String, tool: AITool)
}

public enum DeepSeekError: LocalizedError {
    case noKey
    case api(String)
    case parse(String)

    /// 用 AppSettings.language(当前应用内语言)解析,不是隐式污染风险——这些
    /// 错误全部是终态、直接展示给用户的文案(catch 现场只会 .localizedDescription
    /// 展示或丢弃,不会拼回发给 AI 的下一轮请求),不像 caption/repeatLabel 那样
    /// 会被 RoutineRunner 等处拼进 AI prompt,所以不需要显式传参强制调用方决策。
    public var errorDescription: String? {
        let language = AppSettings.language
        switch self {
        case .noKey:
            return LocalizedStrings.text(.ios_core_deepseek_api_key_not_configured_set_it, language: language)
        case .api(let m):
            return LocalizedStrings.text(.ios_core_deepseek_request_failed, language: language)
                + LocalizedStrings.translate(m, language: language)
        case .parse(let m):
            return LocalizedStrings.text(.ios_core_couldn_t_parse, language: language)
                + LocalizedStrings.translate(m, language: language)
        }
    }
}

/// AI 自然语言创建/编辑,prompt 与 web/lodo/ai.py 保持一致。
/// 名称沿用 DeepSeekClient(三端同名),实际服务商/模型由设置决定
/// (均为 OpenAI 兼容接口),默认 DeepSeek。
/// 放进 LodoCore 是为了让 iPhone/Mac 主 App 和 Watch App 共用同一份实现与 prompt,
/// 不需要手动维护两份保持文字一致。
public enum DeepSeekClient {

    /// 与模型往返的时间字段统一格式,四处解析/格式化共用。
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// AI 个性块:只影响面向用户的文字(反问/汇总/洞察),不影响 JSON 结构。
    private static var personaBlock: String {
        guard let persona = AppSettings.agentPersona else { return "" }
        return "\n\n说话风格(仅影响面向用户的文字,不得改变 JSON 结构与字段值):\(persona)"
    }

    /// 用户偏好块:AI 自己在对话里记下的长期做事习惯,只拼进 command
    /// (AI 助手对话入口),不影响 parse/edit/汇总这些后台小请求。
    /// 没记过任何偏好时整段不出现,prompt 与加这个功能之前逐字一致。
    private static var preferencesBlock: String {
        guard let preferences = AgentPreferences.content else { return "" }
        return """


        用户偏好(你以前记下的,除非这次用户明确另说,否则一律遵守):
        \(preferences)
        """
    }

    private static var timeContext: String {
        let now = Date()
        let weekdays = "一二三四五六日"
        let pyWeekday = (Calendar.current.component(.weekday, from: now) + 5) % 7
        let index = weekdays.index(weekdays.startIndex, offsetBy: pyWeekday)
        return "当前时间:\(dateFormatter.string(from: now))(星期\(weekdays[index]))"
    }

    /// 更早对话的摘要块:窗口之外的历史压成一段常驻文字(见
    /// `AgentConversationSummary`),拼在 historyBlock **之前**——时间上更早,
    /// 而且它是背景、逐条历史是近景。没压过摘要时整段不出现,prompt 与加这个
    /// 功能之前逐字一致。单测入口,纯字符串拼接不依赖网络。
    static func summaryBlock(_ summary: String?) -> String {
        guard let summary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return """


        更早对话的摘要(更久以前聊过的,已经压缩过;对话历史里找不到的上下文从这里找):
        \(summary)
        """
    }

    /// 对话历史块:多轮聊天用,拼进 command() 的 system prompt。
    /// 空历史返回空字符串(单测入口,纯字符串拼接不依赖网络)。
    static func historyBlock(_ history: [(role: String, content: String)]) -> String {
        guard !history.isEmpty else { return "" }
        let lines = history.map { "\($0.role == "user" ? "用户" : "助手"):\($0.content)" }
            .joined(separator: "\n")
        return """


        对话历史(供理解上下文用,不要重复执行历史里已经完成的操作):
        \(lines)
        """
    }

    /// project 复用规则,拼在 `.todo` skill 内容后面;与 memorize() 的 tagRule
    /// 同一个套路——existingProjects 非空才提示,鼓励复用已有项目名而不是随口
    /// 造新的。默认空数组时不追加任何文字,调用方(如 Watch)行为不变。
    private static func projectRule(_ existingProjects: [String]) -> String {
        guard !existingProjects.isEmpty else { return "" }
        return """


        - 已有项目:\(existingProjects.prefix(50).joined(separator: "、"))。\
        project 优先从已有项目中选用语义相近的,都不合适时才创建新项目;\
        实在看不出属于哪个项目就留空字符串,不要瞎猜。
        """
    }

    /// 自然语言 → 新事项字段。existingProjects:当前已使用过的项目名,AI 优先
    /// 复用相近的已有项目,和 memorize() 的 existingTags 同一个思路。
    public static func parse(
        _ text: String, existingProjects: [String] = []
    ) async throws -> ParsedTask {
        let system = """
        你是提醒事项应用 lodo 的解析助手。用户会用自然语言描述一个提醒事项,\
        你需要解析出结构化信息,只返回 JSON,不要任何其他文字。

        \(timeContext)

        返回格式(不适用的字段用默认值):
        \(AgentSkillStore.content(for: .todo))\(projectRule(existingProjects))
        """
        return try parseTask(await payload(system: system, user: text))
    }

    /// 按自然语言指令修改现有事项;未提到的字段保持原值。
    public static func edit(
        _ current: ParsedTask, instruction: String, existingProjects: [String] = []
    ) async throws -> ParsedTask {
        let system = """
        你是提醒事项应用 lodo 的编辑助手。给定一个现有事项和用户的修改指令,\
        输出修改后的完整事项,只返回 JSON,不要任何其他文字。\
        用户没有提到的字段一律保持原值;无法理解指令时返回 {"error": "原因"}。

        \(timeContext)

        现有事项:
        \(json(taskFields(of: current)))

        返回格式(不适用的字段用默认值):
        \(AgentSkillStore.content(for: .todo))\(projectRule(existingProjects))
        """
        return try parseTask(await payload(system: system, user: instruction))
    }

    /// AI 总入口:给定当前待办列表,把用户的一句话解析成一组操作
    /// (新建/修改/完成/删除,可多条),或在关键信息缺失时反问。
    /// memoryEnabled 开启后额外拼入记忆 skill(收藏/查记忆);默认关闭,
    /// Watch 等无记忆数据层的调用方不会看到记忆相关指令。webSearchEnabled 开启后
    /// 额外拼入联网搜索 skill(配置了 Tavily key 才开启);两者独立,拼接顺序
    /// 对所有调用方一致(详见 `AgentSkillStore`)。这是"AI 助手"对话入口,
    /// 按设置里的思考强度传 reasoning_effort(thinking: true),不影响解析/汇总
    /// 等其他后台小请求的响应速度。
    public static func command(
        _ text: String, tasks allTasks: [(uuid: String, task: ParsedTask)],
        memoryEnabled: Bool = false,
        webSearchEnabled: Bool = false,
        healthEnabled: Bool = false,
        travelEnabled: Bool = false,
        tripPlanEnabled: Bool = false,
        history: [(role: String, content: String)] = [],
        /// 更早对话的摘要;默认 nil ⇒ 整段不出现,Watch 等调用方 prompt 逐字不变。
        summary: String? = nil,
        existingProjects: [String] = [],
        /// 非 nil 时走 SSE 流式,把 `answer` 正文边收边吐给调用方(全文,不是增量)。
        /// 默认 nil ⇒ 走原来的一次性请求,Watch 等调用方行为不变。
        onStream: ((String) -> Void)? = nil,
        /// 推理模型先吐的思考过程,喂给"思考中…"那条轻量提示。
        onReasoning: ((String) -> Void)? = nil
    ) async throws -> AICommandResult {
        // token 预算:调用方按 nextRemindAt 排序传入,只带最近 50 条进 prompt
        let tasks = Array(allTasks.prefix(50))
        let list = tasks.map { entry -> [String: Any] in
            var fields = taskFields(of: entry.task)
            fields["uuid"] = entry.uuid
            return fields
        }
        let system = """
        \(AgentSkillStore.content(for: .agent))

        \(AgentSkillStore.content(for: .todo))\(projectRule(existingProjects))\
        \(memoryEnabled ? "\n\n" + AgentSkillStore.content(for: .memory) : "")\
        \(webSearchEnabled ? "\n\n" + AgentSkillStore.content(for: .webSearch) : "")\
        \(healthEnabled ? "\n\n" + AgentSkillStore.content(for: .health) : "")\
        \(travelEnabled ? "\n\n" + AgentSkillStore.content(for: .travel) : "")\
        \(tripPlanEnabled ? "\n\n" + AgentSkillStore.content(for: .tripPlanner) : "")

        \(timeContext)\(preferencesBlock)

        当前待办列表:
        \(json(list))\(personaBlock)\(summaryBlock(summary))\(historyBlock(history))
        """
        // 模型按 prompt 约定用 {"error": "原因"} 表示"这句话里没有我能执行的操作"
        // (带了张照片却没说要拿它干什么就是最常见的一种),decodePayload 会把那句
        // 原因抛成 parse 错误。它是模型想对用户说的话,不是故障——聊天入口渲染成
        // 普通回复气泡,不是红字报错。真正的"没给出可解析 JSON"抛的是固定文案,
        // 仍然按错误处理。
        let raw: [String: Any]
        do {
            raw = try await payload(system: system, user: text, timeout: 90, thinking: true,
                                    tracksUsage: true,
                                    onStream: onStream, onReasoning: onReasoning)
        } catch let DeepSeekError.parse(message)
            where message != malformedPayloadMessage
                && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .actions([.answer(text: message)])
        }
        return try parseCommand(
            raw,
            validUUIDs: tasks.map(\.uuid),
            memoryEnabled: memoryEnabled,
            webSearchEnabled: webSearchEnabled,
            healthEnabled: healthEnabled,
            travelEnabled: travelEnabled,
            tripPlanEnabled: tripPlanEnabled)
    }

    /// 从 payload 里解析总入口结果(单测入口)。
    /// memoryEnabled == false 时 memorize/ask_memory、webSearchEnabled == false 时
    /// web_search/answer、healthEnabled == false 时 read_health、travelEnabled == false
    /// 时 read_trip、tripPlanEnabled == false 时 plan_trip 按未知 action/工具处理
    /// (即使模型幻觉出来,Watch 等调用方也保持旧行为)。
    static func parseCommand(
        _ payload: [String: Any], validUUIDs: [String],
        memoryEnabled: Bool, webSearchEnabled: Bool = false,
        healthEnabled: Bool = false, travelEnabled: Bool = false,
        tripPlanEnabled: Bool = false
    ) throws -> AICommandResult {
        if let rawAsk = payload["ask"] as? [[String: Any]], !rawAsk.isEmpty {
            return .ask(try parseAsk(rawAsk))
        }
        // ReAct 中间步骤:对应开关关闭时 prompt 里根本没提过这个选项,
        // 模型幻觉出来也不认——落到下面 actions 解析,大概率报"缺少 actions",无害。
        if (memoryEnabled || webSearchEnabled || healthEnabled || travelEnabled),
           let toolName = payload["tool"] as? String {
            guard let call = try parseToolCall(
                payload, name: toolName, memoryEnabled: memoryEnabled,
                webSearchEnabled: webSearchEnabled, healthEnabled: healthEnabled,
                travelEnabled: travelEnabled) else {
                throw DeepSeekError.parse("返回格式异常:未知工具 \(toolName)")
            }
            return call
        }
        var rawActions = payload["actions"] as? [[String: Any]] ?? []
        // 模型偶尔把单条操作直接摊在顶层({"action": "edit_trip", …}),忘了外面那层
        // actions 数组——prompt 里每条操作的示例本来就长这样,漏掉外壳很常见。
        // 当成只有一条操作的列表处理,比报"缺少 actions"有用。
        if rawActions.isEmpty, payload["action"] is String {
            rawActions = [payload]
        }
        guard !rawActions.isEmpty else {
            // 没有任何操作、却捎了一句话回来(实测形如 {"actions": [], "reply": "…"},
            // 键名随模型心情换):这是它在回话,不是故障。当成 answer 渲染成气泡,
            // 比红字"缺少 actions"有用。带附件时最常碰上——照片里有内容,可用户
            // 那句话没让它做什么,它就只好聊两句。
            if let reply = ["reply", "answer", "text", "message", "response", "content"]
                .compactMap({ payload[$0] as? String })
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                return .actions([.answer(text: reply)])
            }
            throw DeepSeekError.parse("返回格式异常:缺少 actions")
        }
        // 反过来:ReAct 工具在 prompt 里是顶层对象,模型也会把它塞进 actions 数组
        // ({"actions": [{"action": "read_trip", "name": "北海道"}]})。认得出来就按
        // 工具调用处理——否则它撞上下面的"未知 action",整条请求当场报错,而"先读
        // 一次行程/健康数据再回答"这类请求本来就必须走这一步,等于整个走不通。
        if rawActions.count == 1,
           let toolName = (rawActions[0]["tool"] as? String) ?? (rawActions[0]["action"] as? String),
           let call = try parseToolCall(
               rawActions[0], name: toolName, memoryEnabled: memoryEnabled,
               webSearchEnabled: webSearchEnabled, healthEnabled: healthEnabled,
               travelEnabled: travelEnabled) {
            return call
        }
        var actions: [AIAction] = []
        for raw in rawActions {
            func validUUID() throws -> String {
                guard let uuid = raw["uuid"] as? String,
                      validUUIDs.contains(uuid) else {
                    throw DeepSeekError.parse("找不到要操作的事项")
                }
                return uuid
            }
            switch raw["action"] as? String {
            case "create":
                actions.append(.create(try parseTask(raw)))
            case "update":
                actions.append(.update(uuid: try validUUID(), task: try parseTask(raw)))
            case "complete":
                actions.append(.complete(uuid: try validUUID()))
            case "delete":
                actions.append(.delete(uuid: try validUUID()))
            case "memorize" where memoryEnabled:
                let text = (raw["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:收藏内容为空")
                }
                actions.append(.memorize(text: text))
            case "suggest_memorize" where memoryEnabled:
                let text = (raw["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:建议收藏内容为空")
                }
                actions.append(.suggestMemorize(text: text))
            case "auto_memorize" where memoryEnabled:
                let title = (raw["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let text = (raw["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty, !text.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:自动记录内容为空")
                }
                actions.append(.autoMemorize(title: title, text: text))
            case "remember_preference":
                let text = (raw["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:偏好内容为空")
                }
                actions.append(.rememberPreference(text: text))
            case "ask_memory" where memoryEnabled:
                let question = (raw["question"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !question.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:查询问题为空")
                }
                actions.append(.askMemory(question: question))
            // answer 不受 webSearchEnabled 门控:"直接回话"是聊天入口的基本能力,
            // 和有没有配 Tavily 搜索 key 无关。原来绑在一起时,没配 key 的用户
            // 一句闲聊就会让模型交白卷({"actions": []}),前端只能报错。
            case "answer":
                let text = (raw["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:回答内容为空")
                }
                actions.append(.answer(text: text))
            case "plan_trip" where tripPlanEnabled:
                actions.append(.planTrip(try parseTripPlan(raw)))
            case "edit_trip" where travelEnabled:
                actions.append(.editTrip(try parseTripEdit(raw)))
            default:
                // 带上 action 名:模型编出来的名字是排查这类报错唯一的线索,
                // 光说"未知 action"用户和日志都看不出它到底返回了什么。
                let name = (raw["action"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw DeepSeekError.parse(
                    name.isEmpty ? "返回格式异常:未知 action" : "返回格式异常:未知 action \(name)")
            }
        }
        // 归一化:prompt 已要求问答类操作(ask_memory/answer)单独出现,这里是模型
        // 不守规矩时的确定性兜底——问答与写操作混合时丢弃问答只留写操作(写操作是
        // 用户要落地的事不能丢,查询可以重问);全是问答时只留第一条。
        // plan_trip 归这一组:它本身不落库、要用户在卡片上确认,和建议收藏同性质。
        // edit_trip 虽然会落库,也归这一组——它要求单独出现、有自己的结果卡片和撤销,
        // 混进批量确认清单里既没有卡片也撤销不了;混着待办写操作时丢掉,用户单独再说一遍。
        func isInformational(_ action: AIAction) -> Bool {
            switch action {
            case .askMemory, .answer, .suggestMemorize, .planTrip, .editTrip: return true
            default: return false
            }
        }
        let informationalCount = actions.filter(isInformational).count
        if informationalCount > 0 {
            if informationalCount == actions.count {
                return .actions([actions[0]])
            }
            actions = actions.filter { !isInformational($0) }
        }
        return .actions(actions)
    }

    /// ReAct 工具载荷 → 工具调用;不认得这个名字(或对应能力没开)时返回 nil,
    /// 由调用方决定是报"未知工具"还是继续当普通 action 解析。顶层 `{"tool": …}`
    /// 和被模型误塞进 actions 数组里的那一份共用这一段。
    private static func parseToolCall(
        _ raw: [String: Any], name: String,
        memoryEnabled: Bool, webSearchEnabled: Bool,
        healthEnabled: Bool, travelEnabled: Bool
    ) throws -> AICommandResult? {
        let thought = (raw["thought"] as? String) ?? ""
        switch name {
        case "search_memory" where memoryEnabled:
            guard let query = (raw["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw DeepSeekError.parse("返回格式异常:search_memory 缺少 query")
            }
            return .toolCall(thought: thought, tool: .searchMemory(question: query))
        case "web_search" where webSearchEnabled:
            guard let query = (raw["query"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                throw DeepSeekError.parse("返回格式异常:web_search 缺少 query")
            }
            return .toolCall(thought: thought, tool: .webSearch(query: query))
        case "web_fetch" where webSearchEnabled:
            guard let url = (raw["url"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                throw DeepSeekError.parse("返回格式异常:web_fetch 缺少 url")
            }
            return .toolCall(thought: thought, tool: .webFetch(url: url))
        case "read_health" where healthEnabled:
            // days 缺省按一周算——模型经常只说"看看我的健康数据",没必要
            // 因为少一个字段就报错重来。
            let days = (raw["days"] as? Int) ?? Int(raw["days"] as? String ?? "") ?? 7
            guard days > 0 else {
                throw DeepSeekError.parse("返回格式异常:read_health 缺少 days")
            }
            return .toolCall(thought: thought, tool: .readHealth(days: min(days, 90)))
        case "read_trip" where travelEnabled:
            // name 缺省 = "当前/最近那次旅行",由调用方挑;这里不当成错误。
            let name = (raw["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .toolCall(thought: thought, tool: .readTrip(name: name))
        default:
            return nil
        }
    }

    /// `plan_trip` 单条载荷 → 规划(单测入口)。和 parseTravelPayload 同一个取舍:
    /// 单条安排解析不出来(缺标题、类型不认识、给了航班)就跳过那条,不让整份规划
    /// 白费;但**一条可用安排都没有**、或者**连日期都推不出来**就报错——那样的卡片
    /// 写不进任何一天。
    static func parseTripPlan(_ raw: [String: Any]) throws -> TripPlanProposal {
        func text(_ key: String) -> String? {
            guard let value = (raw[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let rawItems = raw["items"] as? [[String: Any]] ?? []
        let items = rawItems.prefix(60).compactMap(parsePlanItem)
        guard !items.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:行程规划没有任何安排")
        }
        // 起止日优先用模型给的;没给就从安排的时间里推,再推不出来才报错。
        let starts = items.compactMap(\.start)
        let ends = items.compactMap { $0.end ?? $0.start }
        guard var startDate = text("start_date").flatMap(planDate) ?? starts.min(),
              var endDate = text("end_date").flatMap(planDate) ?? ends.max() ?? starts.max() else {
            throw DeepSeekError.parse("返回格式异常:行程规划缺少日期")
        }
        if endDate < startDate { swap(&startDate, &endDate) }
        return TripPlanProposal(
            tripTitle: text("trip") ?? "旅行规划",
            startDate: startDate, endDate: endDate,
            summary: text("summary") ?? "", items: items)
    }

    /// 规划/调整里的一条安排。只认地点和住宿:模型不守规矩给了 flight 也丢掉,
    /// 航班编不出来;缺标题、类型不认识的同样跳过。
    private static func parsePlanItem(_ item: [String: Any]) -> TripPlanItem? {
        func field(_ key: String) -> String? {
            guard let value = (item[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        guard let kind = field("kind").flatMap(TravelItemKind.init(rawValue:)),
              kind != .flight,
              let title = field("title") else { return nil }
        let price: Double? = {
            if let value = item["price"] as? Double { return value }
            if let value = item["price"] as? Int { return Double(value) }
            return field("price").flatMap(Double.init)
        }()
        let start = field("start").flatMap(planDate)
        var end = field("end").flatMap(planDate)
        if let s = start, let e = end, e < s { end = nil }
        return TripPlanItem(
            kind: kind, title: title, note: field("note") ?? "",
            start: start, end: end, placeName: field("place"),
            price: price, currency: field("currency")?.uppercased())
    }

    /// `edit_trip` 单条载荷 → 调整(单测入口)。id 不是合法 UUID 的删/改直接跳过
    /// (是不是这次旅行里的项要到 app 层对着库才知道,那边再报"找不到");
    /// 删、加、改**一样都没有**才报错。
    static func parseTripEdit(_ raw: [String: Any]) throws -> TripEdit {
        func text(_ dict: [String: Any], _ key: String) -> String? {
            guard let value = (dict[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func uuid(_ string: String) -> UUID? {
            // 模型偶尔会把读到的 "[id:xxx]" 连前缀一起抄回来。
            var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[id:") { trimmed = String(trimmed.dropFirst(4)) }
            if trimmed.hasPrefix("id:") { trimmed = String(trimmed.dropFirst(3)) }
            if trimmed.hasSuffix("]") { trimmed = String(trimmed.dropLast()) }
            return UUID(uuidString: trimmed)
        }
        var removeIDs: [UUID] = []
        for case let string as String in raw["remove"] as? [Any] ?? [] {
            if let id = uuid(string), !removeIDs.contains(id) { removeIDs.append(id) }
        }
        let additions = (raw["add"] as? [[String: Any]] ?? []).prefix(30).compactMap(parsePlanItem)
        let updates: [TripEditUpdate] = (raw["update"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = text(entry, "id").flatMap(uuid) else { return nil }
            let start = text(entry, "start").flatMap(planDate)
            var end = text(entry, "end").flatMap(planDate)
            if let s = start, let e = end, e < s { end = nil }
            let update = TripEditUpdate(
                id: id, title: text(entry, "title"), note: text(entry, "note"),
                start: start, end: end, placeName: text(entry, "place"))
            return update.isEmpty ? nil : update
        }
        // 同一项既删又改:以删为准,改那条丢掉。
        let removed = Set(removeIDs)
        let edit = TripEdit(
            tripTitle: text(raw, "trip") ?? "", summary: text(raw, "summary") ?? "",
            removeIDs: removeIDs,
            additions: Array(additions),
            updates: updates.filter { !removed.contains($0.id) })
        guard !edit.removeIDs.isEmpty || !edit.additions.isEmpty || !edit.updates.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:行程调整没有任何改动")
        }
        return edit
    }

    /// 规划里的日期:"yyyy-MM-dd HH:mm" 或只有日期的 "yyyy-MM-dd"。
    private static func planDate(_ string: String) -> Date? {
        if let date = dateFormatter.date(from: string) { return date }
        return dayFormatter.date(from: string)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 反问载荷 → 题目列表(单测入口)。模型不守规矩时按确定性规则收敛,而不是
    /// 整个请求报错:题目最多 4 道、每题选项最多 6 个,问题文案为空或一个选项都
    /// 没有的题目直接丢弃;全丢光才报错(这时候卡片没东西可展示,继续下去更糟)。
    static func parseAsk(_ rawQuestions: [[String: Any]]) throws -> [AskQuestion] {
        var questions: [AskQuestion] = []
        for raw in rawQuestions.prefix(4) {
            let text = (raw["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            let options = ((raw["options"] as? [[String: Any]]) ?? []).prefix(6)
                .compactMap { rawOption -> AskOption? in
                    let label = (rawOption["label"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !label.isEmpty else { return nil }
                    return AskOption(
                        label: label,
                        description: (rawOption["description"] as? String) ?? "",
                        recommended: (rawOption["recommended"] as? Bool) ?? false)
                }
            guard !options.isEmpty else { continue }
            questions.append(AskQuestion(
                header: (raw["header"] as? String) ?? "",
                question: text,
                multiSelect: (raw["multi_select"] as? Bool) ?? false,
                options: options))
        }
        guard !questions.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:ask 缺少可用问题")
        }
        return questions
    }

    /// 按记忆文件为"没说时长"的新事项建议时长(分钟);
    /// 用户明确表示不需要时长、或记忆无相近类型时返回 0。
    public static func suggestDuration(text: String, title: String,
                                       memory: String) async throws -> Int {
        let system = """
        你是提醒事项应用 lodo 的时长建议助手。下面是"事项类型 → 典型时长"的记忆文件、\
        用户创建事项的原话和解析出的事项标题,只返回 JSON,不要任何其他文字。

        判断规则:
        - 用户原话明确表示不需要时长,或记忆中没有类型相近的条目 → {"duration_minutes": 0}
        - 否则参考记忆中相近类型的典型时长 → {"duration_minutes": 分钟数}

        记忆文件:
        \(memory)
        """
        let payload = try await payload(system: system, user: "原话:\(text)\n标题:\(title)")
        return payload["duration_minutes"] as? Int ?? 0
    }

    /// 逾期事项的改期候选:2-3 个(口语化标签, 时间),时间必须晚于当前。
    public static func suggestReschedule(
        title: String, remindAt: Date, durationMinutes: Int, isRecurring: Bool
    ) async throws -> [(label: String, date: Date)] {
        var info = "事项:\(title)\n原提醒时间:\(dateFormatter.string(from: remindAt))"
        if durationMinutes > 0 { info += ",时长 \(durationMinutes) 分钟" }
        if isRecurring { info += ",重复事项(只顺延本次)" }
        let system = """
        你是提醒事项应用 lodo 的改期助手。一个事项已到期未完成,给出 2-3 个合理的\
        新提醒时间候选:按常理选时段(工作事项选工作时间,生活事项可选晚上或周末),\
        时间必须晚于当前时间。只返回 JSON,不要任何其他文字:
        {"candidates": [{"label": "口语化标签,如 今晚 20:00", "time": "YYYY-MM-DD HH:MM"}, ...]}

        \(timeContext)

        \(info)
        """
        let payload = try await payload(system: system, user: "给出改期候选")
        guard let raw = payload["candidates"] as? [[String: Any]] else {
            throw DeepSeekError.parse("返回格式异常:缺少 candidates")
        }
        let now = Date()
        let candidates = raw.compactMap { item -> (label: String, date: Date)? in
            guard let label = item["label"] as? String,
                  let timeString = item["time"] as? String,
                  let date = dateFormatter.date(from: timeString), date > now else { return nil }
            return (label, date)
        }
        guard !candidates.isEmpty else {
            throw DeepSeekError.parse("没有可用的改期候选")
        }
        return candidates
    }

    /// 每周完成洞察:把本地统计说成一句正向鼓励的话(不打分、不指责)。
    public static func weeklyInsight(stats: String) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的回顾助手。根据一周完成统计,输出一句不超过 60 个字的\
        正向洞察:语气鼓励,肯定进步,并给一个具体可行的小建议;禁止任何指责性表述,\
        禁止出现"拖延""失败"等词。只返回 JSON:{"insight": "一句话"},不要任何其他文字。\(personaBlock)
        """
        let payload = try await payload(system: system, user: stats, timeout: 60)
        guard let insight = payload["insight"] as? String,
              !insight.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 insight")
        }
        return insight
    }

    /// "总览" tab 用:给一句今天待办的处理建议(到期未处理的 + 今天该做的都算,
    /// 调用方把列表格式化成 summary 传进来)。
    public static func suggestTodayHandling(summary: String) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的今日助手。根据今天的待办列表(可能含到期未处理的),\
        给一句不超过 60 个字的处理建议:侧重优先级和取舍,具体可执行,\
        不要"合理安排时间"这类空话。只返回 JSON:{"suggestion": "一句话"},不要任何其他文字。\(personaBlock)
        """
        let payload = try await payload(system: system, user: summary, timeout: 60)
        guard let suggestion = payload["suggestion"] as? String,
              !suggestion.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 suggestion")
        }
        return suggestion
    }

    /// "总览" tab 用:给一句今天新收藏的记忆总结(调用方把标题+摘要格式化成
    /// summary 传进来)。
    public static func summarizeTodayMemories(summary: String) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的记忆助手。根据今天新收藏的记忆条目(标题+摘要),\
        用一句不超过 60 个字的话总结今天收藏了什么、有没有共同点或值得注意的地方。\
        只返回 JSON:{"summary": "一句话"},不要任何其他文字。\(personaBlock)
        """
        let payload = try await payload(system: system, user: summary, timeout: 60)
        guard let text = payload["summary"] as? String,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 summary")
        }
        return text
    }

    /// "总览" tab 用:给一句今天的健康提示(调用方把 HealthReport.promptSummary()
    /// 传进来)。和 suggestTodayHandling 同构——一句话、按天缓存、失败就不显示。
    public static func suggestTodayHealth(summary: String) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的健康助手。根据最近几天的健康数据汇总,\
        给一句不超过 60 个字的提示:指出一个最值得注意的变化,并给一个具体可做的小建议,\
        不要"注意身体""保持健康"这类空话。你不是医生,不做诊断、不提药物;\
        数据明显异常时提示去看医生即可。只返回 JSON:{"suggestion": "一句话"},不要任何其他文字。\(personaBlock)
        """
        let payload = try await payload(system: system, user: summary, timeout: 60)
        guard let suggestion = payload["suggestion"] as? String,
              !suggestion.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 suggestion")
        }
        return suggestion
    }

    /// "健康" 页用:一段分析正文 + 最多 3 条建议。memoryContext 是记忆库里打了
    /// 「健康」标签的条目(体检报告、用药、饮食记录这些用户自己收藏的资料),
    /// 没有就不传——健康数据本身已经够看了,别为了凑上下文硬塞。
    public static func analyzeHealth(
        summary: String, memoryContext: String? = nil
    ) async throws -> HealthAnalysis {
        let system = """
        你是提醒事项应用 lodo 的健康助手。根据用户最近几天的健康数据汇总\
        (可能附带用户自己收藏的健康资料),写一段不超过 150 个字的分析:\
        说清楚哪些指标在变好、哪些在变差、可能的原因,再给最多 3 条具体可执行的建议。\
        你不是医生:不做诊断、不推荐药物、不解读化验值的临床意义;\
        发现明显异常时,请建议用户去看医生。\
        只返回 JSON:{"analysis": "一段话", "suggestions": ["建议1", "建议2"]},不要任何其他文字。\(personaBlock)
        """
        let user = memoryContext.map { "\(summary)\n\n用户收藏的健康资料:\n\($0)" } ?? summary
        return try parseHealthAnalysis(await payload(system: system, user: user, timeout: 90))
    }

    /// 从 payload 里解析健康分析结果(单测入口,不发请求)。
    static func parseHealthAnalysis(_ payload: [String: Any]) throws -> HealthAnalysis {
        guard let analysis = (payload["analysis"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !analysis.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 analysis")
        }
        let suggestions = (payload["suggestions"] as? [Any] ?? [])
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return HealthAnalysis(analysis: analysis, suggestions: Array(suggestions.prefix(3)))
    }

    /// 把一段订单/确认单文本(订票邮件、酒店确认信、行程单,或 PDF 提取出的正文)
    /// 解析成若干行程项。和 `parse`(新建待办)一样是"给一段自然语言、要一份结构化
    /// 字段",区别是一次可能出来好几条(往返机票 + 酒店)。
    ///
    /// 解析结果**不直接落库**:调用方要先展示给用户确认(订单里的日期/金额认错了
    /// 代价不小,不像单条待办那样撤销一下就完事)。
    public static func parseTravelItems(
        text: String, tripTitle: String, tripStart: Date, tripEnd: Date
    ) async throws -> [ParsedTravelItem] {
        let system = """
        你是旅行助手。从用户给的订单/确认单/行程单/登机牌/航班动态文本里,抽取出所有行程项。\
        文本可能是截图 OCR 出来的,会有断行、串行、错字,按常识理解。
        当前这趟旅行叫「\(tripTitle)」,日期范围 \(dateFormatter.string(from: tripStart)) 到 \(dateFormatter.string(from: tripEnd))。

        只返回 JSON:{"items": [行程项, ...]},不要任何其他文字。每个行程项:
        {"kind": "flight|lodging|place", "title": "简短名称", "code": "航班号/订单号,没有就省略", \
        "start": "yyyy-MM-dd HH:mm", "end": "yyyy-MM-dd HH:mm", \
        "place": "主要地点(住宿/地点填它本身,航班填**到达地**)", \
        "origin": "航班的出发地,其余类型省略", \
        "price": 数字, "currency": "ISO 4217 币种码如 CNY/JPY/USD", "note": "补充说明", \
        "flight": 航班补充信息,仅 flight 有,见下}

        航班补充信息(每个字段都是可选的,文本里没有就省略,整个对象都没有就省略 flight):
        {"airline": "航空公司", "departure_code": "出发机场三字码如 PEK", "arrival_code": "到达机场三字码", \
        "departure_terminal": "出发航站楼如 T3", "arrival_terminal": "到达航站楼", \
        "check_in_counter": "值机柜台/值机岛", "gate": "登机口", "boarding_time": "yyyy-MM-dd HH:mm", \
        "estimated_departure": "yyyy-MM-dd HH:mm", "estimated_arrival": "yyyy-MM-dd HH:mm", \
        "seat": "座位号", "cabin": "舱位如 经济舱", "aircraft": "机型如 空客A330", \
        "baggage_belt": "行李转盘", \
        "status": "scheduled|check_in|boarding|gate_closed|departed|delayed|arrived|canceled|diverted"}

        规则:
        - 往返机票是**两条** flight,别合成一条。
        - 航班的 start/end 填**计划**起降时刻;航班动态里显示的变更后/预计时刻填 \
        estimated_departure/estimated_arrival,不要覆盖到 start/end 上。只有预计时刻、\
        看不到计划时刻时省略 start/end。
        - status 只在文本明确写了状态(如"延误""登机中""已取消")时填,别从时间推断。
        - 登机口、座位这些照抄原文,读不清就省略,别猜。
        - 住宿的 start 是入住、end 是退房。
        - 年份没写明时按上面给的旅行日期范围推断,不要凭空用今年。
        - 时间拿不准就省略 start/end,别编一个;金额拿不准就省略 price。
        - 文本里没有任何行程信息时返回 {"items": []}。
        \(personaBlock)
        """
        return try parseTravelPayload(await payload(system: system, user: text, timeout: 90))
    }

    /// 从 payload 里解析行程项列表(单测入口,不发请求)。
    /// 单条解析不出来(缺 kind/标题、日期格式不对)就跳过那条,不让整份订单白费。
    static func parseTravelPayload(_ payload: [String: Any]) throws -> [ParsedTravelItem] {
        guard let rawItems = payload["items"] as? [[String: Any]] else {
            throw DeepSeekError.parse("返回格式异常:缺少 items")
        }
        return rawItems.compactMap { raw in
            guard let kind = (raw["kind"] as? String).flatMap(TravelItemKind.init(rawValue:)),
                  let title = (raw["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return nil
            }
            func text(_ key: String) -> String? {
                guard let value = (raw[key] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
                return value
            }
            func number(_ key: String) -> Double? {
                if let value = raw[key] as? Double { return value }
                if let value = raw[key] as? Int { return Double(value) }
                return (raw[key] as? String).flatMap(Double.init)
            }
            return ParsedTravelItem(
                kind: kind, title: title, code: text("code"),
                start: text("start").flatMap(dateFormatter.date(from:)),
                end: text("end").flatMap(dateFormatter.date(from:)),
                placeName: text("place"), originName: text("origin"),
                price: number("price"),
                // 币种统一大写:模型偶尔会返回小写 "jpy",存下去会和 "JPY" 分成两组。
                currency: text("currency")?.uppercased(),
                note: text("note") ?? "",
                flight: kind == .flight
                    ? FlightDetails.parse(raw["flight"], date: dateFormatter.date(from:)) : nil)
        }
    }

    /// 把一段菜单文字(拍照/截图 OCR 出来的,或用户直接贴进来的)整理成菜品清单,
    /// 并翻译成 `targetLanguage`。和 `parseTravelItems` 同一个形状——给一段自然语言、
    /// 要一份结构化字段,一次出来一批。
    ///
    /// 和订单解析不同,这条路径**不给确认页**:认错一道菜的代价是点错菜,不是错过
    /// 航班,而让用户在餐厅里逐条勾选五十道菜比直接整理完再改要难受得多;整理完
    /// 就落成一条记忆条目,不对就删掉重来。
    public static func parseMenu(
        text: String, targetLanguage: String
    ) async throws -> ParsedMenu {
        let system = """
        你是点餐助手。用户给的是一张菜单上的文字,可能来自拍照/截图的 OCR,\
        会有断行、串行、错字。把它整理成菜品清单,并翻译成\(targetLanguage)。

        只返回 JSON:{"restaurant": "店名,菜单上没印就省略", \
        "language": "菜单原文是什么语言,用\(targetLanguage)说,如 日语;认不出来就省略", \
        "currency": "ISO 4217 币种码如 CNY/JPY/EUR,只有符号认不准就省略", \
        "dishes": [菜品, ...]},不要任何其他文字。每道菜:
        {"original": "菜单上的原文名称,照抄不要翻译", \
        "translated": "\(targetLanguage)译名", \
        "category": "分类如 前菜/主菜/甜点/饮品,用\(targetLanguage)写", \
        "price": 数字, \
        "description": "一句不超过 40 字的介绍:主要食材、做法、口味"}

        规则:
        - 只整理菜品。店名、地址、电话、营业时间、"本店谢绝自带酒水"这类说明文字都不是菜。
        - original 照抄菜单原文,不要把译名写进去;菜单本来就是\(targetLanguage)时,\
        translated 填和 original 一样的文字。
        - category 优先用菜单上印的分类;菜单没分类就按常识归类,归不出来就省略。
        - description 一定要给:菜单只写了菜名、或者名字看不出是什么(如"月见とろろ")时,\
        按常识补全说明这是什么菜;拿不准就在句子里说明是推测,不要编造具体做法。
        - price 只填数字,不带货币符号;菜单没标价就省略 price,不要填 0。
        - OCR 串行、错字明显的按常识修正成合理的菜名,不要原样保留乱码。
        - 一道菜也读不出来时返回 {"dishes": []}。
        \(personaBlock)
        """
        return try parseMenuPayload(await payload(system: system, user: text, timeout: 90))
    }

    /// 从 payload 里解析菜单(单测入口,不发请求)。
    /// 单道菜解析不出来(缺原名)就跳过那道,不让整张菜单白费——和
    /// parseTravelPayload 同一个取舍。
    static func parseMenuPayload(_ payload: [String: Any]) throws -> ParsedMenu {
        guard let rawDishes = payload["dishes"] as? [[String: Any]] else {
            throw DeepSeekError.parse("返回格式异常:缺少 dishes")
        }
        func text(_ raw: [String: Any], _ key: String) -> String? {
            guard let value = (raw[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let dishes = rawDishes.compactMap { raw -> ParsedMenuDish? in
            guard let original = text(raw, "original") ?? text(raw, "translated") else { return nil }
            let price: Double? = {
                if let value = raw["price"] as? Double { return value }
                if let value = raw["price"] as? Int { return Double(value) }
                // 模型偶尔把价格写成 "¥1,200" 这样的串,把非数字字符剥掉再转。
                guard let literal = text(raw, "price") else { return nil }
                let digits = literal.filter { $0.isNumber || $0 == "." }
                return Double(digits)
            }()
            return ParsedMenuDish(
                originalName: original,
                translatedName: text(raw, "translated") ?? "",
                intro: text(raw, "description") ?? "",
                category: text(raw, "category") ?? "",
                price: price)
        }
        return ParsedMenu(
            restaurant: text(payload, "restaurant") ?? "",
            sourceLanguage: text(payload, "language") ?? "",
            // 币种统一大写:模型偶尔会返回小写 "jpy"(同 parseTravelPayload)。
            currency: text(payload, "currency")?.uppercased(),
            dishes: dishes)
    }

    /// 定时任务(`AIRoutine`)到点后跑一次:按用户自己写的指令生成这次要展示的内容。
    /// 和 weeklyInsight/summarizeToday 一样是"薄包装 + 返回一句话 JSON",区别是
    /// 指令来自用户而不是写死的 prompt,并且允许联网——天气/行情这类任务不查就没法做。
    ///
    /// webSearchEnabled 时模型可以先返回一个只读工具调用(web_search/web_fetch),
    /// 由调用方执行完把结果放进 history 再问一轮,机制与 command() 的 ReAct 循环一致
    /// (循环体在 app 层,见 RoutineRunner.run)。写操作在这条路径上根本不存在——
    /// 定时任务只产出文字,不碰待办。
    public static func runRoutine(
        name: String, instruction: String, taskContext: String? = nil,
        locationContext: String? = nil, webSearchEnabled: Bool = false,
        history: [(role: String, content: String)] = []
    ) async throws -> AIRoutineOutcome {
        let tools = webSearchEnabled ? """


        如果需要最新/实时信息(天气、行情、新闻等)才能完成任务,先返回:
        {"thought": "为什么需要查", "tool": "web_search", "query": "要搜索的关键词"}
        指令里给了具体链接、需要看链接内容本身时,改为返回:
        {"thought": "为什么需要看这个链接", "tool": "web_fetch", "url": "链接原样"}
        两者合计最多用两次,拿到结果后必须在下一轮给出最终的 {"text": ...},\
        不能一直用工具占位不给结果。
        """ : ""
        let tasks = taskContext.map { "\n\n今天的待办:\n\($0)" } ?? ""
        let location = locationContext.map { "\n\n当前城市:\($0)" } ?? ""
        let system = """
        你是提醒事项应用 lodo 的定时任务助手。用户预先设定了一条会自动执行的例行任务,\
        现在到了执行时间,你要按用户写的指令生成这一次的内容,直接展示给用户看。

        要求:
        - 只输出这次要说的内容本身,不要复述指令,不要开场白和客套话。
        - 具体、可执行,不说"合理安排时间""注意身体"这类空话。
        - 不超过 120 个字,一段纯文本,不要 markdown 标题或列表符号。
        - 信息不足时按常理给出最有用的内容,不要反问用户——定时任务没有人能回答你。

        只返回 JSON:{"text": "这次要展示给用户的内容"},不要任何其他文字。\(tools)

        \(timeContext)\(preferencesBlock)

        任务名:\(name)\(tasks)\(location)\(personaBlock)\(historyBlock(history))
        """
        return try parseRoutine(await payload(system: system, user: instruction, timeout: 60),
                                webSearchEnabled: webSearchEnabled)
    }

    /// 从 payload 里解析定时任务结果(单测入口)。
    /// webSearchEnabled == false 时 prompt 里根本没提过工具,模型幻觉出来也不认,
    /// 落到下面按缺 text 报错——与 parseCommand 对未开启开关的处理一致。
    static func parseRoutine(_ payload: [String: Any],
                             webSearchEnabled: Bool) throws -> AIRoutineOutcome {
        if webSearchEnabled, let toolName = payload["tool"] as? String {
            let thought = (payload["thought"] as? String) ?? ""
            switch toolName {
            case "web_search":
                guard let query = (payload["query"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:web_search 缺少 query")
                }
                return .toolCall(thought: thought, tool: .webSearch(query: query))
            case "web_fetch":
                guard let url = (payload["url"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:web_fetch 缺少 url")
                }
                return .toolCall(thought: thought, tool: .webFetch(url: url))
            default:
                throw DeepSeekError.parse("返回格式异常:未知工具 \(toolName)")
            }
        }
        guard let text = (payload["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 text")
        }
        return .text(text)
    }

    /// 把一段更早的对话压成常驻摘要。AI 助手是单一持续对话、永不结束,窗口之外
    /// 的消息不压就等于彻底失忆。**滚动摘要**:上一版摘要和这批新消息一起给模型,
    /// 让它产出合并后的一份,而不是每段各摘一份堆在一起。
    /// 不拼 personaBlock:摘要是给模型自己看的上下文,要客观,不需要说话风格。
    public static func summarizeConversation(previous: String?, transcript: String) async throws
        -> String {
        let system = """
        你是提醒事项应用 lodo 的对话记忆整理助手。下面是用户与 AI 助手更早的一段对话,\
        请把它压缩成一段摘要,供之后的对话理解上下文。\
        保留:用户说过的事实与偏好、已经执行过的操作及其结果(新建/修改/完成了什么、\
        收藏了什么、规划或调整了哪次行程)、还没了结的话题。\
        丢弃:寒暄、重复的确认、纯粹的客套。用第三人称陈述,不要复述原话。\
        \(previous == nil ? "" : "已有摘要要一并合并进来,不要丢掉它里面的事实。")\
        只返回 JSON:{"summary": "摘要正文"},不要任何其他文字。
        """
        let user = previous.map { "已有摘要:\n\($0)\n\n新增对话:\n\(transcript)" } ?? transcript
        return try parseConversationSummary(
            await payload(system: system, user: user, timeout: 60))
    }

    /// 从 payload 里解析对话摘要(单测入口)。
    static func parseConversationSummary(_ payload: [String: Any]) throws -> String {
        guard let summary = payload["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 summary")
        }
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把今天的事项列表改写成一句话汇总,突出重点事件(用于每日汇总通知正文)。
    public static func summarizeToday(_ items: [String]) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的汇总助手。给定今天开始或到期的事项列表\
        (含时间与时长),用一句话给出今天怎么安排的建议——不是单纯罗列,\
        要指出哪些优先处理、哪些可以往后放,具体可执行,不超过 40 个字,\
        只返回 JSON:{"summary": "一句话"},不要任何其他文字。\(personaBlock)
        """
        let payload = try await payload(system: system, user: json(items), timeout: 60)
        guard let summary = payload["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 summary")
        }
        return summary
    }

    /// AI 收藏整理的结果:标题/摘要/标签,加上可选的资产金额+币种(仅当内容
    /// 记录了一项资产/资金的价值时才非 nil,比如"存折里还有5000美元"、
    /// "工资卡余额12000"——两者要么同时有,要么同时为 nil,不单独出现)。
    /// liabilityValue/interestRate 是另外两个独立的可选字段(负债本金/年化
    /// 利率百分比数值),不要求和 assetValue 成对,也不要求彼此成对——用户
    /// 可能只提了利率没提金额,或者只记了一笔贷款还没记资产本身。
    public struct MemorizedEntry {
        public var title: String
        public var summary: String
        public var tags: [String]
        public var assetValue: Double?
        public var assetCurrency: String?
        public var liabilityValue: Double?
        public var interestRate: Double?

        public init(
            title: String, summary: String, tags: [String],
            assetValue: Double? = nil, assetCurrency: String? = nil,
            liabilityValue: Double? = nil, interestRate: Double? = nil
        ) {
            self.title = title
            self.summary = summary
            self.tags = tags
            self.assetValue = assetValue
            self.assetCurrency = assetCurrency
            self.liabilityValue = liabilityValue
            self.interestRate = interestRate
        }
    }

    /// 把收藏的内容(提取文本,或只有文件名)整理成记忆条目。
    /// existingTags:当前已有的标签全集,AI 优先复用相近的已有标签,
    /// 保持标签体系收敛不发散。
    /// 不拼 personaBlock:摘要要客观中性,个性只用于面向用户的对话文字。
    public static func memorize(
        text: String, filename: String?, kind: String, existingTags: [String] = []
    ) async throws -> MemorizedEntry {
        var context = "内容类型:\(kind)"
        if let filename, !filename.isEmpty { context += "\n文件名:\(filename)" }
        // token 预算:标签全集只带前 50 个进 prompt
        var tagRule = ""
        if !existingTags.isEmpty {
            tagRule = """

            - 已有标签:\(existingTags.prefix(50).joined(separator: "、"))。\
            tags 优先从已有标签中选用语义相近的,都不合适时才创建新标签。
            """
        }
        let system = """
        你是提醒事项应用 lodo 的收藏整理助手。用户收藏了一段内容\
        (可能是网页正文、PDF/图片提取的文字、纯文本,或只有文件名),\
        把它整理成一条记忆条目,只返回 JSON,不要任何其他文字:
        {"title": "不超过 20 字的标题", "summary": "不超过 100 字的客观摘要", "tags": ["2-4 个中文标签"]}

        规则:
        - 标题概括内容主旨,不要照抄第一句。
        - 内容为空、只有文件名时,基于文件名与类型推断,summary 注明"(基于文件名整理)"。
        - 完全无法整理时返回 {"error": "原因"}。
        - 如果内容记录的是一项资产/资金的价值(比如"存折里还有5000美元"、\
        "工资卡余额12000"、"这套房子值300万"),额外返回 "asset_value"(数字金额)\
        和 "asset_currency"(ISO 4217 三位货币代码,如 CNY/USD/EUR;没有明确说\
        是外币就用 CNY),并确保 tags 里包含"资产"这个标签。不是资产内容时\
        不要返回 asset_value/asset_currency 这两个字段。
        - 如果内容还提到负债/贷款/欠款(比如"房贷100万利率4.5%"、"车贷还剩8万"),\
        额外返回 "liability_value"(数字,负债本金,与 asset_value 同币种)和/或\
        "interest_rate"(数字,年化利率的百分比数值,如 4.5 表示 4.5%),两者不要求\
        成对出现,只返回内容里明确提到的那个;同样要确保 tags 里包含"资产"这个\
        标签。不是负债内容时不要返回 liability_value/interest_rate。\(tagRule)

        \(context)
        """
        let user = text.isEmpty ? "(无内容,仅文件名)" : text
        return try parseMemorizedEntry(await payload(system: system, user: user, timeout: 60))
    }

    /// 从 payload 里解析收藏整理结果(单测入口)。asset_value/asset_currency、
    /// liability_value、interest_rate 都是锦上添花的可选字段(不是用户主动
    /// 确认的写操作,是后台整理的尽力而为),值不合法时只丢弃相应字段、不
    /// 影响 title/summary/tags 的正常解析——不像 command 协议里新建/修改
    /// 事项那样"一条坏就整体报错"。liability_value/interest_rate 彼此独立,
    /// 不要求成对出现,也不要求依赖 asset_value/asset_currency 是否有效。
    static func parseMemorizedEntry(_ payload: [String: Any]) throws -> MemorizedEntry {
        guard let title = payload["title"] as? String,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 title")
        }
        var assetValue: Double?
        var assetCurrency: String?
        if let rawValue = payload["asset_value"] as? NSNumber, rawValue.doubleValue > 0,
           let rawCurrency = (payload["asset_currency"] as? String)?
               .trimmingCharacters(in: .whitespaces).uppercased(),
           rawCurrency.count == 3, rawCurrency.allSatisfy({ $0.isASCII && $0.isLetter }) {
            assetValue = rawValue.doubleValue
            assetCurrency = rawCurrency
        }
        var liabilityValue: Double?
        if let rawLiability = payload["liability_value"] as? NSNumber,
           rawLiability.doubleValue >= 0 {
            liabilityValue = rawLiability.doubleValue
        }
        var interestRate: Double?
        if let rawRate = payload["interest_rate"] as? NSNumber {
            interestRate = rawRate.doubleValue
        }
        return MemorizedEntry(
            title: title.trimmingCharacters(in: .whitespaces),
            summary: (payload["summary"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            tags: (payload["tags"] as? [Any])?.compactMap { $0 as? String } ?? [],
            assetValue: assetValue,
            assetCurrency: assetCurrency,
            liabilityValue: liabilityValue,
            interestRate: interestRate
        )
    }

    /// 记忆问答:给定问题与本地粗排出的相关条目(含 uuid),返回自然语言回答
    /// 与相关条目 uuid 列表。调用方负责先粗排、控制条目数与摘录长度。
    public static func askMemory(
        question: String,
        items: [(uuid: String, title: String, summary: String, tags: [String], excerpt: String)]
    ) async throws -> (answer: String, relatedUUIDs: [String]) {
        let list = items.map { item -> [String: Any] in
            [
                "uuid": item.uuid,
                "title": item.title,
                "summary": item.summary,
                "tags": item.tags,
                "excerpt": item.excerpt,
            ]
        }
        let system = """
        你是提醒事项应用 lodo 的收藏问答助手。下面是用户收藏的记忆条目列表,\
        根据它们回答用户的问题(搜索、询问、归纳整理都可以),只返回 JSON,\
        不要任何其他文字:
        {"answer": "回答", "related_uuids": ["相关条目的 uuid,原样取自列表,不要自己生成"]}

        规则:
        - 回答基于条目内容,不要编造条目里没有的信息;不超过 120 个字。
        - 找不到相关条目时,answer 说明没有找到相关收藏,related_uuids 为空数组。

        \(timeContext)

        记忆条目列表:
        \(json(list))\(personaBlock)
        """
        return try parseMemoryAnswer(
            await payload(system: system, user: question),
            validUUIDs: items.map(\.uuid))
    }

    /// 从 payload 里解析问答结果;uuid 必须在传入列表内(单测入口)。
    static func parseMemoryAnswer(
        _ payload: [String: Any], validUUIDs: [String]
    ) throws -> (answer: String, relatedUUIDs: [String]) {
        guard let answer = payload["answer"] as? String,
              !answer.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 answer")
        }
        let related = (payload["related_uuids"] as? [Any])?
            .compactMap { $0 as? String }
            .filter { validUUIDs.contains($0) } ?? []
        return (answer.trimmingCharacters(in: .whitespacesAndNewlines), related)
    }

    /// 用一条新样本让模型归纳更新"事项类型 → 典型时长"记忆文件,返回新文件全文。
    public static func updateMemory(current: String?, title: String,
                                    durationMinutes: Int) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的记忆管理助手,维护一份"事项类型 → 典型时长"的记忆文件。\
        给定现有记忆文件和一条新样本,输出更新后的完整记忆文件:按大致类型归纳,\
        相近类型合并为一条,每条含典型时长(分钟)和 1-3 个例子,最多 15 条,\
        markdown 列表格式,首行标题为"# 事项时长记忆"。\
        只返回 JSON:{"memory": "更新后的文件全文"},不要任何其他文字。

        现有记忆文件:
        \(current ?? "(空)")
        """
        let payload = try await payload(
            system: system, user: "新样本:\(title),\(durationMinutes) 分钟", timeout: 60)
        guard let memory = payload["memory"] as? String else {
            throw DeepSeekError.parse("返回格式异常:缺少 memory")
        }
        return memory
    }

    /// 偏好条数超上限时重写整份文件(合并相近条目);与 updateMemory 同构。
    public static func consolidatePreferences(current: String) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的偏好管理助手,维护一份"用户长期做事偏好"的文件。\
        给定现有文件,输出整理后的完整文件:相近的条目合并成一条,矛盾的以更靠后的为准,\
        一条一行,markdown 列表格式,最多 30 条,首行标题为"# 用户偏好"。\
        不要新增用户没说过的偏好。只返回 JSON:{"preferences": "整理后的文件全文"},\
        不要任何其他文字。
        """
        let payload = try await payload(system: system, user: current, timeout: 60)
        guard let preferences = payload["preferences"] as? String else {
            throw DeepSeekError.parse("返回格式异常:缺少 preferences")
        }
        return preferences
    }

    // MARK: - 请求与序列化

    private static func taskFields(of task: ParsedTask) -> [String: Any] {
        var fields: [String: Any] = [
            "title": task.title,
            "remind_at": dateFormatter.string(from: task.remindAt),
            "all_day": task.allDay,
            "duration_minutes": task.durationMinutes,
            "repeat_type": task.repeatType.rawValue,
            "repeat_days": task.repeatDays,
            "repeat_times": task.repeatTimes,
        ]
        if let project = task.project, !project.isEmpty {
            fields["project"] = project
        }
        return fields
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 发起请求并取回模型返回的 JSON payload(含 error 检查)。
    /// 当前 AI 是否已配置可用:云服务商=已存 key;苹果智能=设备端可用。
    public static var isConfigured: Bool {
        if AppSettings.usesAppleIntelligence {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return FoundationModelsClient.isAvailable
            }
            #endif
            return false
        }
        return KeychainHelper.effectiveAPIKey != nil
    }

    /// 模型压根没给出可解析 JSON 时的固定错误文案。模型自己用 {"error": "原因"}
    /// 说明"这件事我做不了"时抛的是那句原因,两者据此区分(见 command())。
    static let malformedPayloadMessage = "返回格式异常"

    /// 模型输出文本 → JSON payload:剥 markdown 围栏、从首个 { 截到末个 },
    /// 兼容部分服务/端侧模型不严格遵守纯 JSON 的情况。云端与苹果智能共用。
    public static func decodePayload(from text: String) throws -> [String: Any] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            cleaned = cleaned
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"), start < end {
            cleaned = String(cleaned[start...end])
        }
        guard let payload = try? JSONSerialization.jsonObject(
            with: Data(cleaned.utf8)) as? [String: Any] else {
            // 一个花括号都没有 = 模型没按 JSON 约定答,整段就是它想说的白话
            // (问它"这张图说的是什么"最容易碰上)。把这段话当成错误原因抛出去,
            // 聊天入口据此渲染成普通回复气泡(见 command()),其余调用方照旧报错,
            // 但错误里带上模型的原话,比"返回格式异常"五个字好查。
            // 有花括号说明它本来想给 JSON 只是给坏了(截断等),那是真的格式错。
            if !cleaned.isEmpty, !cleaned.contains("{") {
                throw DeepSeekError.parse(MemorySearch.truncate(cleaned, limit: 500))
            }
            throw DeepSeekError.parse(malformedPayloadMessage)
        }
        if let error = payload["error"] as? String {
            throw DeepSeekError.parse(error)
        }
        return payload
    }

    /// timeout:交互型请求默认 20 秒;汇总/记忆等后台请求传 60 秒。
    /// thinking:true 时按设置里的思考强度带上 reasoning_effort(仅 command() 传
    /// true——AI 助手对话入口才需要深度推理,解析/汇总等后台小请求不需要多等)。
    /// onStream / onReasoning 非 nil 时走 SSE 流式(只有 command 这条路径传),
    /// 端侧的苹果智能不支持,那条分支照旧一次性返回。
    /// tracksUsage:把这次请求的 token 用量记进 `AIUsageMonitor`(标题行读它)。
    /// **只有 `command()` 传 true**——那是用户"这句话"的成本;memorize/汇总/时长建议
    /// 这些后台小请求不该混进去。端侧的苹果智能没有 usage 概念,那条路径不统计。
    private static func payload(system: String, user: String,
                                timeout: TimeInterval = 20,
                                thinking: Bool = false,
                                tracksUsage: Bool = false,
                                onStream: ((String) -> Void)? = nil,
                                onReasoning: ((String) -> Void)? = nil) async throws -> [String: Any] {
        // 苹果智能:端侧推理,免 key,payload 形态与云端一致;端侧模型没有
        // reasoning_effort 这个概念,thinking 参数在这条路径上不生效。
        if AppSettings.usesAppleIntelligence {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                if FoundationModelsClient.isAvailable {
                    return try await FoundationModelsClient.payload(system: system, user: user)
                }
                // 设备不支持/未开启/模型未就绪:有 DeepSeek key(内置的优先,
                // 没开或没内置就用钥匙串里存的)就自动退回云端完成这一次请求
                // (不改用户在设置里选的服务商),没有才报不可用原因。
                if let key = (AppSettings.useBuiltInKey ? BuiltInAPIKey.deepSeek : nil)
                    ?? KeychainHelper.apiKey(for: "DeepSeek Flash"),
                   let preset = AppSettings.aiProviders.first(where: { $0.name == "DeepSeek Flash" }),
                   let endpoint = URL(string: preset.endpoint) {
                    return try await cloudRequest(endpoint: endpoint, apiKey: key,
                                                  model: preset.model, system: system,
                                                  user: user, timeout: timeout, thinking: thinking)
                }
                throw DeepSeekError.api(FoundationModelsClient.availabilityHint)
            }
            #endif
            throw DeepSeekError.api("苹果智能需要 iOS 26 及以上系统。")
        }

        guard let apiKey = KeychainHelper.effectiveAPIKey else { throw DeepSeekError.noKey }
        guard let endpoint = AppSettings.aiEndpoint else {
            throw DeepSeekError.api("无效的服务地址,请到「设置」里检查 AI 服务商配置。")
        }
        if onStream != nil || onReasoning != nil {
            return try await cloudStream(
                endpoint: endpoint, apiKey: apiKey, model: AppSettings.aiModel,
                system: system, user: user, timeout: timeout, thinking: thinking,
                tracksUsage: tracksUsage, onStream: onStream, onReasoning: onReasoning)
        }
        return try await cloudRequest(endpoint: endpoint, apiKey: apiKey,
                                      model: AppSettings.aiModel, system: system,
                                      user: user, timeout: timeout, thinking: thinking,
                                      tracksUsage: tracksUsage)
    }

    /// 已知不支持 SSE 的 endpoint(试过一次就失败的),本次运行内不再试。
    /// 只活在内存里:不落盘、不进设置页——服务商那边改好了,重开 app 就会再试。
    private static var unsupportedStreamEndpoints: Set<String> = []

    /// 带了 `stream_options` 就报错的 endpoint(有的网关不认这个多出来的字段,
    /// 直接 400)。去掉它重试一次仍然是流式——不能因为要不到 token 数就把一个
    /// 本来好用的流式能力整条拉黑。同样只活在内存里。
    private static var usageUnsupportedStreamEndpoints: Set<String> = []

    /// 流式版本的 cloudRequest:边收边把 `answer` 的正文喂给 onStream,
    /// 收完之后仍然交给同一个 `decodePayload`——**最终结果的解析路径与非流式
    /// 逐字相同**,流式只是让字早点出现。
    ///
    /// 任何一步不对(网关不支持 stream、中途断流、攒出来的串解析不了)都回退到
    /// 一次性请求。回退前必须先让调用方清掉已经显示的半句(onStream("")),
    /// 否则屏幕上会留下"半句 + 完整句"两段。
    private static func cloudStream(
        endpoint: URL, apiKey: String, model: String, system: String, user: String,
        timeout: TimeInterval, thinking: Bool, tracksUsage: Bool = false,
        onStream: ((String) -> Void)?, onReasoning: ((String) -> Void)?
    ) async throws -> [String: Any] {
        let monitor = tracksUsage ? AIUsageMonitor.shared : nil
        func fallback() async throws -> [String: Any] {
            onStream?("")
            // 同一次逻辑请求不能数两遍:这条流上已经数过的分片作废,
            // 交给下面那次一次性请求报它自己的精确 usage。
            monitor?.discardRequest()
            return try await cloudRequest(endpoint: endpoint, apiKey: apiKey, model: model,
                                          system: system, user: user, timeout: timeout,
                                          thinking: thinking, tracksUsage: tracksUsage)
        }
        guard !unsupportedStreamEndpoints.contains(endpoint.absoluteString) else {
            return try await fallback()
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0,
            "stream": true,
        ]
        if thinking, AppSettings.thinkingLevel != "off" {
            body["reasoning_effort"] = AppSettings.thinkingLevel
        }
        // 不带这个字段服务端一片 usage 都不会发,标题行就只能显示估算值。
        let includeUsage = tracksUsage
            && !usageUnsupportedStreamEndpoints.contains(endpoint.absoluteString)
        if includeUsage { body["stream_options"] = ["include_usage": true] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var scanner = AnswerStreamScanner()
        var throttle = StreamThrottle()
        var raw = ""
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if includeUsage {
                    // 多半是网关不认 stream_options。记下来、去掉它重试一次流式
                    // (集合里已经有了,重试那次的 includeUsage 必为 false,不会再递归)。
                    usageUnsupportedStreamEndpoints.insert(endpoint.absoluteString)
                    return try await cloudStream(
                        endpoint: endpoint, apiKey: apiKey, model: model, system: system,
                        user: user, timeout: timeout, thinking: thinking,
                        tracksUsage: tracksUsage, onStream: onStream, onReasoning: onReasoning)
                }
                unsupportedStreamEndpoints.insert(endpoint.absoluteString)
                return try await fallback()
            }
            // 带标签:`switch` 里的 `break` 跳出的是 switch 不是循环,
            // 收到 [DONE] 还得继续读下去,读到的就是服务端在结束标记之后
            // 多吐的东西。
            streaming: for try await line in bytes.lines {
                guard let event = AgentStream.parseLine(line) else { continue }
                switch event {
                case .done:
                    break streaming
                case .usage(let input, let output):
                    monitor?.report(inputTokens: input, outputTokens: output)
                case .delta(let content, let reasoning):
                    // content 和 reasoning 各算一片 ≈ 一个 token:精确值没来时的兜底,
                    // 顺便撑起"生成时长"那个分母(第一片的时刻才是生成开始)。
                    monitor?.noteDelta()
                    if let reasoning, !reasoning.isEmpty { onReasoning?(reasoning) }
                    guard let content, !content.isEmpty else { continue }
                    raw += content
                    if let text = scanner.consume(content), throttle.shouldFlush(content) {
                        onStream?(text)
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // 中途断流:这次请求本身已经产生过 token,**不能**照搬非流式那套
            // "传输层错误重试一次"——重试会把已经吐过的字再吐一遍。一个字都没
            // 收到时才当成普通失败退回一次性请求。
            guard raw.isEmpty else { throw DeepSeekError.api(error.localizedDescription) }
            return try await fallback()
        }

        // 收完之后把最后一截补上(节流可能压住了最后几片)。
        if !scanner.currentText.isEmpty { onStream?(scanner.currentText) }
        guard !raw.isEmpty else {
            unsupportedStreamEndpoints.insert(endpoint.absoluteString)
            return try await fallback()
        }
        do {
            let decoded = try decodePayload(from: raw)
            // 折进累计的时机放在解析成功之后:下面两条退回一次性请求的岔路上
            // 这次的计数要作废(fallback() 里 discardRequest),不能已经折进去了。
            monitor?.endRequest()
            return decoded
        } catch let DeepSeekError.parse(message) where message == malformedPayloadMessage {
            // 有花括号但给坏了(多半是截断):退回一次性请求重来一遍,比直接
            // 报错好——非流式那条路上同样的输入常常是好的。
            return try await fallback()
        }
    }

    /// 云端 OpenAI 兼容接口的请求构造 + 响应解析,供当前选中服务商和苹果智能
    /// 不可用时的 DeepSeek 退回共用。
    private static func cloudRequest(
        endpoint: URL, apiKey: String, model: String,
        system: String, user: String, timeout: TimeInterval, thinking: Bool = false,
        tracksUsage: Bool = false
    ) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0,
        ]
        // reasoning_effort:OpenAI 兼容接口里推理强度的通用字段名,支持推理的
        // 服务商/模型会据此调整思考深度,不支持的会直接忽略这个多余字段。
        if thinking, AppSettings.thinkingLevel != "off" {
            body["reasoning_effort"] = AppSettings.thinkingLevel
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 这条路上没有增量,量不到"第一个 token 什么时候到",只能拿整次请求的耗时
        // 当生成时长——算出来的速度偏慢(把 prompt 处理和排队都算进去了)。这是
        // 回退路径的固有损失,主路径(流式)不受影响。
        let started = Date()
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.api("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(200))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DeepSeekError.parse(malformedPayloadMessage)
        }
        if tracksUsage {
            let monitor = AIUsageMonitor.shared
            monitor.beginRequest(at: started)
            if let usage = root["usage"] as? [String: Any] {
                monitor.report(inputTokens: usage["prompt_tokens"] as? Int,
                               outputTokens: usage["completion_tokens"] as? Int)
            }
            monitor.endRequest()
        }
        return try decodePayload(from: content)
    }

    /// 传输层错误(超时/连接问题)延时后重试一次;取消/HTTP 状态码错误不重试。
    private static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch is URLError {
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                return try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DeepSeekError.api(error.localizedDescription)
            }
        } catch {
            throw DeepSeekError.api(error.localizedDescription)
        }
    }

    /// 从 payload 里解析并校验事项字段;任何字段超出合理范围直接抛错(不做静默
    /// clamp)——AI 返回离谱值通常本身就意味着误解了用户意图,静默改写会产生
    /// "AI 说建的是 A,实际存的是被偷偷改过的 A'"这种不可见偏差,不如报错更安全。
    private static func parseTask(_ payload: [String: Any]) throws -> ParsedTask {
        guard let rawTitle = payload["title"] as? String,
              let remindStr = payload["remind_at"] as? String,
              let remindAt = dateFormatter.date(from: remindStr) else {
            throw DeepSeekError.parse("返回格式异常:\(payload)")
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:标题为空")
        }

        let times = (payload["repeat_times"] as? [Any])?.compactMap { $0 as? String } ?? []
        for t in times {
            let parts = t.split(separator: ":")
            guard parts.count == 2, parts[1].count == 2,
                  let h = Int(parts[0]), let m = Int(parts[1]),
                  (0...23).contains(h), (0...59).contains(m) else {
                throw DeepSeekError.parse("时间点格式异常:\(t)")
            }
        }

        let duration = payload["duration_minutes"] as? Int ?? 0
        guard (0...1440).contains(duration) else {
            throw DeepSeekError.parse("返回格式异常:时长超出范围")
        }

        let rawDays = (payload["repeat_days"] as? [Any])?.compactMap { $0 as? Int } ?? []
        guard rawDays.allSatisfy({ (0...6).contains($0) }) else {
            throw DeepSeekError.parse("返回格式异常:周几超出范围")
        }
        let days = Array(Set(rawDays)).sorted()

        // project 是锦上添花的分类信息(不像 title/remind_at 那样硬校验),值不对
        // 或缺失只取 nil,不拖累整条事项解析失败。
        let project = (payload["project"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = (project?.isEmpty ?? true) ? nil : project

        return ParsedTask(
            title: title,
            remindAt: remindAt,
            allDay: payload["all_day"] as? Bool ?? false,
            durationMinutes: duration,
            repeatType: RepeatType(rawValue: payload["repeat_type"] as? String ?? "none") ?? .none,
            repeatDays: days,
            repeatTimes: times,
            project: trimmedProject
        )
    }
}
