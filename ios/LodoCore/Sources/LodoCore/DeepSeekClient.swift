import Foundation

/// AI 解析/编辑得到的事项字段,创建与编辑表单共用的值包。
public struct ParsedTask {
    public var title: String
    public var remindAt: Date
    public var allDay: Bool
    public var durationMinutes: Int
    public var repeatType: RepeatType
    public var repeatDays: [Int]
    public var repeatTimes: [String]

    public init(title: String, remindAt: Date, allDay: Bool, durationMinutes: Int,
                repeatType: RepeatType, repeatDays: [Int], repeatTimes: [String]) {
        self.title = title
        self.remindAt = remindAt
        self.allDay = allDay
        self.durationMinutes = durationMinutes
        self.repeatType = repeatType
        self.repeatDays = repeatDays
        self.repeatTimes = repeatTimes
    }
}

extension ParsedTask {
    /// 从现有事项取当前字段值(编辑表单预填、AI 修改的"现有事项"上下文共用)。
    public init(from task: TaskItem) {
        self.init(title: task.title, remindAt: task.remindAt, allDay: task.allDay,
                  durationMinutes: task.durationMinutes, repeatType: task.repeatType,
                  repeatDays: task.repeatDays, repeatTimes: task.repeatTimes)
    }
}

/// AI 总入口解析出的单个操作。
/// memorize/askMemory 仅在 command(memoryEnabled: true) 时会出现
/// (iOS/macOS 主 app;Watch 无记忆数据层,不开启)。
public enum AIAction {
    case create(ParsedTask)
    case update(uuid: String, task: ParsedTask)
    case complete(uuid: String)
    case delete(uuid: String)
    case memorize(text: String)
    case askMemory(question: String)
}

/// AI 总入口的返回:操作列表、关键信息缺失时的反问(附候选补充),或
/// ReAct 循环里的中间步骤(还没准备好给最终答案,先要执行一个只读工具)。
public enum AICommandResult {
    case actions([AIAction])
    case clarify(question: String, options: [String])
    case toolCall(thought: String, tool: AITool)
}

/// ReAct 循环里可调用的只读工具;enum 设计是为了以后加新工具不用改循环机制。
/// 只读是硬性要求——写操作(新建/修改/完成/删除)永远只能是最终答案的一部分,
/// 不能在推理过程中未经确认就被模型自己调用。
public enum AITool {
    case searchMemory(question: String)
}

public enum DeepSeekError: LocalizedError {
    case noKey
    case api(String)
    case parse(String)

