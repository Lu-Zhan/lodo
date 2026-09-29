import Foundation
import SwiftData

/// 资产页里"钱是怎么进出的"那一部分:收入(工资、奖金)、固定支出(房贷车贷、房租、
/// 保险)、信用卡。**不记日常消费**——资产页的定位是隔几个月更新一次的资产台账,
/// 不是记账本。
///
/// 独立轻量模型(同 `PackingItem`/`MenuDish`),**不进记忆库**:一张信用卡、一笔工资
/// 不是值得收藏的资料,混进记忆会把记忆搜索和向量索引刷脏。车子、房产、存款这些
/// "有多少钱"的资产仍是打了「资产」标签的记忆条目(`MemoryItem.assetTagName`),
/// AI 收藏、记忆搜索、问 AI 都能命中它们。
///
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
@Model
public final class FinanceEntry {
    public var uuid: UUID = UUID()
    /// `FinanceKind` 的存储值(income / expense / creditCard),**别改这几个字符串**。
    public var kindRaw: String = FinanceKind.income.rawValue
    public var title: String = ""
    /// 收入/支出的金额;信用卡是额度。
    public var amount: Double?
    public var currency: String = "CNY"
    /// `FinanceCadence` 的存储值(monthly / quarterly / yearly / irregular)。信用卡不用。
    public var cadenceRaw: String = FinanceCadence.monthly.rawValue
    /// 每月几号(1–31):收入是发薪日、支出是扣款日、信用卡是**还款日**。月份不够长时落在月末。
    public var dayOfMonth: Int?
    /// 信用卡的账单日(1–31)。
    public var statementDay: Int?
    /// 信用卡所属银行;收入/支出可以写付款方/收款方(公司、银行),可空。
    public var institution: String = ""
    /// 支出的截止日期(房贷还到哪年哪月);过了这天不再计入每月支出。
    public var endDate: Date?
    public var notes: String = ""
    /// 信用卡:还款日前一天自动生成一条提醒任务(默认开)。
    public var remindEnabled: Bool = true
    /// 最近一次生成的还款提醒是哪一期(还款日 yyyy-MM-dd)和那条任务,防止重复生成。
    public var reminderCycle: String = ""
    public var reminderTaskUUID: UUID?
    public var sortIndex: Int = 0
    /// 最近一次改动金额/额度的时间("上次更新 3 个月前")。
    public var updatedAt: Date = Date.now
    public var createdAt: Date = Date.now
    /// 在哪本共享资产台账里(同 `MemoryItem.assetLedgerUUID`);nil = 没共享。不进备份。
    public var ledgerUUID: UUID?
    /// 共享台账里别人加的:添加人的显示名(「由 X 添加」),同 `MemoryItem.sharedAddedBy`。
    public var sharedAddedBy: String?

    public init(uuid: UUID = UUID(), kind: FinanceKind, title: String, amount: Double? = nil,
                currency: String = "CNY", cadence: FinanceCadence = .monthly,
                dayOfMonth: Int? = nil, statementDay: Int? = nil, institution: String = "",
                endDate: Date? = nil, notes: String = "", remindEnabled: Bool = true,
                sortIndex: Int = 0, updatedAt: Date = .now, createdAt: Date = .now) {
        self.uuid = uuid
        self.kindRaw = kind.rawValue
        self.title = title
        self.amount = amount
        self.currency = currency
        self.cadenceRaw = cadence.rawValue
        self.dayOfMonth = dayOfMonth
        self.statementDay = statementDay
        self.institution = institution
        self.endDate = endDate
        self.notes = notes
        self.remindEnabled = remindEnabled
        self.sortIndex = sortIndex
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }

    public var kind: FinanceKind {
        get { FinanceKind(rawValue: kindRaw) ?? .income }
        set { kindRaw = newValue.rawValue }
    }

    public var cadence: FinanceCadence {
        get { FinanceCadence(rawValue: cadenceRaw) ?? .monthly }
        set { cadenceRaw = newValue.rawValue }
    }

    /// 纯逻辑层用的值快照。
    public var snapshot: FinanceSnapshot {
        FinanceSnapshot(id: uuid, kind: kind, title: title, amount: amount, currency: currency,
                        cadence: cadence, dayOfMonth: dayOfMonth, statementDay: statementDay,
                        institution: institution, endDate: endDate, updatedAt: updatedAt)
    }
}

public enum FinanceKind: String, CaseIterable, Codable, Sendable {
    case income, expense, creditCard
}

public enum FinanceCadence: String, CaseIterable, Codable, Sendable {
    case monthly, quarterly, yearly, irregular

