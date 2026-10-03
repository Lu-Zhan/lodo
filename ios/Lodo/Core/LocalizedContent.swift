import Foundation
import LodoCore

/// App-layer labels derived from core models. Core keeps its Chinese captions for
/// scheduler, notification, and cross-platform semantics; views use these when
/// showing the same data in the selected app language.
enum LocalizedContent {
    static func taskCaption(_ task: TaskItem, language: AppLanguage = AppSettings.language) -> String {
        var parts = [dateCaption(task.nextRemindAt, language: language)]
        if task.isRecurring {
            parts.append(repeatCaption(type: task.repeatType, days: task.repeatDays,
                                       times: task.repeatTimes, language: language))
        } else if task.allDay {
            parts.append(LocalizedStrings.text(.shared_all_day, language: language))
        }
        if task.phase == .end {
            parts.append(LocalizedStrings.text(.ios_core_task_in_progress, language: language))
        }
        return parts.joined(separator: " · ")
    }

    static func taskCaption(_ task: ParsedTask, language: AppLanguage = AppSettings.language) -> String {
        var parts = [dateCaption(task.remindAt, language: language)]
        if task.repeatType != .none {
            parts.append(repeatCaption(type: task.repeatType, days: task.repeatDays,
                                       times: task.repeatTimes, language: language))
        } else if task.allDay {
            parts.append(LocalizedStrings.text(.shared_all_day, language: language))
        }
        return parts.joined(separator: " · ")
    }

    static func repeatLabel(_ task: TaskItem,
                            language: AppLanguage = AppSettings.language) -> String {
        repeatCaption(type: task.repeatType, days: task.repeatDays, times: task.repeatTimes,
                      language: language)
    }

    static func routineCaption(_ routine: AIRoutine, language: AppLanguage = AppSettings.language) -> String {
        let times = routine.times.sorted().joined(separator: "/")
        guard !times.isEmpty else {
            return LocalizedStrings.text(.ios_core_no_time_set, language: language)
        }
        if routine.repeatType == .weekly {
            guard !routine.days.isEmpty else {
                return LocalizedStrings.text(.ios_core_no_weekday_selected, language: language)
            }
            return repeatCaption(type: .weekly, days: routine.days, times: routine.times,
                                 language: language)
        }
        return "\(LocalizedStrings.text(.shared_daily, language: language)) \(times)"
    }

    static func routineSubtitle(_ routine: AIRoutine, nextRun: Date?,
                                language: AppLanguage = AppSettings.language) -> String {
        let caption = routineCaption(routine, language: language)
        guard routine.enabled else {
            return "\(caption) · \(String(localized: "已停用", bundle: .appLanguage(language), locale: language.locale))"
        }
        guard let nextRun else { return caption }
        let next = LocalizedStrings.text(.ios_core_next_occurrence, language: language)
        return "\(caption) · \(next) \(dateCaption(nextRun, language: language))"
    }

