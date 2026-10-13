import Foundation

/// 体检条目的种类。rawValue 是持久化字符串,**别改**。
public enum CheckupEntryKind: String, CaseIterable, Sendable {
    /// 一项指标/检查项(数值或文字结论)。
    case item
    /// 整份报告的综合建议/总检结论,一份报告最多一条。
    case advice
}

/// 报告上对一项结果的标记。rawValue 是持久化字符串,**别改**。
public enum CheckupFlag: String, CaseIterable, Sendable {
    case normal
    case high
    case low
    /// 文字类结果的"异常"(阳性、结节…),没有高低方向。
    case abnormal

    public var isAbnormal: Bool { self != .normal }

    /// 列表上那个小箭头。
    public var symbol: String {
        switch self {
        case .normal: return "checkmark"
        case .high: return "arrow.up"
        case .low: return "arrow.down"
        case .abnormal: return "exclamationmark"
        }
    }
}

/// 条目的值快照:纯逻辑层只认它,不碰 SwiftData(和 `MenuDishEntry` 同一个分层)。
public struct CheckupEntryValue: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var reportID: UUID
    public var kind: CheckupEntryKind
    public var category: String
    public var name: String
    public var value: String
    public var unit: String
    public var referenceRange: String
    public var flag: CheckupFlag?
    public var conclusion: String
    public var advice: String
    public var date: Date
    public var sortIndex: Int

    public init(id: UUID = UUID(), reportID: UUID, kind: CheckupEntryKind = .item,
                category: String = "", name: String = "", value: String = "", unit: String = "",
                referenceRange: String = "", flag: CheckupFlag? = nil, conclusion: String = "",
                advice: String = "", date: Date, sortIndex: Int = 0) {
        self.id = id
        self.reportID = reportID
        self.kind = kind
        self.category = category
        self.name = name
        self.value = value
        self.unit = unit
        self.referenceRange = referenceRange
        self.flag = flag
        self.conclusion = conclusion
        self.advice = advice
        self.date = date
        self.sortIndex = sortIndex
    }

    public init(from entry: CheckupEntry) {
        self.init(id: entry.uuid, reportID: entry.reportUUID, kind: entry.kind,
                  category: entry.category, name: entry.name, value: entry.value,
                  unit: entry.unit, referenceRange: entry.referenceRange, flag: entry.flag,
                  conclusion: entry.conclusion, advice: entry.advice, date: entry.date,
                  sortIndex: entry.sortIndex)
    }

    /// 结果的数值(能解析时)。
    public var numericValue: Double? { CheckupPlan.numericValue(value) }

    /// 报告没标记时按参考范围推一个高低(只对数值能推);标了就用标的。
    public var effectiveFlag: CheckupFlag? {
        if let flag { return flag }
        guard let number = numericValue else { return nil }
        let bounds = CheckupPlan.referenceBounds(referenceRange)
        if let low = bounds.low, number < low { return .low }
        if let high = bounds.high, number > high { return .high }
        return bounds.low == nil && bounds.high == nil ? nil : .normal
    }

    /// 一行展示用的结果:"5.6 mmol/L" / "阴性";值为空时退回结论。
    public var displayValue: String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return conclusion }
        return unit.isEmpty ? trimmed : "\(trimmed) \(unit)"
    }
}

/// 一项指标在时间轴上的全部记录(按指标看的那一档)。
public struct CheckupMetric: Equatable, Sendable, Identifiable {
    /// 归并用的键(`CheckupPlan.metricKey`)。
    public var key: String
    /// 显示名:最近一次报告里的写法。
    public var name: String
    public var category: String
    /// 按日期从早到晚。
    public var records: [CheckupEntryValue]