    /// 折算成每月多少(不定期的不折算,返回 nil——奖金发不发、发多少说不准,
    /// 硬摊到每月会让"每月结余"看上去比实际宽裕)。
    public var monthlyFactor: Double? {
        switch self {
        case .monthly: return 1
        case .quarterly: return 1.0 / 3
        case .yearly: return 1.0 / 12
        case .irregular: return nil
        }
    }
}

/// `FinanceEntry` 的值快照(和 `TaskData` ↔ `TaskItem` 同一个分层),单测不碰 SwiftData。
public struct FinanceSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: FinanceKind
    public let title: String
    public let amount: Double?
    public let currency: String
    public let cadence: FinanceCadence
    public let dayOfMonth: Int?
    public let statementDay: Int?
    public let institution: String
    public let endDate: Date?
    public let updatedAt: Date

    public init(id: UUID = UUID(), kind: FinanceKind, title: String, amount: Double? = nil,
                currency: String = "CNY", cadence: FinanceCadence = .monthly,
                dayOfMonth: Int? = nil, statementDay: Int? = nil, institution: String = "",
                endDate: Date? = nil, updatedAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.title = title
        self.amount = amount
        self.currency = currency
        self.cadence = cadence
        self.dayOfMonth = dayOfMonth
        self.statementDay = statementDay
        self.institution = institution
        self.endDate = endDate
        self.updatedAt = updatedAt
    }
}

public enum FinancePlan {
    // MARK: - 每月收支

    public struct MonthlyTotal: Equatable, Sendable {
        public var income: Double = 0
        public var expense: Double = 0
        public var net: Double { income - expense }
        /// 换不出汇率、没有计入的币种(同 `TravelTotal.missingCurrencies`:宁可少算也不拿错汇率糊弄)。
        public var missingCurrencies: [String] = []
        /// 不定期的收入/支出条数(不折算进每月,单独说一声)。
        public var irregularCount: Int = 0
    }

    /// 每月收入、固定支出折算到 `currency`。已经过了截止日期的支出(房贷还清了)不算;
    /// 信用卡不参与(额度不是钱的进出)。
    public static func monthlyTotal(_ entries: [FinanceSnapshot], in currency: String, now: Date,
                                    convert: (Double, String, String) -> Double?) -> MonthlyTotal {
        var total = MonthlyTotal()
        var missing: [String] = []
        for entry in entries where entry.kind != .creditCard {
            guard let amount = entry.amount else { continue }
            if entry.kind == .expense, let end = entry.endDate, end < now { continue }
            guard let factor = entry.cadence.monthlyFactor else {
                total.irregularCount += 1
                continue
            }
            let converted = entry.currency == currency ? amount : convert(amount, entry.currency, currency)
            guard let converted else {
                if !missing.contains(entry.currency) { missing.append(entry.currency) }
                continue
            }
            if entry.kind == .income { total.income += converted * factor }
            else { total.expense += converted * factor }
        }
        total.missingCurrencies = missing.sorted()
        return total
    }

    // MARK: - 信用卡日期

