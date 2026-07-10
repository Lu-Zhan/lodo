import Foundation
import LodoCore

/// AI 解析/编辑得到的事项字段,创建与编辑表单共用的值包。
struct ParsedTask {
    var title: String
    var remindAt: Date
    var allDay: Bool
    var durationMinutes: Int
    var repeatType: RepeatType
    var repeatDays: [Int]
    var repeatTimes: [String]
}

extension ParsedTask {
    /// 从现有事项取当前字段值(编辑表单预填、AI 修改的"现有事项"上下文共用)。
    init(from task: TaskItem) {
        self.init(title: task.title, remindAt: task.remindAt, allDay: task.allDay,
                  durationMinutes: task.durationMinutes, repeatType: task.repeatType,
                  repeatDays: task.repeatDays, repeatTimes: task.repeatTimes)
    }
}

/// AI 总入口解析出的单个操作。
enum AIAction {
    case create(ParsedTask)
    case update(uuid: String, task: ParsedTask)
    case complete(uuid: String)
    case delete(uuid: String)
}

/// AI 总入口的返回:操作列表,或关键信息缺失时的反问(附候选补充)。
enum AICommandResult {
    case actions([AIAction])
    case clarify(question: String, options: [String])
}

enum DeepSeekError: LocalizedError {
    case noKey
    case api(String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .noKey: return "未配置 DeepSeek API key,请到「设置」里填写。"
        case .api(let m): return "调用 DeepSeek 失败:\(m)"
        case .parse(let m): return "无法解析:\(m)"
        }
    }
}

/// DeepSeek 自然语言创建/编辑,prompt 与 web/lodo/ai.py 保持一致。
enum DeepSeekClient {
    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private static let model = "deepseek-chat"

    private static let taskSchema = """
    {"title": "事项内容(去掉时间词,保留做什么)",
      "remind_at": "YYYY-MM-DD HH:MM",
      "all_day": false,
      "duration_minutes": 0,
      "repeat_type": "none",
      "repeat_days": [],
      "repeat_times": []}
    """

    private static let taskRules = """
    规则:
    - "今天/明天/后天/周X/X月X日" 等相对时间基于当前时间换算成具体日期。
    - 只说了点数没说上下午时,按常理推断(如"9点开会"在当前时间之前则理解为最近的将来时间)。
    - 未提到时长时 duration_minutes 为 0;"开会一小时"之类则换算成分钟数。
    - 只有日期、没有具体时间点的事项(如"明天要交报告"):all_day 设为 true,remind_at 用 "YYYY-MM-DD 00:00"。
    - 重复事项:"每天…"时 repeat_type 为 "daily";"每周一三五…"之类时 repeat_type 为 "weekly",repeat_days 为选中的周几(0=周一 … 6=周日)。repeat_times 为当天的提醒时间点列表,可以有多个(如"每天9点和21点提醒吃药" → ["09:00", "21:00"]);重复事项 remind_at 填第一次提醒的时间。
    - 无法解析出时间时,返回 {"error": "原因"}。
    """

    private static let formatAndRules = """
    返回格式(不适用的字段用默认值):
    \(taskSchema)

    \(taskRules)
    """