    public var id: String { key }
    public var latest: CheckupEntryValue? { records.last }
    /// 有一半以上的记录能解析出数字就当数值指标画折线。
    public var isNumeric: Bool {
        let numeric = records.filter { $0.numericValue != nil }.count
        return numeric > 0 && numeric * 2 >= records.count
    }
    /// 能画上图的点(按日期)。
    public var points: [(date: Date, value: Double)] {
        records.compactMap { record in record.numericValue.map { (record.date, $0) } }
    }
    /// 最近一次的参考范围上下限(图上画参考带用)。
    public var referenceBounds: (low: Double?, high: Double?) {
        CheckupPlan.referenceBounds(records.last(where: { !$0.referenceRange.isEmpty })?.referenceRange ?? "")
    }
}

/// AI 整理出来的一项(落库前)。
public struct ParsedCheckupItem: Equatable, Sendable {
    public var category: String
    public var name: String
    public var value: String
    public var unit: String
    public var reference: String
    public var flag: CheckupFlag?
    public var conclusion: String
    public var advice: String

    public init(category: String = "", name: String, value: String = "", unit: String = "",
                reference: String = "", flag: CheckupFlag? = nil, conclusion: String = "",
                advice: String = "") {
        self.category = category
        self.name = name
        self.value = value
        self.unit = unit
        self.reference = reference
        self.flag = flag
        self.conclusion = conclusion
        self.advice = advice
    }
}

/// 一整份报告的整理结果。
public struct ParsedCheckupReport: Equatable, Sendable {
    public var title: String
    public var date: Date?
    public var institution: String
    public var items: [ParsedCheckupItem]
    /// 报告里的综合建议/总检结论;没有为空串。
    public var summaryAdvice: String

    public init(title: String = "", date: Date? = nil, institution: String = "",
                items: [ParsedCheckupItem], summaryAdvice: String = "") {
        self.title = title
        self.date = date
        self.institution = institution
        self.items = items
        self.summaryAdvice = summaryAdvice
    }
}

/// 一份报告在纯逻辑层的样子(时间轴、分享、AI 上下文用)。
public struct CheckupReportValue: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var date: Date
    public var institution: String

    public init(id: UUID, title: String, date: Date, institution: String = "") {
        self.id = id
        self.title = title
        self.date = date
        self.institution = institution
    }
}

public enum CheckupPlan {

    // MARK: - 数值与参考范围

