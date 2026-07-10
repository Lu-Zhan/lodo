import Foundation

/// 应用设置(UserDefaults),视图侧用 @AppStorage 绑定同一批 key。
enum AppSettings {
    static let snoozeMinutesKey = "snoozeMinutes"
    static let allDayTimeKey = "allDayTime"
    static let digestEnabledKey = "digestEnabled"
    static let digestTimeKey = "digestTime"
    static let digestTimesKey = "digestTimes"
    static let digestRepeatTypeKey = "digestRepeatType"
    static let digestDaysKey = "digestDays"
    static let hapticsEnabledKey = "hapticsEnabled"
    static let insightEnabledKey = "insightEnabled"
    static let agentPersonaStyleKey = "agentPersonaStyle"
    static let agentPersonaCustomKey = "agentPersonaCustom"

    static var snoozeMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: snoozeMinutesKey)
        return v > 0 ? v : 15
    }

    /// 全天(仅日期)事项当天的提醒时间,"HH:MM"。
    static var allDayTime: String {
        UserDefaults.standard.string(forKey: allDayTimeKey) ?? "09:00"
    }

    static var digestEnabled: Bool {
        UserDefaults.standard.bool(forKey: digestEnabledKey)
    }

    static var digestTime: String {
        UserDefaults.standard.string(forKey: digestTimeKey) ?? "21:00"
    }

    /// 汇总提醒时间点列表("HH:MM");无新值时迁移旧的单一 digestTime。
    static var digestTimes: [String] {
        let raw = UserDefaults.standard.string(forKey: digestTimesKey) ?? ""
        let times = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return times.isEmpty ? [digestTime] : times
    }

    /// 汇总重复方式:"daily" 或 "weekly"。
    static var digestRepeatType: String {
        UserDefaults.standard.string(forKey: digestRepeatTypeKey) ?? "daily"
    }

    /// weekly 时选中的周几(0=周一 … 6=周日),默认工作日。
    static var digestDays: [Int] {
        let raw = UserDefaults.standard.string(forKey: digestDaysKey) ?? "0,1,2,3,4"
        return raw.split(separator: ",").compactMap { Int($0) }
            .filter { (0...6).contains($0) }.sorted()
    }

    /// 滑动操作振动反馈,默认开。
    static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: hapticsEnabledKey)
    }

    /// 已完成页的每周完成洞察,默认开。
    static var insightEnabled: Bool {
        UserDefaults.standard.object(forKey: insightEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: insightEnabledKey)
    }

    /// AI 个性预设:名称 → 说话风格描述。"默认"为无个性,"自定义"用用户文本。
    static let personaPresets: [(name: String, text: String)] = [
        ("高效秘书", "像一位干练的行政秘书:简洁、专业、直接,不说废话。"),
        ("温柔陪伴", "语气温柔体贴,像关心你的朋友,多一点鼓励。"),
        ("严格教练", "像自律教练:直接有推动力,催促按时完成,语气可以严厉但保持尊重。"),
        ("幽默轻松", "轻松幽默,偶尔调皮,让提醒不那么无聊。"),
    ]

    static var agentPersonaStyle: String {
        UserDefaults.standard.string(forKey: agentPersonaStyleKey) ?? "默认"
    }

    /// 生效的个性描述;默认(无个性)返回 nil。
    static var agentPersona: String? {
        switch agentPersonaStyle {
        case "默认":
            return nil
        case "自定义":
            let custom = (UserDefaults.standard.string(forKey: agentPersonaCustomKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return custom.isEmpty ? nil : custom
        default:
            return personaPresets.first { $0.name == agentPersonaStyle }?.text
        }
    }

    /// 把 "HH:MM" 应用到某一天,得到具体提醒时间。
    static func time(_ hhmm: String, on day: Date) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let hour = parts.count == 2 ? parts[0] : 9
        let minute = parts.count == 2 ? parts[1] : 0
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    static func hhmm(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
