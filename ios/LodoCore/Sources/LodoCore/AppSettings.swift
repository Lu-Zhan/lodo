import Foundation

/// 应用设置(UserDefaults),视图侧用 @AppStorage 绑定同一批 key。
/// 放进 LodoCore(而不是主 App target)是为了让 Watch App 直接调用 DeepSeekClient 时
/// 复用同一份默认值逻辑;Watch 侧 UserDefaults 是设备本地的,不与 iPhone 同步
/// (这轮范围内 Watch 只用这里的合理默认值,设置页本身不做跨设备同步)。
public enum AppSettings {
    public static let snoozeMinutesKey = "snoozeMinutes"
    public static let allDayTimeKey = "allDayTime"
    public static let digestEnabledKey = "digestEnabled"
    public static let digestTimeKey = "digestTime"
    public static let digestTimesKey = "digestTimes"
    public static let digestRepeatTypeKey = "digestRepeatType"
    public static let digestDaysKey = "digestDays"
    public static let hapticsEnabledKey = "hapticsEnabled"
    public static let insightEnabledKey = "insightEnabled"
    public static let agentSilenceTimeoutSecondsKey = "agentSilenceTimeoutSeconds"
    public static let agentPersonaStyleKey = "agentPersonaStyle"
    public static let agentPersonaCustomKey = "agentPersonaCustom"
    public static let aiProviderKey = "aiProvider"
    public static let aiModelKey = "aiModel"
    public static let aiCustomEndpointKey = "aiCustomEndpoint"
    public static let icloudSyncEnabledKey = "icloudSyncEnabled"
    public static let thinkingLevelKey = "thinkingLevel"
    public static let useBuiltInKeyKey = "useBuiltInKey"

    public static var snoozeMinutes: Int {
        let v = UserDefaults.standard.integer(forKey: snoozeMinutesKey)
        return v > 0 ? v : 15
    }

    /// 全天(仅日期)事项当天的提醒时间,"HH:MM"。
    public static var allDayTime: String {
        UserDefaults.standard.string(forKey: allDayTimeKey) ?? "09:00"
    }

    public static var digestEnabled: Bool {
        UserDefaults.standard.bool(forKey: digestEnabledKey)
    }

    public static var digestTime: String {
        UserDefaults.standard.string(forKey: digestTimeKey) ?? "21:00"
    }

    /// 汇总提醒时间点列表("HH:MM");无新值时迁移旧的单一 digestTime。
    public static var digestTimes: [String] {
        let raw = UserDefaults.standard.string(forKey: digestTimesKey) ?? ""
        let times = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return times.isEmpty ? [digestTime] : times
    }

    /// 汇总重复方式:"daily" 或 "weekly"。
    public static var digestRepeatType: String {
        UserDefaults.standard.string(forKey: digestRepeatTypeKey) ?? "daily"
    }

    /// weekly 时选中的周几(0=周一 … 6=周日),默认工作日。
    public static var digestDays: [Int] {
        let raw = UserDefaults.standard.string(forKey: digestDaysKey) ?? "0,1,2,3,4"
        return raw.split(separator: ",").compactMap { Int($0) }
            .filter { (0...6).contains($0) }.sorted()
    }

    /// iCloud 同步(CloudKit),默认开;关闭后仅保存在本机,不与其他设备同步。
    /// 更改后需要重新打开 App 才生效(ModelContainer 只在启动时创建一次)。
    public static var icloudSyncEnabled: Bool {
        UserDefaults.standard.object(forKey: icloudSyncEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: icloudSyncEnabledKey)
    }

    /// AI 助手的思考强度:off/low/medium/high,默认 medium。通过 reasoning_effort
    /// 传给支持推理的服务商/模型(OpenAI 兼容接口的通用字段名),不支持的会忽略这个参数,
    /// 不影响正常使用。只作用于 AI 助手对话入口,不影响解析/汇总等后台小请求。
    public static var thinkingLevel: String {
        UserDefaults.standard.string(forKey: thinkingLevelKey) ?? "medium"
    }

