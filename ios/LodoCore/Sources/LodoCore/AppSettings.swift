import Foundation

/// 应用设置(UserDefaults),视图侧用 @AppStorage 绑定同一批 key。
/// 放进 LodoCore(而不是主 App target)是为了让 Watch App 直接调用 DeepSeekClient 时
/// 复用同一份默认值逻辑;Watch 侧 UserDefaults 是设备本地的,不与 iPhone 同步
/// (这轮范围内 Watch 只用这里的合理默认值,设置页本身不做跨设备同步)。
public enum AppSettings {
    public static let snoozeMinutesKey = "snoozeMinutes"
    public static let repeatReminderEnabledKey = "repeatReminderEnabled"
    public static let allDayTimeKey = "allDayTime"
    public static let digestEnabledKey = "digestEnabled"
    public static let digestTimeKey = "digestTime"
    public static let digestTimesKey = "digestTimes"
    public static let digestRepeatTypeKey = "digestRepeatType"
    public static let digestDaysKey = "digestDays"
    public static let hapticsEnabledKey = "hapticsEnabled"
    public static let insightEnabledKey = "insightEnabled"
    public static let agentSilenceTimeoutSecondsKey = "agentSilenceTimeoutSeconds"
    public static let quietHoursEnabledKey = "quietHoursEnabled"
    public static let quietHoursStartKey = "quietHoursStart"
    public static let quietHoursEndKey = "quietHoursEnd"
    public static let sttEngineKey = "sttEngine"
    public static let useBuiltInSTTKeyKey = "useBuiltInSTTKey"
    public static let agentPersonaStyleKey = "agentPersonaStyle"
    public static let agentPersonaCustomKey = "agentPersonaCustom"
    public static let aiProviderKey = "aiProvider"
    public static let aiModelKey = "aiModel"
    public static let aiCustomEndpointKey = "aiCustomEndpoint"
    public static let icloudSyncEnabledKey = "icloudSyncEnabled"
    public static let thinkingLevelKey = "thinkingLevel"
    public static let useBuiltInKeyKey = "useBuiltInKey"
    public static let hasSeenOnboardingKey = "hasSeenOnboarding"
    public static let accentPaletteKey = "accentPalette"
    public static let assetDisplayCurrencyKey = "assetDisplayCurrency"
    public static let languageKey = "appLanguage"
    public static let appIconStyleKey = "appIconStyle"
    public static let openAgentOnLaunchKey = "openAgentOnLaunch"
    public static let healthEnabledKey = "healthEnabled"
    public static let healthRangeDaysKey = "healthRangeDays"
    public static let calendarEnabledKey = "calendarEnabled"
    public static let calendarWriteEnabledKey = "calendarWriteEnabled"
    /// lodo 自己那本日历的标识符(EKCalendar.calendarIdentifier)。只在写开关
    /// 开着时才会有;用户在系统日历里把它删了,下次同步会新建一本并覆盖这里。
    public static let calendarIdentifierKey = "calendarIdentifier"
    /// 日历页上次用的视图(`CalendarViewMode.rawValue`),纯展示偏好。
    public static let calendarViewModeKey = "calendarViewMode"
    /// 总览页的 widget 布局(`OverviewLayout.encoded()` 的 JSON),纯展示偏好、只存本机。
    public static let overviewLayoutKey = "overviewLayout"

    /// 健康分析总开关。**默认关**:读健康数据要系统授权,而且开了之后汇总统计
    /// 会发给所选 AI 服务商——这种事不该替用户默认打开。关着时健康页只画本地
    /// 图表,一个网络请求都不发。
    public static var healthEnabled: Bool {
        UserDefaults.standard.bool(forKey: healthEnabledKey)
    }

    /// 系统日历总开关(读)。**默认关**:读日历要系统授权,不该替用户默认打开。
    /// 关着时日历页只显示一个「连接日历」的引导,一次 EventKit 调用都不发。
    public static var calendarEnabled: Bool {
        UserDefaults.standard.bool(forKey: calendarEnabledKey)
    }

    /// 把 lodo 任务写进系统日历。**默认关**,而且是 `calendarEnabled` 的下级——
    /// 往用户的日历里写东西比读更重,要单独点一次头。
    public static var calendarWriteEnabled: Bool {
        calendarEnabled && UserDefaults.standard.bool(forKey: calendarWriteEnabledKey)
    }

    public static var calendarIdentifier: String? {
        UserDefaults.standard.string(forKey: calendarIdentifierKey)
    }

    public static func setCalendarIdentifier(_ identifier: String?) {
        let defaults = UserDefaults.standard
        if let identifier {
            defaults.set(identifier, forKey: calendarIdentifierKey)
        } else {
            defaults.removeObject(forKey: calendarIdentifierKey)
        }
    }

    /// 健康数据回看天数,默认 14 天(够算出"最近 7 天 vs 之前 7 天"的趋势)。
    public static var healthRangeDays: Int {
        let v = UserDefaults.standard.integer(forKey: healthRangeDaysKey)
        return v > 0 ? v : 14
    }

