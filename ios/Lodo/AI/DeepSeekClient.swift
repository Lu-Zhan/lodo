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

    private static let formatAndRules = """
    返回格式(不适用的字段用默认值):
    {"title": "事项内容(去掉时间词,保留做什么)",
      "remind_at": "YYYY-MM-DD HH:MM",
      "all_day": false,
      "duration_minutes": 0,
      "repeat_type": "none",
      "repeat_days": [],
      "repeat_times": []}

    规则:
    - "今天/明天/后天/周X/X月X日" 等相对时间基于当前时间换算成具体日期。
    - 只说了点数没说上下午时,按常理推断(如"9点开会"在当前时间之前则理解为最近的将来时间)。
    - 未提到时长时 duration_minutes 为 0;"开会一小时"之类则换算成分钟数。
    - 只有日期、没有具体时间点的事项(如"明天要交报告"):all_day 设为 true,remind_at 用 "YYYY-MM-DD 00:00"。
    - 重复事项:"每天…"时 repeat_type 为 "daily";"每周一三五…"之类时 repeat_type 为 "weekly",repeat_days 为选中的周几(0=周一 … 6=周日)。repeat_times 为当天的提醒时间点列表,可以有多个(如"每天9点和21点提醒吃药" → ["09:00", "21:00"]);重复事项 remind_at 填第一次提醒的时间。
    - 无法解析出时间时,返回 {"error": "原因"}。
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
        return try await complete(system: system, user: text)
    }

    /// 按自然语言指令修改现有事项;未提到的字段保持原值。
    static func edit(_ current: ParsedTask, instruction: String) async throws -> ParsedTask {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let currentJSON: [String: Any] = [
            "title": current.title,
            "remind_at": formatter.string(from: current.remindAt),
            "all_day": current.allDay,
            "duration_minutes": current.durationMinutes,
            "repeat_type": current.repeatType.rawValue,
            "repeat_days": current.repeatDays,
            "repeat_times": current.repeatTimes,
        ]
        let taskJSON = String(
            data: try JSONSerialization.data(withJSONObject: currentJSON),
            encoding: .utf8) ?? "{}"
        let system = """
        你是提醒事项应用 lodo 的编辑助手。给定一个现有事项和用户的修改指令,\
        输出修改后的完整事项,只返回 JSON,不要任何其他文字。\
        用户没有提到的字段一律保持原值;无法理解指令时返回 {"error": "原因"}。

        \(timeContext)

        现有事项:
        \(taskJSON)

        \(formatAndRules)
        """
        return try await complete(system: system, user: instruction)
    }

    private static func complete(system: String, user: String) async throws -> ParsedTask {
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
