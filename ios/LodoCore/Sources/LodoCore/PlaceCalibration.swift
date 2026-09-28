import Foundation

/// 重新选点时让 AI 从 OpenStreetMap 候选里挑最合理的那个(`PlaceCalibrationTests`)。
///
/// 为什么要 AI:Nominatim 给的同名候选常常有好几个(日本十几座「清水寺」、同名的
/// 连锁酒店、车站和同名商场),`OSMGeocode.pick` 只会按"离行程近 + 知名度"机械地挑,
/// 挑不出"这趟行程的第二天在京都,所以是京都那座""住的是酒店不是酒店旁边的车站"
/// 这类要看上下文的判断;也认不出所有候选都搜岔了的情况。
///
/// 做法:整趟旅行的地点和各自的候选**一次**交给模型(省请求、也让它看得到同一天的
/// 其他安排),模型对每一项回一个候选编号,或者 null 表示都不对。这里只负责拼给模型
/// 的清单、解析回复;发请求在 `DeepSeekClient.calibratePlaces`,落库在 app 层
/// `TravelStore.relocateAll`/`locate`。
public enum PlaceCalibration {
    /// 每个地点最多给模型看几个候选(标题和地点名两路搜到的合在一起)。
    public static let maxCandidates = 8

    /// 校准时拿去搜的词:**标题和地点名都搜**,标题在前。只搜地点名(原来的做法)时
    /// 「浅草寺」填的地点是「浅草」,候选就只剩浅草这个区和几个浅草站,景点本身根本
    /// 不在里面,AI 再会挑也挑不出来。标题里「(还没定时间)」这类括号备注先去掉;
    /// 住宿的标题按 `TravelDestination.lodgingQuery` 去掉「住/一带」。
    public static func queries(title: String, place: String, isLodging: Bool) -> [String] {
        var cleanedTitle = title.replacingOccurrences(
            of: #"[（(【\[][^）)】\]]*[）)】\]]"#, with: "", options: .regularExpression)
        if isLodging { cleanedTitle = TravelDestination.lodgingQuery(cleanedTitle) }
        var result: [String] = []
        for query in [cleanedTitle, place].map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            where !query.isEmpty && !result.contains(query) {
            result.append(query)
        }
        return result
    }

    /// 把几路搜到的候选合起来:按出现顺序,同一个 OSM 对象、或坐标约 100 米内的只留
    /// 第一个,最多 `maxCandidates` 个。每一路自己最多先取一半,免得第一路把名额占满、
    /// 另一路(比如地点名搜到的那个区)一条都进不来。
    public static func merge(_ lists: [[OSMGeocode.Place]]) -> [OSMGeocode.Place] {
        let perList = lists.count > 1 ? max(1, maxCandidates / lists.count) : maxCandidates
        var seenIDs = Set<String>()
        var seenSpots = Set<String>()
        var result: [OSMGeocode.Place] = []
        func add(_ place: OSMGeocode.Place) -> Bool {
            let spot = String(format: "%.3f,%.3f", place.latitude, place.longitude)
            guard result.count < maxCandidates, !seenIDs.contains(place.id),
                  !seenSpots.contains(spot) else { return false }
            seenIDs.insert(place.id)
            seenSpots.insert(spot)
            result.append(place)
            return true
        }
        var leftovers: [OSMGeocode.Place] = []
        for list in lists {
            var taken = 0
            for place in list {
                if taken < perList, add(place) { taken += 1 } else { leftovers.append(place) }
            }
        }
        for place in leftovers { _ = add(place) }
        return result
    }

    public struct Candidate: Equatable, Sendable {
        public let latitude: Double
        public let longitude: Double
        public let name: String
        /// 完整地址(Nominatim 的 display_name)。
        public let address: String
        /// Nominatim 的 addresstype(tourism / railway / amenity …)。
        public let type: String
        public let importance: Double
        /// 离这趟旅行目的地的距离(公里);目的地没有坐标时为 nil。
        public let distanceKm: Double?

        public init(latitude: Double, longitude: Double, name: String, address: String,
                    type: String, importance: Double, distanceKm: Double?) {
            self.latitude = latitude
            self.longitude = longitude
            self.name = name
            self.address = address
            self.type = type
            self.importance = importance
            self.distanceKm = distanceKm
        }
    }

    public struct Item: Equatable, Sendable {
        public let id: UUID
        public let title: String
        /// 用户填的地点名(可空)。
        public let place: String
        /// 「住宿」「地点」这类给模型看的类型名。
        public let kind: String
        /// 「第 2 天 10:00」这类时间;没排期为 nil。
        public let when: String?
        public let note: String
        public let candidates: [Candidate]

        public init(id: UUID, title: String, place: String, kind: String, when: String?,
                    note: String, candidates: [Candidate]) {
            self.id = id
            self.title = title
            self.place = place
            self.kind = kind
            self.when = when
            self.note = note
            self.candidates = candidates
        }
    }

    public enum Choice: Equatable, Sendable {
        /// 选中的候选下标(0 起,对应 `Item.candidates`)。
        case pick(Int)
        /// 模型认为所有候选都不对。
        case none
    }

    /// 给模型看的清单。候选编号从 1 开始(模型对 1 起的编号更稳),解析时换回 0 起。
    public static func prompt(trip: String, items: [Item]) -> String {
        var lines = [trip, "", "要定位的地点(同一天的地点一般离得不远):"]
        for item in items {
            var head = "[id:\(item.id.uuidString)] \(item.kind)「\(item.title)」"
            if !item.place.isEmpty, item.place != item.title { head += "(地点:\(item.place))" }
            if let when = item.when { head += " · \(when)" }
            let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty { head += " · 备注:\(String(note.prefix(60)))" }
            lines.append(head)
            for (index, candidate) in item.candidates.enumerated() {
                var line = "  \(index + 1). \(candidate.name) — \(candidate.address)"
                if !candidate.type.isEmpty { line += " · 类型 \(candidate.type)" }
                line += String(format: " · 知名度 %.2f", candidate.importance)
                if let km = candidate.distanceKm { line += String(format: " · 距目的地 %.0f km", km) }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 解析 `{"choices": [{"id": "…", "pick": 2}]}`。`pick` 为 null / 0 = 都不对;
    /// 超出候选范围、id 不在清单里的一律忽略(调用方对没有结论的项退回自动挑选)。
    /// id 认 `[id:` 前缀和大小写差异(模型抄 id 时常带上方括号)。
    public static func parse(_ payload: [String: Any], items: [Item]) -> [UUID: Choice] {
        guard let choices = payload["choices"] as? [[String: Any]] else { return [:] }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [UUID: Choice] = [:]
        for choice in choices {
            guard let raw = choice["id"] as? String,
                  let id = UUID(uuidString: cleanID(raw)),
                  let item = byID[id], result[id] == nil else { continue }
            let pick: Int?
            switch choice["pick"] {
            case let number as Int: pick = number
            case let number as Double: pick = Int(number)
            case let text as String: pick = Int(text.trimmingCharacters(in: .whitespaces))
            default: pick = nil
            }
            guard let pick, pick != 0 else {
                result[id] = Choice.none
                continue
            }
            guard (1...item.candidates.count).contains(pick) else { continue }
            result[id] = .pick(pick - 1)
        }
        return result
    }

    private static func cleanID(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") { text.removeFirst() }
        if text.hasSuffix("]") { text.removeLast() }
        if text.lowercased().hasPrefix("id:") { text = String(text.dropFirst(3)) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
