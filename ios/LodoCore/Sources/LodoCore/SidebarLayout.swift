import Foundation

public struct SidebarItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var isVisible: Bool

    public init(id: String, isVisible: Bool = true) {
        self.id = id
        self.isVisible = isVisible
    }
}

/// 侧栏页面的顺序与可见性。只存稳定字符串,页面类型和默认顺序由 App 传入。
public struct SidebarLayout: Equatable, Sendable {
    public var items: [SidebarItem]

    public init(items: [SidebarItem]) {
        self.items = items
    }

    /// 解不开时用默认布局;未知标识跳过,重复只留第一条,缺少的项按默认顺序补末尾。
    /// initiallyHidden 只用于未存过的项,兼容旧版单独保存的可见性设置。
    public static func decode(_ string: String?, defaultOrder: [String],
                              initiallyHidden: Set<String> = []) -> SidebarLayout {
        var defaultsSeen = Set<String>()
        let defaults = defaultOrder.filter { defaultsSeen.insert($0).inserted }
        let known = Set(defaults)
        let raw = string?.data(using: .utf8).flatMap {
            try? JSONDecoder().decode([RawItem].self, from: $0)
        } ?? []
        var seen = Set<String>()
        var items: [SidebarItem] = []
        for entry in raw {
            guard known.contains(entry.id), seen.insert(entry.id).inserted else { continue }
            items.append(SidebarItem(id: entry.id, isVisible: entry.isVisible ?? true))
        }
        for id in defaults where !seen.contains(id) {
            items.append(SidebarItem(id: id, isVisible: !initiallyHidden.contains(id)))
        }
        return SidebarLayout(items: items)
    }

    public func encoded() -> String {
        let raw = items.map { RawItem(id: $0.id, isVisible: $0.isVisible) }
        guard let data = try? JSONEncoder().encode(raw) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private struct RawItem: Codable {
        var id: String
        var isVisible: Bool?
    }

    /// 按用户顺序返回可见项,允许全部隐藏。
    public var visibleIDs: [String] {
        items.filter(\.isVisible).map(\.id)
    }

    /// 移到目标所在位置,语义同 OverviewLayout.move(_:to:)。
    public mutating func move(_ id: String, to target: String) {
        guard id != target,
              let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    /// 系统 List.onMove 的偏移量语义,不依赖 SwiftUI。
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard (0...items.count).contains(destination),
              source.allSatisfy({ items.indices.contains($0) }) else { return }
        let moving = source.sorted().map { items[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { items.remove(at: index) }
        items.insert(contentsOf: moving, at: destination - before)
    }

    public mutating func setVisible(_ visible: Bool, for id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isVisible = visible
    }
}
