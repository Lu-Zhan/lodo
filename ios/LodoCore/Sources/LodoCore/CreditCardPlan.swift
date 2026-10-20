import Foundation

/// 信用卡的三种提醒。rawValue 是持久化字符串(备份、共享都不存它,但别改)。
public enum CardReminderKind: String, CaseIterable, Codable, Sendable {
    /// 账单日:出账了,去看一眼这期账单(默认关)。
    case statement
    /// 还款日:最不该漏的那一个(默认开,老数据就是这个)。
    case repayment
    /// 年费:收年费前核对一下,该刷够次数的刷够、该打电话申请减免的去打(默认关)。
    case annualFee
}

/// 年费按什么日子收。rawValue 是持久化字符串(`FinanceEntry.annualFeeBasisRaw`),**别改**。
public enum AnnualFeeBasis: String, CaseIterable, Codable, Sendable {
    /// 不清楚哪天收:可以记金额和减免条件,但开不了提醒。
    case unknown
    /// 每年固定某月某日(看账单或银行 app 上写的)。
    case fixedDate
    /// 只知道开卡月份:按那个月 1 号算,界面上说明"请以银行为准"。
    case openingMonth
}

/// 信用卡的提醒设置与年费资料(`FinanceEntry.cardSettings` 的值快照)。
/// 手写解码:共享同步把它整份编码成一个字段,以后加字段时老数据缺 key 照样解得开。
public struct CreditCardSettings: Equatable, Codable, Sendable {
    public var repaymentRemind: Bool
    public var repaymentLeadDays: Int
    public var statementRemind: Bool
    public var statementLeadDays: Int
    /// nil = 没填,0 = 免年费。
    public var annualFeeAmount: Double?
    public var annualFeeBasis: AnnualFeeBasis
    public var annualFeeMonth: Int?
    public var annualFeeDay: Int?
    public var annualFeeWaiver: String
    public var annualFeeRemind: Bool
    public var annualFeeLeadDays: Int

    public init(repaymentRemind: Bool = true, repaymentLeadDays: Int = 1,
                statementRemind: Bool = false, statementLeadDays: Int = 0,
                annualFeeAmount: Double? = nil, annualFeeBasis: AnnualFeeBasis = .unknown,
                annualFeeMonth: Int? = nil, annualFeeDay: Int? = nil, annualFeeWaiver: String = "",
                annualFeeRemind: Bool = false, annualFeeLeadDays: Int = 30) {
        self.repaymentRemind = repaymentRemind
        self.repaymentLeadDays = repaymentLeadDays
        self.statementRemind = statementRemind
        self.statementLeadDays = statementLeadDays
        self.annualFeeAmount = annualFeeAmount
        self.annualFeeBasis = annualFeeBasis
        self.annualFeeMonth = annualFeeMonth
        self.annualFeeDay = annualFeeDay
        self.annualFeeWaiver = annualFeeWaiver
        self.annualFeeRemind = annualFeeRemind
        self.annualFeeLeadDays = annualFeeLeadDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CreditCardSettings()
        repaymentRemind = try c.decodeIfPresent(Bool.self, forKey: .repaymentRemind) ?? d.repaymentRemind
        repaymentLeadDays = try c.decodeIfPresent(Int.self, forKey: .repaymentLeadDays) ?? d.repaymentLeadDays
        statementRemind = try c.decodeIfPresent(Bool.self, forKey: .statementRemind) ?? d.statementRemind
        statementLeadDays = try c.decodeIfPresent(Int.self, forKey: .statementLeadDays) ?? d.statementLeadDays
        annualFeeAmount = try c.decodeIfPresent(Double.self, forKey: .annualFeeAmount)
        let basis = try c.decodeIfPresent(String.self, forKey: .annualFeeBasis) ?? ""
        annualFeeBasis = AnnualFeeBasis(rawValue: basis) ?? .unknown
        annualFeeMonth = try c.decodeIfPresent(Int.self, forKey: .annualFeeMonth)
        annualFeeDay = try c.decodeIfPresent(Int.self, forKey: .annualFeeDay)
        annualFeeWaiver = try c.decodeIfPresent(String.self, forKey: .annualFeeWaiver) ?? ""
        annualFeeRemind = try c.decodeIfPresent(Bool.self, forKey: .annualFeeRemind) ?? d.annualFeeRemind
        annualFeeLeadDays = try c.decodeIfPresent(Int.self, forKey: .annualFeeLeadDays) ?? d.annualFeeLeadDays
    }

    /// 免年费(金额填的是 0)。
    public var isFeeWaivedOrFree: Bool { annualFeeAmount == 0 }
}

/// 一期提醒:哪种、哪一期(目标日)、什么时候响。
public struct CardReminder: Equatable, Sendable {
    public let cardID: UUID
    public let kind: CardReminderKind
    /// 目标日(还款日 / 账单日 / 收年费那天)的 0 点。名字沿用老的还款提醒。
    public let dueDate: Date
    /// 实际排的提醒时刻:按提前天数算出来的时刻,已经过了就取 now。
    public let remindAt: Date
    /// 按提前天数算出来的时刻(不夹 now);设置改了、提醒还没响时按它原地改。
    public let scheduledAt: Date
    /// 早于这个时刻不生成任务(年费:提醒前 60 天内才建,免得一年后的事挂在任务列表里)。
    public let createAfter: Date
    /// 这一期的标识(目标日 yyyy-MM-dd),存在卡上防重复。
    public let cycle: String
}

