import Foundation

/// 一趟旅行的同行人(旅行详情面板「人员」)。两种来源:
/// - **从人脉链接**:`contactUUID` 指向打了「人脉」标签的那条记忆条目,名字随人脉走
///   (人脉里改了名,这里跟着变);`name` 只是链接那一刻的名字,人脉被删了、或者在
///   共享旅行的另一台设备上(别人的人脉库里没有这个人)时拿它兜底。
/// - **单独新建**:`contactUUID` 为 nil,只有名字和一句备注——一起去的同事不一定
///   值得进人脉库。
///
/// 存成 JSON 串挂在 `TravelTrip.travelersData` 上(同 `extraDestinations`):一趟旅行
/// 就几个人,不值得为它另建一张表,还能直接跟着旅行共享和备份走。
public struct TripTraveler: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var contactUUID: UUID?
    public var name: String
    public var note: String

    public init(id: UUID = UUID(), contactUUID: UUID? = nil, name: String, note: String = "") {
        self.id = id
        self.contactUUID = contactUUID
        self.name = name
        self.note = note
    }

    public var isLinkedContact: Bool { contactUUID != nil }

    /// 名字空着的不存(单独新建时只点了保存)。
    public static func encode(_ travelers: [TripTraveler]) -> String {
        let kept = travelers.compactMap { traveler -> TripTraveler? in
            var t = traveler
            t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
            t.note = t.note.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.name.isEmpty && t.contactUUID == nil ? nil : t
        }
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(kept) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 解码失败按没有处理(同 `TripDestination.decode`)。
    public static func decode(_ text: String) -> [TripTraveler] {
        guard !text.isEmpty,
              let list = try? JSONDecoder().decode([TripTraveler].self, from: Data(text.utf8))
        else { return [] }
        return list
    }

    /// 把几位人脉加进同行人:已经链接过的跳过,顺序保持选择的顺序。
    public static func linking(_ contacts: [(uuid: UUID, name: String)],
                               into travelers: [TripTraveler]) -> [TripTraveler] {
        var result = travelers
        var linked = Set(travelers.compactMap(\.contactUUID))
        for contact in contacts where linked.insert(contact.uuid).inserted {
            result.append(TripTraveler(contactUUID: contact.uuid, name: contact.name))
        }
        return result
    }
}

extension TravelTrip {
    /// 同行人,读写走 `travelersData`。
    public var travelers: [TripTraveler] {
        get { TripTraveler.decode(travelersData) }
        set { travelersData = TripTraveler.encode(newValue) }
    }
}