    /// `timeZone` 给了就按那个时区显示(交通项的出发/到达地当地时间),nil = 本机时区。
    static func time(_ date: Date, language: AppLanguage = AppSettings.language,
                     timeZone: TimeZone? = nil) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute().locale(language.locale)
        if let timeZone { style.timeZone = timeZone }
        return date.formatted(style)
    }

    static func dateTime(_ date: Date, language: AppLanguage = AppSettings.language,
                         timeZone: TimeZone? = nil) -> String {
        var style = Date.FormatStyle.dateTime.month().day().hour().minute().locale(language.locale)
        if let timeZone { style.timeZone = timeZone }
        return date.formatted(style)
    }

    /// 时区的短名:"东京 GMT+9"。用在交通项详情里说明"这是当地时间"。
    static func timeZoneName(_ zone: TimeZone, language: AppLanguage = AppSettings.language) -> String {
        let city = zone.identifier.split(separator: "/").last.map {
            $0.replacingOccurrences(of: "_", with: " ")
        } ?? zone.identifier
        let localized = zone.localizedName(for: .shortGeneric, locale: language.locale)
        let seconds = zone.secondsFromGMT()
        let hours = seconds / 3600
        let minutes = abs(seconds % 3600) / 60
        let offset = minutes == 0 ? String(format: "GMT%+d", hours)
            : String(format: "GMT%+d:%02d", hours, minutes)
        return [localized ?? city, offset].joined(separator: " ")
    }

    static func dateOnly(_ date: Date, language: AppLanguage = AppSettings.language) -> String {
        date.formatted(.dateTime.month().day().locale(language.locale))
    }

    static func dateAndWeekday(_ date: Date, language: AppLanguage = AppSettings.language) -> String {
        date.formatted(.dateTime.month().day().weekday().locale(language.locale))
    }

    static func dateAndWeekdayTime(_ date: Date, language: AppLanguage = AppSettings.language,
                                   timeZone: TimeZone? = nil) -> String {
        var style = Date.FormatStyle.dateTime.month().day().weekday().hour().minute()
            .locale(language.locale)
        if let timeZone { style.timeZone = timeZone }
        return date.formatted(style)
    }

    static func weekdayShortName(_ day: Int, language: AppLanguage = AppSettings.language) -> String {
        guard (0...6).contains(day) else { return "" }
        let symbol = localizedCalendar(language).shortWeekdaySymbols[(day + 1) % 7]
        return language == .zhHans ? String(symbol.dropFirst()) : symbol
    }

    static func dateRangeEndpoint(_ date: Date, language: AppLanguage = AppSettings.language) -> String {
        date.formatted(.dateTime.month().day().year().locale(language.locale))
    }

    static func abbreviatedDateTime(_ date: Date, language: AppLanguage = AppSettings.language) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                                        locale: language.locale))
    }

    static func taskFinishedCaption(language: AppLanguage = AppSettings.language) -> String {
        LocalizedStrings.translate("时间到 — 完成了吗?", language: language)
    }

    static func memoryKindLabel(_ kind: MemoryKind,
                                language: AppLanguage = AppSettings.language) -> String {
        LocalizedStrings.translate(kind.label, language: language)
    }

    static func skillTitle(_ skill: AgentSkillID,
                           language: AppLanguage = AppSettings.language) -> String {
        let key: LK
        switch skill {
        case .agent: key = .ios_core_skill_agent_title
        case .todo: key = .ios_core_skill_todo_title
        case .memory: key = .ios_core_skill_memory_title
        case .webSearch: key = .ios_core_skill_web_search_title
        case .health: key = .ios_core_skill_health_title
        case .travel: key = .ios_core_skill_travel_title
        case .tripPlanner: key = .ios_core_skill_trip_planner_title
        case .news: key = .ios_core_skill_news_title
        case .countdown: key = .ios_core_skill_countdown_title
        case .assetLedger: key = .ios_core_skill_asset_ledger_title
        case .feeds: key = .ios_core_skill_feeds_title
        case .assets: key = .ios_core_skill_assets_title
        case .routineWeb: key = .ios_core_skill_routine_web_title
        }
        return LocalizedStrings.text(key, language: language)
    }

    static func skillSubtitle(_ skill: AgentSkillID,
                              language: AppLanguage = AppSettings.language) -> String {
        let key: LK
        switch skill {
        case .agent: key = .ios_core_skill_agent_subtitle
        case .todo: key = .ios_core_skill_todo_subtitle
        case .memory: key = .ios_core_skill_memory_subtitle
        case .webSearch: key = .ios_core_skill_web_search_subtitle
        case .health: key = .ios_core_skill_health_subtitle
        case .travel: key = .ios_core_skill_travel_subtitle
        case .tripPlanner: key = .ios_core_skill_trip_planner_subtitle
        case .news: key = .ios_core_skill_news_subtitle
        case .countdown: key = .ios_core_skill_countdown_subtitle
        case .assetLedger: key = .ios_core_skill_asset_ledger_subtitle
        case .feeds: key = .ios_core_skill_feeds_subtitle
        case .assets: key = .ios_core_skill_assets_subtitle
        case .routineWeb: key = .ios_core_skill_routine_web_subtitle
        }
        return LocalizedStrings.text(key, language: language)
    }

    static func skillGroupTitle(_ group: AgentSkillGroup,
                                language: AppLanguage = AppSettings.language) -> String {
        let key: LK
        switch group {
        case .system: key = .ios_core_skill_group_system
        case .memory: key = .ios_core_skill_group_memory
        case .travel: key = .ios_core_skill_group_travel
        case .health: key = .ios_core_skill_group_health
        case .news: key = .ios_core_skill_group_news
        case .routine: key = .ios_core_skill_group_routine
        case .custom: key = .ios_core_skill_group_custom
        }
        return LocalizedStrings.text(key, language: language)
    }

    static func relativeTimeLabel(to date: Date, from now: Date = .now,
                                  language: AppLanguage = AppSettings.language) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 {
            return LocalizedStrings.text(.ios_core_relative_started, language: language)
        }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 {
            return String(format: LocalizedStrings.text(.ios_core_relative_minutes,
                                                        language: language), minutes)
        }
        let days = OverviewTime.daysUntil(date, from: now)
        if days == 0 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if remainingMinutes == 0 {
                return String(format: LocalizedStrings.text(.ios_core_relative_hours,
                                                            language: language), hours)
            }
            return String(format: LocalizedStrings.text(.ios_core_relative_hours_minutes,
                                                        language: language), hours,
                          remainingMinutes)
        }
        if days == 1 {
            return String(localized: "明天", bundle: .appLanguage(language), locale: language.locale)
        }
        return String(format: LocalizedStrings.text(.ios_core_relative_days,
                                                    language: language), days)
    }

    private static func repeatCaption(type: RepeatType, days: [Int], times: [String],
                                      language: AppLanguage) -> String {
        let timeText = times.joined(separator: "/")
        guard type == .weekly else {
            return "\(LocalizedStrings.text(.shared_daily, language: language)) \(timeText)"
        }
        let names = days.sorted().compactMap { day -> String? in
            guard (0...6).contains(day) else { return nil }
            let calendar = localizedCalendar(language)
            let symbol = calendar.weekdaySymbols[(day + 1) % 7]
            return language == .zhHans ? String(symbol.dropFirst(2)) : symbol
        }
        let dayText = names.joined(separator: language == .en ? ", " : "、")
        return "\(LocalizedStrings.text(.ios_core_weekly_caption_prefix, language: language))\(dayText) \(timeText)"
    }

    static func dateCaption(_ date: Date, language: AppLanguage = AppSettings.language) -> String {
        let calendar = localizedCalendar(language)
        let timeText = time(date, language: language)
        if calendar.isDateInToday(date) {
            return "\(String(localized: "今天", bundle: .appLanguage(language), locale: language.locale)) \(timeText)"
        }
        if calendar.isDateInTomorrow(date) {
            return "\(String(localized: "明天", bundle: .appLanguage(language), locale: language.locale)) \(timeText)"
        }
        return dateTime(date, language: language)
    }

    private static func localizedCalendar(_ language: AppLanguage) -> Calendar {
        var calendar = Calendar.current
        calendar.locale = language.locale
        return calendar
    }
}

extension Bundle {
    /// 应用内语言对应的语言包(`en.lproj` / `zh-Hans.lproj`);找不到时退回主包。
    ///
    /// 视图外面拼的文案(通知正文、小组件快照、倒数日"还有 12 天"这类)要用
    /// `String(localized: …, bundle: .appLanguage(), locale: …)`:**光传 `locale:` 不够**,
    /// 它只管数字日期的格式,取哪种语言的翻译仍然跟系统语言走——应用内选了中文、
    /// 系统是英文时就会出来"Starts in 3 d"。视图里的 `Text("…")` 不受影响(根上下发了
    /// `\.locale`)。
    static func appLanguage(_ language: AppLanguage = AppSettings.language) -> Bundle {
        if let cached = appLanguageBundles[language] { return cached }
        let bundle = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        appLanguageBundles[language] = bundle
        return bundle
    }
}

nonisolated(unsafe) private var appLanguageBundles: [AppLanguage: Bundle] = [:]
