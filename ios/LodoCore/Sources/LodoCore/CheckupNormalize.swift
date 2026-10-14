import Foundation

/// 一组"其实是同一项指标"的写法,以及归并后统一用的名字。
public struct CheckupNameGroup: Equatable, Sendable, Identifiable {
    /// 归并后的名字。
    public var canonical: String
    /// 被并进来的原写法(不含和 canonical 同键的那个),按首次出现的顺序。
    public var variants: [String]
    /// 这一组一共涉及几条记录(含本来就叫 canonical 的)。
    public var recordCount: Int

    public var id: String { CheckupPlan.metricKey(canonical) }

    public init(canonical: String, variants: [String], recordCount: Int = 0) {
        self.canonical = canonical
        self.variants = variants
        self.recordCount = recordCount
    }
}

/// 一次「重新匹配检查项」要做的改动。先算出来给用户看,点了「应用」才落库。
public struct CheckupNormalizationPlan: Equatable, Sendable {
    /// 合并的写法(只列真的会改名的组)。
    public var groups: [CheckupNameGroup]
    /// 条目 id → 改动后的整条快照(改名、以及去重时从重复项补上的空字段)。
    public var updates: [UUID: CheckupEntryValue]
    /// 要删掉的重复条目。
    public var removals: [CheckupEntryValue]

    public init(groups: [CheckupNameGroup] = [], updates: [UUID: CheckupEntryValue] = [:],
                removals: [CheckupEntryValue] = []) {
        self.groups = groups
        self.updates = updates
        self.removals = removals
    }

    public var isEmpty: Bool { updates.isEmpty && removals.isEmpty }
}

/// 「重新匹配检查项」:把历次报告里同一项指标的不同写法(中英文、缩写、全称、错字)
/// 归成一个名字,再把同一份报告里因此重复出来的记录去掉。
///
/// 分两步:哪些写法是同一项,由 AI(`DeepSeekClient.matchCheckupNames`)按编号清单
/// 判断,再叠上本地一条稳妥的规则(括号里的英文缩写相同,如 "谷丙转氨酶(ALT)" 和
/// "ALT");怎么改、删哪条是这里的纯函数算的,单测 `CheckupNormalizeTests`。
public enum CheckupNormalizer {

    /// 一个写法在档案里的样子(喂给 AI 的清单一行)。
    public struct NameInfo: Equatable, Sendable {
        public var name: String
        public var category: String
        public var unit: String
        public var sample: String
        public var count: Int
    }

    /// 档案里出现过的全部写法:按 `metricKey` 去重,保持最近报告里的顺序。
    public static func catalog(_ entries: [CheckupEntryValue], limit: Int = 300) -> [NameInfo] {
        var order: [String] = []
        var infos: [String: NameInfo] = [:]
        let sorted = entries.sorted { ($1.date, $0.sortIndex) < ($0.date, $1.sortIndex) }
        for entry in sorted where entry.kind == .item {
            let key = CheckupPlan.metricKey(entry.name)
            guard !key.isEmpty else { continue }
            if var info = infos[key] {
                info.count += 1
                if info.unit.isEmpty { info.unit = entry.unit }
                infos[key] = info
            } else {
                order.append(key)
                infos[key] = NameInfo(name: entry.name, category: entry.category, unit: entry.unit,
                                      sample: entry.displayValue, count: 1)
            }
        }
        return order.prefix(limit).compactMap { infos[$0] }
    }

    /// 清单写成编号文字:"1|谷丙转氨酶(ALT)|肝功能|U/L|38"。编号从 1 起。
    public static func promptLines(_ catalog: [NameInfo]) -> String {
        catalog.enumerated().map { index, info in
            let sample = String(info.sample.replacingOccurrences(of: "\n", with: " ").prefix(30))
            return "\(index + 1)|\(info.name)|\(info.category)|\(info.unit)|\(sample)"
        }.joined(separator: "\n")
    }