public enum CreditCardPlan {
    /// 提前天数的可选值。月度的(账单、还款)不超过半个月——再早就提醒到上一期去了;
    /// 年费最多提前 90 天。
    public static let monthlyLeadChoices = [0, 1, 2, 3, 5, 7, 10, 15]
    public static let annualLeadChoices = [0, 7, 15, 30, 60, 90]
    /// 年费提醒只在提醒时刻前这么多天内才建成任务。
    public static let annualCreationWindowDays = 60

    public static func clampedLead(_ days: Int, kind: CardReminderKind) -> Int {
        switch kind {
        case .statement, .repayment: return min(max(days, 0), 15)
        case .annualFee: return min(max(days, 0), 90)
        }
    }

    /// 这种提醒现在是不是开着且排得出来(开关开着、日子填了;年费还要求不是免年费)。
    public static func isActive(_ card: FinanceSnapshot, kind: CardReminderKind) -> Bool {
        guard card.kind == .creditCard else { return false }
        let s = card.card
        switch kind {
        case .repayment: return s.repaymentRemind && card.dayOfMonth != nil
        case .statement: return s.statementRemind && card.statementDay != nil
        case .annualFee:
            return s.annualFeeRemind && !s.isFeeWaivedOrFree && annualFeeRule(s) != nil
        }
    }

    /// 年费的(月, 日);不清楚日子时 nil。开卡月份按 1 号算。
    public static func annualFeeRule(_ s: CreditCardSettings) -> (month: Int, day: Int)? {
        guard let month = s.annualFeeMonth, (1...12).contains(month) else { return nil }
        switch s.annualFeeBasis {
        case .unknown: return nil
        case .openingMonth: return (month, 1)
        case .fixedDate:
            guard let day = s.annualFeeDay, (1...31).contains(day) else { return nil }
            return (month, day)
        }
    }

    /// 下一次收年费的日子(今天当天也算),日子不存在的年份落在月末(2/29 平年落 2/28)。
    public static func nextAnnualFeeDate(_ s: CreditCardSettings, onOrAfter now: Date,
                                         calendar: Calendar = .current) -> Date? {
        guard let rule = annualFeeRule(s) else { return nil }
        let today = calendar.startOfDay(for: now)
        let year = calendar.component(.year, from: today)
        for y in year...(year + 1) {
            guard let first = calendar.date(from: DateComponents(year: y, month: rule.month, day: 1)),
                  let range = calendar.range(of: .day, in: .month, for: first),
                  let date = calendar.date(from: DateComponents(year: y, month: rule.month,
                                                                day: min(rule.day, range.count))),
                  date >= today else { continue }
            return date
        }
        return nil
    }

    /// 某种提醒的下一个目标日(没开、没填时也照算,给列表展示用)。
    public static func targetDate(_ card: FinanceSnapshot, kind: CardReminderKind, now: Date,
                                  calendar: Calendar = .current) -> Date? {
        guard card.kind == .creditCard else { return nil }
        switch kind {
        case .repayment: return FinancePlan.nextDueDate(card, now: now, calendar: calendar)
        case .statement: return FinancePlan.nextStatementDate(card, now: now, calendar: calendar)
        case .annualFee: return nextAnnualFeeDate(card.card, onOrAfter: now, calendar: calendar)
        }
    }

    /// 这张卡这种提醒的下一期。提醒时刻 = 目标日往前「提前天数」那天的全天提醒时刻
    /// (`allDayTime`,"HH:MM")。**任务提前建好、到那一刻才响**(见 `FinanceReminders`);
    /// 那一刻已经过了而目标日还没过(新加的卡、刚改了日子)时取 now——漏了比多响一次代价大。
    /// 各种提醒的日子各自算,不从账单日去推还款日(账单 25 号、还款次月 13 号时,
    /// 7 月 20 日的下一个还款日是 8 月 13 日,下一个账单日是 7 月 25 日)。
    /// 这里不看开关(`isActive` 管),只要日子算得出来就给。
    public static func reminder(for card: FinanceSnapshot, kind: CardReminderKind, allDayTime: String,
                                now: Date, calendar: Calendar = .current) -> CardReminder? {
        guard let target = targetDate(card, kind: kind, now: now, calendar: calendar) else { return nil }
        let lead: Int = switch kind {
        case .repayment: card.card.repaymentLeadDays
        case .statement: card.card.statementLeadDays
        case .annualFee: card.card.annualFeeLeadDays
        }
        let (hour, minute) = parseTime(allDayTime)
        let day = calendar.date(byAdding: .day, value: -clampedLead(lead, kind: kind), to: target) ?? target
        let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        let createAfter: Date = kind == .annualFee
            ? (calendar.date(byAdding: .day, value: -annualCreationWindowDays, to: at) ?? at)
            : .distantPast
        return CardReminder(cardID: card.id, kind: kind, dueDate: target, remindAt: max(at, now),
                            scheduledAt: at, createAfter: createAfter,
                            cycle: FinancePlan.cycleKey(target, calendar: calendar))
    }

    /// "HH:MM" → (时, 分);格式不对退回 09:00。
    static func parseTime(_ text: String) -> (Int, Int) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return (9, 0) }
        return (h, m)
    }
}