    public var errorDescription: String? {
        switch self {
        case .noKey: return "未配置 DeepSeek API key,请到「设置」里填写。"
        case .api(let m): return "调用 DeepSeek 失败:\(m)"
        case .parse(let m): return "无法解析:\(m)"
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

    private static var timeContext: String {
        let now = Date()
        let weekdays = "一二三四五六日"
        let pyWeekday = (Calendar.current.component(.weekday, from: now) + 5) % 7
        let index = weekdays.index(weekdays.startIndex, offsetBy: pyWeekday)
        return "当前时间:\(dateFormatter.string(from: now))(星期\(weekdays[index]))"
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

    /// 自然语言 → 新事项字段。
    public static func parse(_ text: String) async throws -> ParsedTask {
        let system = """
        你是提醒事项应用 lodo 的解析助手。用户会用自然语言描述一个提醒事项,\
        你需要解析出结构化信息,只返回 JSON,不要任何其他文字。

        \(timeContext)

        返回格式(不适用的字段用默认值):
        \(AgentSkillStore.content(for: .todo))
        """
        return try parseTask(await payload(system: system, user: text))
    }

    /// 按自然语言指令修改现有事项;未提到的字段保持原值。
    public static func edit(_ current: ParsedTask, instruction: String) async throws -> ParsedTask {
        let system = """
        你是提醒事项应用 lodo 的编辑助手。给定一个现有事项和用户的修改指令,\
        输出修改后的完整事项,只返回 JSON,不要任何其他文字。\
        用户没有提到的字段一律保持原值;无法理解指令时返回 {"error": "原因"}。

        \(timeContext)

        现有事项:
        \(json(taskFields(of: current)))

        返回格式(不适用的字段用默认值):
        \(AgentSkillStore.content(for: .todo))
        """
        return try parseTask(await payload(system: system, user: instruction))
    }

    /// AI 总入口:给定当前待办列表,把用户的一句话解析成一组操作
    /// (新建/修改/完成/删除,可多条),或在关键信息缺失时反问。
    /// memoryEnabled 开启后额外拼入记忆 skill(收藏/查记忆);默认关闭,
    /// Watch 等无记忆数据层的调用方不会看到记忆相关指令(但 agent.md/待办 skill
    /// 的拼接顺序对所有调用方一致,详见 `AgentSkillStore`)。
    public static func command(
        _ text: String, tasks allTasks: [(uuid: String, task: ParsedTask)],
        memoryEnabled: Bool = false,
        history: [(role: String, content: String)] = []
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

        \(AgentSkillStore.content(for: .todo))\
        \(memoryEnabled ? "\n\n" + AgentSkillStore.content(for: .memory) : "")

        \(timeContext)

        当前待办列表:
        \(json(list))\(personaBlock)\(historyBlock(history))
        """
        return try parseCommand(
            await payload(system: system, user: text),
            validUUIDs: tasks.map(\.uuid),
            memoryEnabled: memoryEnabled)
    }

    /// 从 payload 里解析总入口结果(单测入口)。
    /// memoryEnabled == false 时 memorize/ask_memory 按未知 action 处理
    /// (即使模型幻觉出这两种操作,Watch 等调用方也保持旧行为)。
    static func parseCommand(
        _ payload: [String: Any], validUUIDs: [String], memoryEnabled: Bool
    ) throws -> AICommandResult {
        if let question = payload["question"] as? String, !question.isEmpty {
            let options = (payload["options"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .clarify(question: question, options: options)
        }
        // ReAct 中间步骤:memoryEnabled == false(Watch)时 prompt 里根本没提过这个选项,
        // 模型幻觉出来也不认——落到下面 actions 解析,大概率报"缺少 actions",无害。
        if memoryEnabled, let toolName = payload["tool"] as? String {
            let thought = (payload["thought"] as? String) ?? ""
            switch toolName {
            case "search_memory":
                guard let query = (payload["query"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:search_memory 缺少 query")
                }
                return .toolCall(thought: thought, tool: .searchMemory(question: query))
            default:
                throw DeepSeekError.parse("返回格式异常:未知工具 \(toolName)")
            }
        }
        guard let rawActions = payload["actions"] as? [[String: Any]],
              !rawActions.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 actions")
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
            case "ask_memory" where memoryEnabled:
                let question = (raw["question"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !question.isEmpty else {
                    throw DeepSeekError.parse("返回格式异常:查询问题为空")
                }
                actions.append(.askMemory(question: question))
            default:
                throw DeepSeekError.parse("返回格式异常:未知 action")
            }
        }
        // 归一化:prompt 已要求 ask_memory 单独出现,这里是模型不守规矩时的
        // 确定性兜底——问答与写操作混合时丢弃问答只留写操作(写操作是用户要
        // 落地的事不能丢,查询可以重问);全是问答时只留第一条。
        let askQuestions = actions.compactMap { action -> String? in
            if case .askMemory(let question) = action { return question }
            return nil
        }
        if !askQuestions.isEmpty {
            if askQuestions.count == actions.count {
                return .actions([.askMemory(question: askQuestions[0])])
            }
            actions = actions.filter {
                if case .askMemory = $0 { return false }
                return true
            }
        }
        return .actions(actions)
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

    /// 把 agent 对话的首轮内容总结成一个简短标题(thread 列表/导航栏用)。
    /// 不拼 personaBlock:标题要客观简洁,不需要说话风格。
    public static func summarizeThreadTitle(_ text: String) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的对话标题生成助手。根据用户和 AI 的第一轮对话内容,\
        生成一个不超过 12 个字的简短标题,概括这轮对话的主题,不用标点结尾。\
        只返回 JSON:{"title": "标题"},不要任何其他文字。
        """
        return try parseThreadTitle(await payload(system: system, user: text))
    }

    /// 从 payload 里解析对话标题(单测入口)。
    static func parseThreadTitle(_ payload: [String: Any]) throws -> String {
        guard let title = payload["title"] as? String,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 title")
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// 把今天的事项列表改写成一句话汇总,突出重点事件(用于每日汇总通知正文)。
    public static func summarizeToday(_ items: [String]) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的汇总助手。给定今天开始或到期的事项列表\
        (含时间与时长),用一句话概括今天的安排,突出重点事件\
        (如时间临近、耗时长或听起来重要的),不超过 40 个字,\
        只返回 JSON:{"summary": "一句话"},不要任何其他文字。\(personaBlock)
        """
        let payload = try await payload(system: system, user: json(items), timeout: 60)
        guard let summary = payload["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 summary")
        }
        return summary
    }

    /// AI 收藏整理的结果:标题/摘要/标签。
    public struct MemorizedEntry {
        public var title: String
        public var summary: String
        public var tags: [String]

        public init(title: String, summary: String, tags: [String]) {
            self.title = title
            self.summary = summary
            self.tags = tags
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
        - 完全无法整理时返回 {"error": "原因"}。\(tagRule)

        \(context)
        """
        let user = text.isEmpty ? "(无内容,仅文件名)" : text
        return try parseMemorizedEntry(await payload(system: system, user: user, timeout: 60))
    }

    /// 从 payload 里解析收藏整理结果(单测入口)。
    static func parseMemorizedEntry(_ payload: [String: Any]) throws -> MemorizedEntry {
        guard let title = payload["title"] as? String,
              !title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 title")
        }
        return MemorizedEntry(
            title: title.trimmingCharacters(in: .whitespaces),
            summary: (payload["summary"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            tags: (payload["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
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

    // MARK: - 请求与序列化

    private static func taskFields(of task: ParsedTask) -> [String: Any] {
        return [
            "title": task.title,
            "remind_at": dateFormatter.string(from: task.remindAt),
            "all_day": task.allDay,
            "duration_minutes": task.durationMinutes,
            "repeat_type": task.repeatType.rawValue,
            "repeat_days": task.repeatDays,
            "repeat_times": task.repeatTimes,
        ]
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
        return KeychainHelper.apiKey != nil
    }

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
            throw DeepSeekError.parse("返回格式异常")
        }
        if let error = payload["error"] as? String {
            throw DeepSeekError.parse(error)
        }
        return payload
    }

    /// timeout:交互型请求默认 20 秒;汇总/记忆等后台请求传 60 秒。
    private static func payload(system: String, user: String,
                                timeout: TimeInterval = 20) async throws -> [String: Any] {
        // 苹果智能:端侧推理,免 key,payload 形态与云端一致
        if AppSettings.usesAppleIntelligence {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                if FoundationModelsClient.isAvailable {
                    return try await FoundationModelsClient.payload(system: system, user: user)
                }
                // 设备不支持/未开启/模型未就绪:有 DeepSeek key 就自动退回云端
                // 完成这一次请求(不改用户在设置里选的服务商),没有才报不可用原因。
                if let key = KeychainHelper.apiKey(for: "DeepSeek"),
                   let preset = AppSettings.aiProviders.first(where: { $0.name == "DeepSeek" }),
                   let endpoint = URL(string: preset.endpoint) {
                    return try await cloudRequest(endpoint: endpoint, apiKey: key,
                                                  model: preset.model, system: system,
                                                  user: user, timeout: timeout)
                }
                throw DeepSeekError.api(FoundationModelsClient.availabilityHint)
            }
            #endif
            throw DeepSeekError.api("苹果智能需要 iOS 26 及以上系统。")
        }

        guard let apiKey = KeychainHelper.apiKey else { throw DeepSeekError.noKey }
        guard let endpoint = AppSettings.aiEndpoint else {
            throw DeepSeekError.api("无效的服务地址,请到「设置」里检查 AI 服务商配置。")
        }
        return try await cloudRequest(endpoint: endpoint, apiKey: apiKey,
                                      model: AppSettings.aiModel, system: system,
                                      user: user, timeout: timeout)
    }

    /// 云端 OpenAI 兼容接口的请求构造 + 响应解析,供当前选中服务商和苹果智能
    /// 不可用时的 DeepSeek 退回共用。
    private static func cloudRequest(
        endpoint: URL, apiKey: String, model: String,
        system: String, user: String, timeout: TimeInterval
    ) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0,
        ] as [String: Any])

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.api("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(200))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw DeepSeekError.parse("返回格式异常")
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

    /// 从 payload 里解析并校验事项字段。
    private static func parseTask(_ payload: [String: Any]) throws -> ParsedTask {
        guard let title = payload["title"] as? String,
              let remindStr = payload["remind_at"] as? String,
              let remindAt = dateFormatter.date(from: remindStr) else {
            throw DeepSeekError.parse("返回格式异常:\(payload)")
        }
        let times = (payload["repeat_times"] as? [Any])?.compactMap { $0 as? String } ?? []
        for t in times where t.wholeMatch(of: try! Regex(#"\d{1,2}:\d{2}"#)) == nil {
            throw DeepSeekError.parse("时间点格式异常:\(t)")
        }
        return ParsedTask(
            title: title.trimmingCharacters(in: .whitespaces),
            remindAt: remindAt,
            allDay: payload["all_day"] as? Bool ?? false,
            durationMinutes: payload["duration_minutes"] as? Int ?? 0,
            repeatType: RepeatType(rawValue: payload["repeat_type"] as? String ?? "none") ?? .none,
            repeatDays: (payload["repeat_days"] as? [Any])?.compactMap { $0 as? Int } ?? [],
            repeatTimes: times
        )
    }
}