    /// 滑动操作振动反馈,默认开。
    public static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: hapticsEnabledKey)
    }

    /// 已完成页的每周完成洞察,默认开。
    public static var insightEnabled: Bool {
        UserDefaults.standard.object(forKey: insightEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: insightEnabledKey)
    }

    /// 语音录音静音多少秒后自动停止,默认 3 秒;0 = 关闭,不自动停止。
    public static var agentSilenceTimeoutSeconds: Int {
        UserDefaults.standard.object(forKey: agentSilenceTimeoutSecondsKey) == nil
            ? 3
            : UserDefaults.standard.integer(forKey: agentSilenceTimeoutSecondsKey)
    }

    /// AI 服务商预设(均为 OpenAI 兼容的 chat/completions 接口),默认 DeepSeek;
    /// "自定义"支持任何兼容服务(OpenRouter、Ollama 等)。
    public static let aiProviders: [(name: String, endpoint: String, model: String)] = [
        ("DeepSeek", "https://api.deepseek.com/chat/completions", "deepseek-chat"),
        ("OpenAI", "https://api.openai.com/v1/chat/completions", "gpt-4o-mini"),
        ("通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen-plus"),
        ("Kimi", "https://api.moonshot.cn/v1/chat/completions", "moonshot-v1-8k"),
        ("智谱", "https://open.bigmodel.cn/api/paas/v4/chat/completions", "glm-4-flash"),
    ]

    /// 苹果智能(端侧 Foundation Models)的服务商名。
    public static let appleIntelligenceProvider = "苹果智能"

    public static var aiProvider: String {
        UserDefaults.standard.string(forKey: aiProviderKey) ?? "DeepSeek"
    }

    public static var usesAppleIntelligence: Bool {
        aiProvider == appleIntelligenceProvider
    }

    /// "使用内置 API Key"开关(设置页,仅 DeepSeek 服务商下出现);实际是否
    /// 生效还要看 BuiltInAPIKey.deepSeek 是否真的内置了 key,由
    /// KeychainHelper.effectiveAPIKey 兜底判断。默认开——没内置 key 的构建
    /// (BuiltInAPIKey.swift.example 的 nil)这个默认值不会有任何效果,
    /// 仍然安全退回钥匙串。
    public static var useBuiltInKey: Bool {
        UserDefaults.standard.object(forKey: useBuiltInKeyKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: useBuiltInKeyKey)
    }

    /// 当前服务商的接口地址;自定义地址无效时返回 nil。
    public static var aiEndpoint: URL? {
        if aiProvider == "自定义" {
            let custom = (UserDefaults.standard.string(forKey: aiCustomEndpointKey) ?? "")
                .trimmingCharacters(in: .whitespaces)
            return URL(string: custom)
        }
        let preset = aiProviders.first { $0.name == aiProvider } ?? aiProviders[0]
        return URL(string: preset.endpoint)
    }

    /// 当前使用的模型:用户覆盖值优先,否则用服务商默认。
    public static var aiModel: String {
        let override = (UserDefaults.standard.string(forKey: aiModelKey) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        return aiProviders.first { $0.name == aiProvider }?.model ?? aiProviders[0].model
    }

    /// AI 个性预设:名称 → 说话风格描述。"默认"为无个性,"自定义"用用户文本。
    public static let personaPresets: [(name: String, text: String)] = [
        ("高效秘书", "像一位干练的行政秘书:简洁、专业、直接,不说废话。"),
        ("温柔陪伴", "语气温柔体贴,像关心你的朋友,多一点鼓励。"),
        ("严格教练", "像自律教练:直接有推动力,催促按时完成,语气可以严厉但保持尊重。"),
        ("幽默轻松", "轻松幽默,偶尔调皮,让提醒不那么无聊。"),
    ]

    public static var agentPersonaStyle: String {
        UserDefaults.standard.string(forKey: agentPersonaStyleKey) ?? "默认"
    }

    /// 生效的个性描述;默认(无个性)返回 nil。
    public static var agentPersona: String? {
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
    public static func time(_ hhmm: String, on day: Date) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let hour = parts.count == 2 ? parts[0] : 9
        let minute = parts.count == 2 ? parts[1] : 0
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    public static func hhmm(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
