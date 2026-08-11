import Foundation
import SwiftData
import LodoCore

/// 记忆标签的应用层操作:标签全集 = 用户创建的 MemoryTag ∪ 条目里出现过的标签。
@MainActor
enum MemoryTags {

    /// 全部标签及使用条数,按使用次数降序、同次数按名称升序。
    static func entries(in context: ModelContext) -> [(name: String, count: Int)] {
        let created = (try? context.fetch(FetchDescriptor<MemoryTag>())) ?? []
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        var counts: [String: Int] = [:]
        for name in created.map(\.name) where !name.isEmpty {
            counts[name] = counts[name] ?? 0
        }
        for name in items.flatMap(\.tags) where !name.isEmpty {
            counts[name, default: 0] += 1
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, count: $0.value) }
    }

    static func all(in context: ModelContext) -> [String] {
        entries(in: context).map(\.name)
    }

    /// 主动创建标签(去重:全集里已有同名标签则不重复建)。不允许创建和
    /// 保留标签同名的标签行——即使当下没有条目使用它,留着也容易被误认成
    /// 真的"资产"/"人脉"/"AI记录"入口。
    static func create(_ name: String, context: ModelContext) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !MemoryItem.reservedTagNames.contains(trimmed),
              !all(in: context).contains(trimmed) else { return }
        context.insert(MemoryTag(name: trimmed))
        try? context.save()
    }

    /// 改名:同步改所有条目里的这个标签;用户创建的标签行一并改名。保留标签
    /// 本身不能被改名(会让 isAsset/isContact/isAutoRecorded 判定失效),
    /// 也不能把一个普通标签改成和保留标签同名(会让一批不相关的条目突然被
    /// 当成资产/人脉/AI记录对待)——这两条不能只靠 UI 层不展示保留标签来
    /// 保证,调用方之后新增入口也不会漏掉。
    static func rename(_ old: String, to new: String, context: ModelContext) {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != old,
              !MemoryItem.reservedTagNames.contains(old),
              !MemoryItem.reservedTagNames.contains(trimmed) else { return }
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        for item in items where item.tags.contains(old) {
            var tags = item.tags.filter { $0 != old }
            if !tags.contains(trimmed) { tags.append(trimmed) }
            item.tags = tags
        }
        let created = (try? context.fetch(FetchDescriptor<MemoryTag>())) ?? []
        for tag in created where tag.name == old { tag.name = trimmed }
        try? context.save()
    }

    /// 删除:从所有条目里摘掉这个标签;用户创建的标签行一并删除。条目本身不动。
    /// 保留标签不能被删除,理由同 rename。
    static func delete(_ name: String, context: ModelContext) {
        guard !MemoryItem.reservedTagNames.contains(name) else { return }
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        for item in items where item.tags.contains(name) {
            item.tags = item.tags.filter { $0 != name }
        }
        let created = (try? context.fetch(FetchDescriptor<MemoryTag>())) ?? []
        for tag in created where tag.name == name { context.delete(tag) }
        try? context.save()
    }

    /// 单个条目上添/摘标签(详情页点选)。保留标签不走这个通用入口——
    /// 资产/人脉的字段编辑、auto_memorize 的落库各自直接操作 item.tags,
    /// 不该被这里的通用增删逻辑误伤。
    static func toggle(_ name: String, on item: MemoryItem, context: ModelContext) {
        guard !MemoryItem.reservedTagNames.contains(name) else { return }
        if item.tags.contains(name) {
            item.tags = item.tags.filter { $0 != name }
        } else {
            item.tags = item.tags + [name]
        }
        try? context.save()
    }
}