    /// 解析 AI 的分组:`{"groups": [{"name": "标准名", "ids": [1, 3]}]}`。编号越界的丢掉,
    /// 一个写法只认它第一次出现的那组,不到两个写法的组丢掉;name 为空时用组里第一个写法。
    public static func parseGroups(_ payload: [String: Any], catalog: [NameInfo]) -> [CheckupNameGroup] {
        guard let raw = payload["groups"] as? [[String: Any]] else { return [] }
        var used = Set<Int>()
        var groups: [CheckupNameGroup] = []
        for group in raw {
            let ids: [Int] = ((group["ids"] as? [Any]) ?? []).compactMap { value in
                if let number = value as? Int { return number }
                if let number = value as? Double { return Int(number) }
                if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
                return nil
            }
            var members: [Int] = []
            for id in ids where id >= 1 && id <= catalog.count && !used.contains(id) && !members.contains(id) {
                members.append(id)
            }
            guard members.count >= 2 else { continue }
            used.formUnion(members)
            let names = members.map { catalog[$0 - 1].name }
            let given = ((group["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            groups.append(CheckupNameGroup(canonical: given.isEmpty ? names[0] : given, variants: names))
        }
        return groups
    }

    /// 本地规则:名字里括号中的英文缩写(或整个名字就是英文缩写)相同的算同一项,
    /// 如 "谷丙转氨酶(ALT)"、"丙氨酸氨基转移酶(ALT)"、"ALT"。只认 2–10 位的字母数字
    /// 缩写,"血压" 这类没有缩写的不参与。统一名优先挑带中文的、记录多的那个写法。
    public static func localGroups(_ catalog: [NameInfo]) -> [CheckupNameGroup] {
        var order: [String] = []
        var byAbbr: [String: [NameInfo]] = [:]
        for info in catalog {
            guard let abbr = abbreviation(of: info.name) else { continue }
            if byAbbr[abbr] == nil { order.append(abbr) }
            byAbbr[abbr, default: []].append(info)
        }
        return order.compactMap { abbr in
            guard let members = byAbbr[abbr], members.count >= 2 else { return nil }
            let canonical = members.max { preference($0) < preference($1) }!.name
            return CheckupNameGroup(canonical: canonical, variants: members.map(\.name))
        }
    }

    /// AI 的分组和本地分组合起来:有交集的组并成一组(并查集),统一名以 AI 给的为准。
    public static func merge(_ ai: [CheckupNameGroup], _ local: [CheckupNameGroup]) -> [CheckupNameGroup] {
        var merged: [(canonical: String, keys: [String], names: [String])] = []
        for group in ai + local {
            let names = group.variants
            let keys = Set(names.map(CheckupPlan.metricKey))
            let hits = merged.indices.filter { !keys.isDisjoint(with: merged[$0].keys) }
            var combined = (canonical: group.canonical, keys: [String](), names: [String]())
            if let first = hits.first {
                // 先到的组(AI 在前)决定统一名。
                combined.canonical = merged[first].canonical
            }
            for index in hits {
                combined.keys += merged[index].keys
                combined.names += merged[index].names
            }
            for name in names where !combined.keys.contains(CheckupPlan.metricKey(name)) {
                combined.keys.append(CheckupPlan.metricKey(name))
                combined.names.append(name)
            }
            for index in hits.reversed() { merged.remove(at: index) }
            merged.insert(combined, at: hits.first ?? merged.count)
        }
        return merged.map { CheckupNameGroup(canonical: $0.canonical, variants: $0.names) }
    }

    /// 算出要改的:按分组改名,再在**同一份报告**里按新名字去重。
    ///
    /// 去重只删"确实重复"的:两条结果相同,或者其中一条没有结果。同一份报告里同名但
    /// 结果不同的两条(左右眼、两次测量,或者 AI 归错了组)都留着——删错了就找不回来。
    /// 留下的那条按信息多少挑(有结果、单位、参考范围、标记、结论、建议各算一分,
    /// 同分取报告里靠前的),它空着的字段从被删的那条补上。
    public static func plan(_ entries: [CheckupEntryValue], groups: [CheckupNameGroup]) -> CheckupNormalizationPlan {
        var canonicalByKey: [String: String] = [:]
        for group in groups {
            for name in group.variants + [group.canonical] {
                canonicalByKey[CheckupPlan.metricKey(name)] = group.canonical
            }
        }

        var working: [UUID: CheckupEntryValue] = [:]
        var changed = Set<UUID>()
        for entry in entries {
            var entry = entry
            if entry.kind == .item, let canonical = canonicalByKey[CheckupPlan.metricKey(entry.name)],
               canonical != entry.name {
                entry.name = canonical
                changed.insert(entry.id)
            }
            working[entry.id] = entry
        }

        var removals: [CheckupEntryValue] = []
        let items = working.values.filter { $0.kind == .item && !CheckupPlan.metricKey($0.name).isEmpty }
        let byReportAndKey = Dictionary(grouping: items) { "\($0.reportID.uuidString)|\(CheckupPlan.metricKey($0.name))" }
        for key in byReportAndKey.keys.sorted() {
            guard let records = byReportAndKey[key], records.count >= 2 else { continue }
            var pool = records.sorted { (score($1), $0.sortIndex) < (score($0), $1.sortIndex) }
            while !pool.isEmpty {
                var keeper = pool.removeFirst()
                var rest: [CheckupEntryValue] = []
                for other in pool {
                    if sameResult(keeper, other) {
                        if fill(&keeper, from: other) { changed.insert(keeper.id) }
                        removals.append(entries.first { $0.id == other.id } ?? other)
                    } else {
                        rest.append(other)
                    }
                }
                working[keeper.id] = keeper
                pool = rest
            }
        }

        let removedIDs = Set(removals.map(\.id))
        var updates: [UUID: CheckupEntryValue] = [:]
        for id in changed where !removedIDs.contains(id) {
            if let entry = working[id] { updates[id] = entry }
        }

        // 只列真的有记录改名的组;记录数按改动后的名字数。
        var shown: [CheckupNameGroup] = []
        for group in groups {
            let keys = Set(group.variants.map(CheckupPlan.metricKey))
            let renamed = entries.filter {
                $0.kind == .item && keys.contains(CheckupPlan.metricKey($0.name)) && $0.name != group.canonical
            }
            guard !renamed.isEmpty else { continue }
            let canonicalKey = CheckupPlan.metricKey(group.canonical)
            var variants: [String] = []
            for name in group.variants where name != group.canonical && !variants.contains(name) {
                if entries.contains(where: { $0.kind == .item && $0.name == name }) { variants.append(name) }
            }
            let total = entries.filter {
                $0.kind == .item && (keys.contains(CheckupPlan.metricKey($0.name))
                                     || CheckupPlan.metricKey($0.name) == canonicalKey)
            }.count
            shown.append(CheckupNameGroup(canonical: group.canonical, variants: variants, recordCount: total))
        }
        removals.sort { ($0.date, $0.sortIndex) < ($1.date, $1.sortIndex) }
        return CheckupNormalizationPlan(groups: shown, updates: updates, removals: removals)
    }

    // MARK: - 内部

    /// 括号里的缩写,或整个名字就是缩写时的那个缩写(小写)。
    static func abbreviation(of name: String) -> String? {
        let normalized = name.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
        var candidate = normalized
        if let open = normalized.lastIndex(of: "("), let close = normalized.lastIndex(of: ")"), open < close {
            candidate = String(normalized[normalized.index(after: open)..<close])
        }
        let trimmed = candidate.filter { !$0.isWhitespace }
        guard (2...10).contains(trimmed.count),
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              trimmed.contains(where: \.isLetter) else { return nil }
        return trimmed.lowercased()
    }

    private static func preference(_ info: NameInfo) -> (Int, Int, Int) {
        let hasChinese = info.name.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return (hasChinese ? 1 : 0, info.count, info.name.count)
    }

    private static func score(_ entry: CheckupEntryValue) -> Int {
        [entry.value, entry.unit, entry.referenceRange, entry.conclusion, entry.advice]
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            + (entry.flag == nil ? 0 : 1)
    }

    private static func resultKey(_ entry: CheckupEntryValue) -> String {
        let value = entry.value.isEmpty ? entry.conclusion : entry.value
        return value.filter { !$0.isWhitespace }.lowercased()
    }

    private static func sameResult(_ a: CheckupEntryValue, _ b: CheckupEntryValue) -> Bool {
        let left = resultKey(a), right = resultKey(b)
        if left.isEmpty || right.isEmpty { return true }
        if left == right { return true }
        // 数值相同、写法不同("5.60" 和 "5.6"),单位一致或缺一边时也算同一条。
        if let x = CheckupPlan.numericValue(a.value), let y = CheckupPlan.numericValue(b.value), x == y {
            let unitA = a.unit.lowercased(), unitB = b.unit.lowercased()
            return unitA.isEmpty || unitB.isEmpty || unitA == unitB
        }
        return false
    }

    /// keeper 空着的字段从 other 补;补了任何一项返回 true。
    private static func fill(_ keeper: inout CheckupEntryValue, from other: CheckupEntryValue) -> Bool {
        var changed = false
        func take(_ path: WritableKeyPath<CheckupEntryValue, String>) {
            if keeper[keyPath: path].isEmpty, !other[keyPath: path].isEmpty {
                keeper[keyPath: path] = other[keyPath: path]
                changed = true
            }
        }
        take(\.value)
        take(\.unit)
        take(\.referenceRange)
        take(\.conclusion)
        take(\.advice)
        take(\.category)
        if keeper.flag == nil, let flag = other.flag {
            keeper.flag = flag
            changed = true
        }
        return changed
    }
}