    /// 从结果里解析数字:"5.6"、"<0.5"、"≥ 10"、"1,234"、"5.6↑" 都认;"阴性"、"1+"、
    /// "2-5/HP" 这类不是一个数的不认(尿常规的"1+"按数值画线是错的)。
    public static func numericValue(_ text: String) -> Double? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        while let first = rest.first, "<>≤≥＜＞=".contains(first) {
            rest = rest.dropFirst().drop(while: { $0 == " " })
        }
        var digits = ""
        var index = rest.startIndex
        if index < rest.endIndex, rest[index] == "-" || rest[index] == "+" {
            digits.append(rest[index])
            index = rest.index(after: index)
        }
        var sawDigit = false
        while index < rest.endIndex {
            let char = rest[index]
            if char.isASCII, char.isNumber {
                digits.append(char)
                sawDigit = true
            } else if char == "." {
                digits.append(char)
            } else if char == "," {
                // 千分位逗号跳过。
            } else {
                break
            }
            index = rest.index(after: index)
        }
        guard sawDigit, let number = Double(digits) else { return nil }
        let tail = rest[index...].trimmingCharacters(in: .whitespaces)
        if let next = tail.first, "+-~/～–—".contains(next) { return nil }
        return number
    }

    /// 参考范围的上下限:"3.9-6.1"、"3.9~6.1"、"3.9–6.1"、"<5.2"、"≤5.2"、">1.04"。
    /// 认不出来两头都是 nil。
    public static func referenceBounds(_ text: String) -> (low: Double?, high: Double?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (nil, nil) }
        if let first = trimmed.first, "<≤＜".contains(first) {
            return (nil, numericValue(String(trimmed.dropFirst())))
        }
        if let first = trimmed.first, ">≥＞".contains(first) {
            return (numericValue(String(trimmed.dropFirst())), nil)
        }
        for separator in ["~", "～", "–", "—", "-"] {
            // 从第二个字符起找分隔符:开头的负号不是分隔符。
            let body = trimmed.dropFirst()
            guard let range = body.range(of: separator) else { continue }
            let low = numericValue(String(trimmed[..<range.lowerBound]))
            let high = numericValue(String(trimmed[range.upperBound...]))
            if low != nil || high != nil { return (low, high) }
        }
        return (nil, nil)
    }

    // MARK: - 时间轴

    /// 归并同一项指标用的键:去空白、统一全半角括号、忽略大小写。"总胆固醇(TC)" 和
    /// "总胆固醇（TC）" 是同一项;名字写法差得更远的靠整理时把已有指标名交给 AI 沿用。
    public static func metricKey(_ name: String) -> String {
        name.replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .filter { !$0.isWhitespace }
            .lowercased()
    }

    /// 把条目按指标归并成时间轴。只看 `.item`,名字为空的跳过;按分类首次出现的顺序、
    /// 同分类按最近一次报告里的顺序排(和报告上读起来的顺序一致)。
    public static func metrics(from entries: [CheckupEntryValue]) -> [CheckupMetric] {
        var byKey: [String: [CheckupEntryValue]] = [:]
        for entry in entries where entry.kind == .item {
            let key = metricKey(entry.name)
            guard !key.isEmpty else { continue }
            byKey[key, default: []].append(entry)
        }
        let metrics = byKey.map { key, records -> CheckupMetric in
            let sorted = records.sorted { ($0.date, $0.sortIndex) < ($1.date, $1.sortIndex) }
            let latest = sorted.last!
            return CheckupMetric(key: key, name: latest.name, category: latest.category, records: sorted)
        }
        // 分类顺序:最近一份报告里的顺序优先,老报告才有的分类排在后面。
        let ordered = entries.sorted { ($1.date, $0.sortIndex) < ($0.date, $1.sortIndex) }
        var categoryOrder: [String: Int] = [:]
        for entry in ordered where categoryOrder[entry.category] == nil {
            categoryOrder[entry.category] = categoryOrder.count
        }
        return metrics.sorted {
            let left = categoryOrder[$0.category] ?? .max
            let right = categoryOrder[$1.category] ?? .max
            if left != right { return left < right }
            return ($0.latest?.sortIndex ?? 0) < ($1.latest?.sortIndex ?? 0)
        }
    }

    /// 一份报告里的条目按分类分组,分类按首次出现的顺序(不按字母重排),
    /// 综合建议不在其中。
    public static func grouped(_ entries: [CheckupEntryValue]) -> [(category: String, entries: [CheckupEntryValue])] {
        var order: [String] = []
        var groups: [String: [CheckupEntryValue]] = [:]
        for entry in entries.sorted(by: { $0.sortIndex < $1.sortIndex }) where entry.kind == .item {
            if groups[entry.category] == nil { order.append(entry.category) }
            groups[entry.category, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// 一份报告里的异常项数(按 `effectiveFlag`)。
    public static func abnormalCount(_ entries: [CheckupEntryValue]) -> Int {
        entries.filter { $0.kind == .item && ($0.effectiveFlag?.isAbnormal ?? false) }.count
    }

    /// 整理时交给 AI 的"已有指标名"(同一个人以往报告里的),让它沿用同样的写法。
    /// 去重、保持首次出现的顺序,最多 `limit` 个。
    public static func knownNames(_ entries: [CheckupEntryValue], limit: Int = 200) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for entry in entries.sorted(by: { ($1.date, $0.sortIndex) < ($0.date, $1.sortIndex) })
        where entry.kind == .item && !entry.name.isEmpty {
            if seen.insert(metricKey(entry.name)).inserted { names.append(entry.name) }
            if names.count >= limit { break }
        }
        return names
    }

    // MARK: - 文本

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    /// 喂给 AI 健康分析的体检摘要(**只给本人的**,调用方负责过滤)。最近一份报告的
    /// 异常项 + 综合建议,再加上有两次以上记录的数值指标的变化;控制在 `limit` 字内。
    /// 没有报告返回 nil。
    public static func promptSummary(
        reports: [CheckupReportValue], entries: [CheckupEntryValue], limit: Int = 1500
    ) -> String? {
        guard let latest = reports.max(by: { $0.date < $1.date }) else { return nil }
        var lines: [String] = []
        let latestEntries = entries.filter { $0.reportID == latest.id }
        lines.append("最近一次体检:\(dayString(latest.date))\(latest.title.isEmpty ? "" : " \(latest.title)")")
        let abnormal = latestEntries.filter { $0.kind == .item && ($0.effectiveFlag?.isAbnormal ?? false) }
        if abnormal.isEmpty {
            lines.append("异常项:无")
        } else {
            lines.append("异常项:")
            for entry in abnormal {
                var line = "- \(entry.name) \(entry.displayValue)"
                if !entry.referenceRange.isEmpty { line += "(参考 \(entry.referenceRange))" }
                if !entry.advice.isEmpty { line += ";报告建议:\(entry.advice)" }
                lines.append(line)
            }
        }
        if let advice = latestEntries.first(where: { $0.kind == .advice }), !advice.advice.isEmpty {
            lines.append("报告综合建议:\(advice.advice)")
        }
        let changes = metrics(from: entries).filter { $0.isNumeric && $0.points.count >= 2 }
        if !changes.isEmpty {
            lines.append("历次变化:")
            for metric in changes {
                let values = metric.points.suffix(4).map { "\(dayString($0.date)) \(format($0.value))" }
                lines.append("- \(metric.name):\(values.joined(separator: " → "))")
            }
        }
        let text = lines.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// 整份报告写成纯文字:进记忆条目的 `sourceText`(记忆搜索/问 AI 用),也是分享
    /// 时每份报告那一段。
    public static func reportText(_ report: CheckupReportValue, entries: [CheckupEntryValue]) -> String {
        var lines = ["\(report.title)(\(dayString(report.date)))"]
        if !report.institution.isEmpty { lines.append("体检机构:\(report.institution)") }
        for group in grouped(entries) {
            lines.append("")
            lines.append("【\(group.category.isEmpty ? "其他" : group.category)】")
            for entry in group.entries {
                var line = "\(entry.name):\(entry.displayValue)"
                if !entry.referenceRange.isEmpty { line += "(参考 \(entry.referenceRange))" }
                if let flag = entry.effectiveFlag, flag.isAbnormal { line += " [\(flagLabel(flag))]" }
                if !entry.conclusion.isEmpty, entry.conclusion != entry.displayValue {
                    line += " \(entry.conclusion)"
                }
                lines.append(line)
                if !entry.advice.isEmpty { lines.append("  建议:\(entry.advice)") }
            }
        }
        if let advice = entries.first(where: { $0.kind == .advice }), !advice.advice.isEmpty {
            lines.append("")
            lines.append("【综合建议】")
            lines.append(advice.advice)
        }
        return lines.joined(separator: "\n")
    }

    /// 分享一个人的档案:按时间从近到远把每份报告写出来。
    public static func shareText(
        profileName: String, reports: [CheckupReportValue], entries: [CheckupEntryValue]
    ) -> String {
        var parts = ["\(profileName) 的体检档案"]
        for report in reports.sorted(by: { $0.date > $1.date }) {
            parts.append(reportText(report, entries: entries.filter { $0.reportID == report.id }))
        }
        return parts.joined(separator: "\n\n————————\n\n")
    }

    /// 纯文字里用的标记名(prompt/分享都是中文,不跟应用语言走)。
    static func flagLabel(_ flag: CheckupFlag) -> String {
        switch flag {
        case .normal: return "正常"
        case .high: return "偏高"
        case .low: return "偏低"
        case .abnormal: return "异常"
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }
}