    private static var timeContext: String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let weekdays = "一二三四五六日"
        let pyWeekday = (Calendar.current.component(.weekday, from: now) + 5) % 7
        let index = weekdays.index(weekdays.startIndex, offsetBy: pyWeekday)
        return "当前时间:\(formatter.string(from: now))(星期\(weekdays[index]))"
    }

    /// 自然语言 → 新事项字段。
    static func parse(_ text: String) async throws -> ParsedTask {
        let system = """
        你是提醒事项应用 lodo 的解析助手。用户会用自然语言描述一个提醒事项,\
        你需要解析出结构化信息,只返回 JSON,不要任何其他文字。

        \(timeContext)

        \(formatAndRules)
        """
        return try parseTask(await payload(system: system, user: text))
    }

    /// 按自然语言指令修改现有事项;未提到的字段保持原值。
    static func edit(_ current: ParsedTask, instruction: String) async throws -> ParsedTask {
        let system = """
        你是提醒事项应用 lodo 的编辑助手。给定一个现有事项和用户的修改指令,\
        输出修改后的完整事项,只返回 JSON,不要任何其他文字。\
        用户没有提到的字段一律保持原值;无法理解指令时返回 {"error": "原因"}。

        \(timeContext)

        现有事项:
        \(json(taskFields(of: current)))

        \(formatAndRules)
        """
        return try parseTask(await payload(system: system, user: instruction))
    }

    /// AI 总入口:给定当前待办列表,把用户的一句话解析成一组操作
    /// (新建/修改/完成/删除,可多条),或在关键信息缺失时反问。
    static func command(
        _ text: String, tasks: [(uuid: String, task: ParsedTask)]
    ) async throws -> AICommandResult {
        let list = tasks.map { entry -> [String: Any] in
            var fields = taskFields(of: entry.task)
            fields["uuid"] = entry.uuid
            return fields
        }
        let system = """
        你是提醒事项应用 lodo 的智能入口。给定当前待办事项列表和用户的一句话,\
        解析出要执行的操作列表,只返回 JSON,不要任何其他文字。

        支持的操作(action):
        - 新建:{"action": "create", ...事项字段}
        - 修改:{"action": "update", "uuid": "原样取自当前待办列表,不要自己生成", ...事项字段}\
        (输出修改后的完整字段值,用户没有提到的字段一律保持原值)
        - 完成:{"action": "complete", "uuid": "原样取自当前待办列表"}
        - 删除:{"action": "delete", "uuid": "原样取自当前待办列表"}

        判断规则:
        - 一句话里包含多件事时返回多个操作,如"明天上午开会,周五交报告"→ 两条 create。
        - 修改/完成/删除按标题语义匹配列表中的事项("开会完成了"→ complete,\
        "把取快递删了"→ delete);匹配不到时返回 {"error": "原因"}。
        - 新建缺少关键时间信息且无法按常理推断时(如只说"提醒我交材料"),不要猜,\
        改为反问:{"question": "要问用户的问题", "options": ["候选补充1", "候选补充2", "候选补充3"]},\
        options 给 2-3 个具体可直接采用的补充(如"明天 09:00")。
        - 无法解析时返回 {"error": "原因"}。

        \(timeContext)

        当前待办列表:
        \(json(list))

        返回格式(二选一):
        {"actions": [操作, ...]}
        {"question": "...", "options": ["...", "..."]}

        事项字段:
        \(taskSchema)

        \(taskRules)
        """
        let payload = try await payload(system: system, user: text)

        if let question = payload["question"] as? String, !question.isEmpty {
            let options = (payload["options"] as? [Any])?.compactMap { $0 as? String } ?? []
            return .clarify(question: question, options: options)
        }
        guard let rawActions = payload["actions"] as? [[String: Any]],
              !rawActions.isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 actions")
        }
        var actions: [AIAction] = []
        for raw in rawActions {
            func validUUID() throws -> String {
                guard let uuid = raw["uuid"] as? String,
                      tasks.contains(where: { $0.uuid == uuid }) else {
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
            default:
                throw DeepSeekError.parse("返回格式异常:未知 action")
            }
        }
        return .actions(actions)
    }

    /// 按记忆文件为"没说时长"的新事项建议时长(分钟);
    /// 用户明确表示不需要时长、或记忆无相近类型时返回 0。
    static func suggestDuration(text: String, title: String,
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

    /// 把今天的事项列表改写成一句话汇总,突出重点事件(用于每日汇总通知正文)。
    static func summarizeToday(_ items: [String]) async throws -> String {
        let system = """
        你是提醒事项应用 lodo 的汇总助手。给定今天开始或到期的事项列表\
        (含时间与时长),用一句话概括今天的安排,突出重点事件\
        (如时间临近、耗时长或听起来重要的),不超过 40 个字,\
        只返回 JSON:{"summary": "一句话"},不要任何其他文字。
        """
        let payload = try await payload(system: system, user: json(items))
        guard let summary = payload["summary"] as? String,
              !summary.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw DeepSeekError.parse("返回格式异常:缺少 summary")
        }
        return summary
    }

    /// 用一条新样本让模型归纳更新"事项类型 → 典型时长"记忆文件,返回新文件全文。
    static func updateMemory(current: String?, title: String,
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
            system: system, user: "新样本:\(title),\(durationMinutes) 分钟")
        guard let memory = payload["memory"] as? String else {
            throw DeepSeekError.parse("返回格式异常:缺少 memory")
        }
        return memory
    }

    // MARK: - 请求与序列化

    private static func taskFields(of task: ParsedTask) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return [
            "title": task.title,
            "remind_at": formatter.string(from: task.remindAt),
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
    private static func payload(system: String, user: String) async throws -> [String: Any] {
        guard let apiKey = KeychainHelper.apiKey else { throw DeepSeekError.noKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": ["type": "json_object"],
            "temperature": 0,
        ] as [String: Any])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DeepSeekError.api(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DeepSeekError.api("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(200))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              let payload = try? JSONSerialization.jsonObject(
                  with: Data(content.utf8)) as? [String: Any] else {
            throw DeepSeekError.parse("返回格式异常")
        }
        if let error = payload["error"] as? String {
            throw DeepSeekError.parse(error)
        }
        return payload
    }

    /// 从 payload 里解析并校验事项字段。
    private static func parseTask(_ payload: [String: Any]) throws -> ParsedTask {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let title = payload["title"] as? String,
              let remindStr = payload["remind_at"] as? String,
              let remindAt = formatter.date(from: remindStr) else {
            throw DeepSeekError.parse("返回格式异常:\(payload)")
        }
        let times = (payload["repeat_times"] as? [Any])?.compactMap { $0 as? String } ?? []
        for t in times where t.wholeMatch(of: /\d{1,2}:\d{2}/) == nil {
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