    /// 每月 `day` 号在 `now` 当天或之后最近的那一天(0 点)。月份不够长时落在月末
    /// (31 号还款的卡,二月落 28/29 号)。
    public static func nextDate(day: Int, onOrAfter now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        for offset in 0..<3 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: today),
                  let range = calendar.range(of: .day, in: .month, for: month) else { continue }
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = min(max(day, 1), range.count)
            if let date = calendar.date(from: components), date >= today { return date }
        }
        return today
    }

    /// 下一次还款日(还款日当天也算"这一期",当天还没过)。
    public static func nextDueDate(_ card: FinanceSnapshot, now: Date,
                                   calendar: Calendar = .current) -> Date? {
        guard card.kind == .creditCard, let day = card.dayOfMonth else { return nil }
        return nextDate(day: day, onOrAfter: now, calendar: calendar)
    }

    public static func nextStatementDate(_ card: FinanceSnapshot, now: Date,
                                         calendar: Calendar = .current) -> Date? {
        guard card.kind == .creditCard, let day = card.statementDay else { return nil }
        return nextDate(day: day, onOrAfter: now, calendar: calendar)
    }

    /// 离某天还有几天(0 = 今天)。
    public static func daysUntil(_ date: Date, from now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                to: calendar.startOfDay(for: date)).day ?? 0
    }

    /// 一期还款提醒:哪一期(还款日)、提醒时刻(还款日前一天的全天提醒时刻)。
    public struct CardReminder: Equatable, Sendable {
        public let cardID: UUID
        public let dueDate: Date
        public let remindAt: Date
        /// 这一期的标识(还款日 yyyy-MM-dd),存在卡上防重复。
        public let cycle: String
    }

    /// 这张卡下一期的还款提醒。"到期前一天变成一条提醒任务":提醒时刻是还款日前一天的
    /// `allDayTime`("HH:MM",设置里的全天提醒时刻)。**任务提前建好、到那一刻才响**——
    /// 不能等到前一天才去生成:那天 app 没打开就漏了,而通知链是预排的,不需要 app 在跑。
    /// 前一天的提醒时刻已经过了(新加的卡、还款日就是今天明天)时提醒时刻取 `now`,
    /// 还款日当天也照样提醒一次——漏了还款比多响一次代价大得多。
    public static func reminder(for card: FinanceSnapshot, allDayTime: String, now: Date,
                                calendar: Calendar = .current) -> CardReminder? {
        guard let due = nextDueDate(card, now: now, calendar: calendar) else { return nil }
        let parts = allDayTime.split(separator: ":").compactMap { Int($0) }
        let hour = parts.count == 2 ? parts[0] : 9
        let minute = parts.count == 2 ? parts[1] : 0
        let eve = calendar.date(byAdding: .day, value: -1, to: due) ?? due
        let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: eve) ?? eve
        return CardReminder(cardID: card.id, dueDate: due, remindAt: max(at, now),
                            cycle: cycleKey(due, calendar: calendar))
    }

    public static func cycleKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - 多久没更新

    /// 资产页定位是"隔几个月更新一次":最久没更新的那一项过了多少个月。
    /// 超过 `staleMonths` 个月才提醒——更频繁地催没有意义。
    public static let staleMonths = 3

    public static func monthsSince(_ date: Date, now: Date, calendar: Calendar = .current) -> Int {
        max(0, calendar.dateComponents([.month], from: date, to: now).month ?? 0)
    }
}

// MARK: - 资产(车房存款这些"有多少钱")

/// 资产的预设分类。资产本身是打了「资产」标签的记忆条目,分类就是它的另一个标签
/// (`MemoryPipeline.saveAsset` 一直是这么存的),这里只给常用的几个一个固定顺序和图标;
/// 用户自己写的别的分类照样认,排在预设后面。
public enum AssetCategory {
    /// 预设分类(持久化的就是这几个中文字符串本身——它们是记忆条目的标签)。
    public static let presets = ["房产", "车辆", "存款", "投资", "保险", "其他"]

    public static func symbol(for category: String) -> String {
        switch category {
        case "房产": return "house.fill"
        case "车辆": return "car.fill"
        case "存款": return "banknote.fill"
        case "投资": return "chart.line.uptrend.xyaxis"
        case "保险": return "shield.lefthalf.filled"
        default: return "shippingbox.fill"
        }
    }

    /// 一条资产的分类:除保留标签外的第一个标签;没有就归「其他」。
    public static func category(of tags: [String], reserved: Set<String>) -> String {
        tags.first { !reserved.contains($0) } ?? "其他"
    }

    /// 分组顺序:预设按固定顺序,自定义的按首次出现排在预设之间「其他」之前。
    public static func orderedGroups(_ categories: [String]) -> [String] {
        var custom: [String] = []
        for c in categories where !presets.contains(c) && !custom.contains(c) { custom.append(c) }
        let used = Set(categories)
        let head = presets.dropLast().filter(used.contains)
        return head + custom + (used.contains("其他") ? ["其他"] : [])
    }
}

extension FinancePlan {
    public struct NetWorth: Equatable, Sendable {
        public var assets: Double = 0
        public var liabilities: Double = 0
        public var net: Double { assets - liabilities }
        public var missingCurrencies: [String] = []
        /// 没填金额的资产数(不计入总额,如实说一声)。
        public var unvaluedCount: Int = 0
    }

    /// 净资产 = 资产金额合计 − 负债合计(房贷车贷本金),折算到 `currency`。
    /// 换不出汇率的币种不计入并报回来(同 `monthlyTotal`)。
    public static func netWorth(_ items: [(value: Double?, liability: Double?, currency: String)],
                                in currency: String,
                                convert: (Double, String, String) -> Double?) -> NetWorth {
        var result = NetWorth()
        var missing: [String] = []
        func converted(_ amount: Double, _ from: String) -> Double? {
            if from == currency { return amount }
            let value = convert(amount, from, currency)
            if value == nil, !missing.contains(from) { missing.append(from) }
            return value
        }
        for item in items {
            if let value = item.value {
                result.assets += converted(value, item.currency) ?? 0
            } else if item.liability == nil {
                result.unvaluedCount += 1
            }
            if let liability = item.liability {
                result.liabilities += converted(liability, item.currency) ?? 0
            }
        }
        result.missingCurrencies = missing.sorted()
        return result
    }
}