    /// 「反复提醒」总开关,**默认开**——这是 lodo 的核心("纠缠式提醒":到期后
    /// 每隔一个稍等间隔重响直到完成)。关掉后到期只提醒一次,事项仍然 pending、
    /// 仍然逾期,只是不再反复敲门;用户主动点的「稍等」不受影响。
    public static var repeatReminderEnabled: Bool {
        UserDefaults.standard.object(forKey: repeatReminderEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: repeatReminderEnabledKey)
    }

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

    /// 免打扰时段:只影响到期提醒是否弹通知,不影响到期状态本身;默认开、
    /// 22:00–08:00。
    public static var quietHoursEnabled: Bool {
        UserDefaults.standard.object(forKey: quietHoursEnabledKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: quietHoursEnabledKey)
    }

    public static var quietHoursStart: String {
        UserDefaults.standard.string(forKey: quietHoursStartKey) ?? "22:00"
    }

    public static var quietHoursEnd: String {
        UserDefaults.standard.string(forKey: quietHoursEndKey) ?? "08:00"
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

    /// AI 助手的思考强度:off/low/medium/high,默认 low。通过 reasoning_effort
    /// 传给支持推理的服务商/模型(OpenAI 兼容接口的通用字段名),不支持的会忽略这个参数,
    /// 不影响正常使用。只作用于 AI 助手对话入口,不影响解析/汇总等后台小请求。
    public static var thinkingLevel: String {
        UserDefaults.standard.string(forKey: thinkingLevelKey) ?? "low"
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

    /// 冷启动完成引导后是否直接弹出 AI 助手,默认开。只在真正的冷启动生效
    /// (ContentView 用一次性 @State 标记防止重复触发),不影响退到后台再回前台。
    public static var openAgentOnLaunch: Bool {
        UserDefaults.standard.object(forKey: openAgentOnLaunchKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: openAgentOnLaunchKey)
    }

    /// 语音录音静音多少秒后自动停止,默认 3 秒;0 = 关闭,不自动停止。
    public static var agentSilenceTimeoutSeconds: Int {
        UserDefaults.standard.object(forKey: agentSilenceTimeoutSecondsKey) == nil
            ? 3
            : UserDefaults.standard.integer(forKey: agentSilenceTimeoutSecondsKey)
    }

    /// 语音转文字引擎:"qwenASR"(云端,默认)或 "system"(iOS 自带 SFSpeechRecognizer)。
    public static var sttEngine: String {
        UserDefaults.standard.string(forKey: sttEngineKey) ?? "qwenASR"
    }

    /// STT "使用内置 API Key"开关,默认开,语义与 useBuiltInKey 一致。
    public static var useBuiltInSTTKey: Bool {
        UserDefaults.standard.object(forKey: useBuiltInSTTKeyKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: useBuiltInSTTKeyKey)
    }

    /// AI 服务商预设(均为 OpenAI 兼容的 chat/completions 接口),默认 DeepSeek;
    /// "自定义"支持任何兼容服务(OpenRouter、Ollama 等)。
    public static let aiProviders: [(name: String, endpoint: String, model: String)] = [
        // 排第一个 = 默认服务商(见 defaultAIProvider)。两条走同一个接口、
        // 同一把 key,区别只在 model 字段。名字直接跟着模型走:DeepSeek 的
        // /models 目前只给这两个,别再填别的代号——`deepseek-v4.1-flash` 已经
        // 下线(直接 400),`deepseek-v4-flash-vision-exp` 服务端静默映射成
        // deepseek-flash(能用,但名字和实际跑的模型对不上)。
        ("DeepSeek Flash", "https://api.deepseek.com/chat/completions", "deepseek-flash"),
        ("DeepSeek V4 Pro", "https://api.deepseek.com/chat/completions", "deepseek-v4-pro"),
        ("GPT-5.6 Luna", "https://runapi.host/v1/chat/completions", "gpt-5.6-luna"),
        ("Qwen3.5 Flash", "https://runapi.host/v1/chat/completions", "qwen3.5-flash"),
        ("OpenAI", "https://api.openai.com/v1/chat/completions", "gpt-4o-mini"),
        ("通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", "qwen-plus"),
        ("Kimi", "https://api.moonshot.cn/v1/chat/completions", "moonshot-v1-8k"),
        ("智谱", "https://open.bigmodel.cn/api/paas/v4/chat/completions", "glm-4-flash"),
    ]

    /// 苹果智能(端侧 Foundation Models)的服务商名。
    public static let appleIntelligenceProvider = "苹果智能"

    /// 没选过服务商时用哪个。改这个值会让"从没进过设置页"的老用户也一起换过去
    /// ——他们本来就没做过选择,跟着默认走是预期行为。
    public static let defaultAIProvider = "DeepSeek Flash"

    /// 老版本存下来的服务商名 → 现在的名字。两个 DeepSeek 预设原来按当时的模型
    /// 代号命名,那两个模型都已经不在 API 上了(见 aiProviders 的注释),改名成
    /// 现在真实存在的两个。**老用户一律落到 flash 那档**——原来两条都是 flash
    /// 档位,不能借改名把人悄悄换到更贵的 pro 上。读取时映射,不改写存储:
    /// 用户再进一次设置页选定什么就写什么。
    public static let renamedAIProviders: [String: String] = [
        "DeepSeek V4 Flash Vision": "DeepSeek Flash",
        "DeepSeek": "DeepSeek Flash",
    ]

    /// 新服务商名 → 还可以沿用哪些老名字底下存着的 key。同一个 DeepSeek 账号
    /// 同一把 key,只是模型不同,改名后不该让人重新填一遍(KeychainHelper
    /// 读不到新名字时按这个顺序回退;Android `SettingsRepository` 同名同义)。
    public static let apiKeyAliases: [String: [String]] = [
        "DeepSeek Flash": ["DeepSeek V4 Flash Vision", "DeepSeek"],
        "DeepSeek V4 Pro": ["DeepSeek V4 Flash Vision", "DeepSeek"],
    ]

    public static var aiProvider: String {
        let stored = UserDefaults.standard.string(forKey: aiProviderKey) ?? defaultAIProvider
        return renamedAIProviders[stored] ?? stored
    }

    public static var usesAppleIntelligence: Bool {
        aiProvider == appleIntelligenceProvider
    }

    /// "使用内置 API Key"开关(设置页,仅当前服务商在 BuiltInAPIKey.key(for:)
    /// 里真的有内置值时才出现,目前是 DeepSeek、GPT-5.6 Luna);实际是否
    /// 生效由 KeychainHelper.effectiveAPIKey 兜底判断。默认开——没内置 key 的构建
    /// (BuiltInAPIKey.swift.example 全是 nil)这个默认值不会有任何效果,
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

    /// 强调色预设的标识(UI 侧 `AccentPalette` 的 rawValue)。默认 `terracotta`
    /// ——赤陶橙,浅色下 #C2410C 对白底 5.18、暗色下 #FF9E4D 对 #1C1C1E 约 7,
    /// 两种模式的文字与图形都过 WCAG AA;系统橙 #FF9500 白底只有 2.20,
    /// 当强调色时彩色小字/细图标会发虚,所以默认值**不是**系统橙。
    /// 值放在 LodoCore 只是为了和其余设置同源,真正的颜色定义在 app 层
    /// (LodoCore 不依赖 SwiftUI)。
    public static var accentPalette: String {
        UserDefaults.standard.string(forKey: accentPaletteKey) ?? "terracotta"
    }

    /// personaPresets/aiProviders 里的 `name` 同时用作存储匹配键(如
    /// `agentPersonaStyle`)和展示文案——存储值永远保持中文原文不翻译,这里只做
    /// 展示层的中 → 英映射,不改 personaPresets/aiProviders 数组本身。
    private static let personaDisplayNames: [String: String] = [
        "高效秘书": "Efficient Secretary", "温柔陪伴": "Gentle Companion",
        "严格教练": "Strict Coach", "幽默轻松": "Playful & Witty",
        "默认": "Default", "自定义": "Custom",
    ]
    private static let providerDisplayNames: [String: String] = [
        "通义千问": "Tongyi Qianwen", "智谱": "Zhipu", "苹果智能": "Apple Intelligence",
    ]

    public static func displayName(forPersona name: String, language: AppLanguage) -> String {
        language == .en ? (personaDisplayNames[name] ?? name) : name
    }
    public static func displayName(forProvider name: String, language: AppLanguage) -> String {
        language == .en ? (providerDisplayNames[name] ?? name) : name
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

    /// 是否已经看过首次引导;默认 false(未设置过等于没看过)。
    public static var hasSeenOnboarding: Bool {
        UserDefaults.standard.bool(forKey: hasSeenOnboardingKey)
    }

    /// 资产总览的汇总展示币种(把不同币种的资产换算成同一种货币求和),默认人民币。
    public static var assetDisplayCurrency: String {
        UserDefaults.standard.string(forKey: assetDisplayCurrencyKey) ?? "CNY"
    }

    /// 应用内语言开关,不跟随系统语言,默认中文。View 层用 @AppStorage 读同一个
    /// key(见 ios/Lodo/LodoApp.swift 的 .environment(\.locale) 注入);这里的 get/set
    /// 供非 View 上下文(通知、错误文案等)读取当前语言、以及设置页之外的地方
    /// (如 Watch 应用自己的启动逻辑)显式写入用。
    public static var language: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .zhHans }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: languageKey) }
    }

    /// App 图标配色(莫兰迪色系),默认白色。
    public static var appIconStyle: AppIconStyle {
        AppIconStyle(rawValue: UserDefaults.standard.string(forKey: appIconStyleKey) ?? "") ?? .white
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
