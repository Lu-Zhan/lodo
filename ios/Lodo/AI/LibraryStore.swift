import Foundation
import SwiftData
import LodoCore

/// AI 助手对「资产」「新闻订阅」的写操作(`AssetOp` / `FeedOp`)的执行与撤销。
/// 和 `CountdownStore` 同一个取舍:直接执行,结果卡片带撤销;撤销靠
/// `LibraryEditRecord` 里记下的新建 uuid 和改之前的整份快照。
@MainActor
enum LibraryStore {
    // MARK: - prompt 里的清单

    static func assetEntries(in context: ModelContext) -> [AssetEntry] {
        let items = ((try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []).filter(\.isAsset)
        return items.map { item in
            AssetEntry(id: item.uuid, title: item.title,
                       category: AssetCategory.category(of: item.tags, reserved: MemoryItem.reservedTagNames),
                       value: item.assetValue, currency: item.assetCurrencyOrDefault,
                       liability: item.assetLiability, interestRate: item.assetInterestRate,
                       updatedAt: item.assetUpdatedAtOrCreated)
        }
    }

    static func feedEntries(in context: ModelContext) -> [FeedEntry] {
        NewsStore.feeds(in: context).map {
            FeedEntry(id: $0.uuid, title: $0.title, url: $0.url, kind: $0.kind, enabled: $0.enabled)
        }
    }

    // MARK: - 执行

    static func apply(assets assetOps: [AssetOp], feeds feedOps: [FeedOp],
                      context: ModelContext) async -> LibraryEditRecord {
        var record = LibraryEditRecord()
        for op in assetOps { applyAsset(op, into: &record, context: context) }
        for op in feedOps { await applyFeed(op, into: &record, context: context) }
        try? context.save()
        return record
    }

    private static func applyAsset(_ op: AssetOp, into record: inout LibraryEditRecord,
                                   context: ModelContext) {
        switch op {
        case .create(let draft):
            let category = draft.category == "其他" ? "" : draft.category
            guard let item = MemoryPipeline.saveAsset(
                title: draft.title, value: draft.value, currency: draft.currency,
                liability: draft.liability, interestRate: draft.interestRate,
                category: category, note: draft.note, context: context) else {
                record.skipped.append("资产名称为空")
                return
            }
            record.lines.append(line(for: item, created: true))
        case .update(let id, let change):
            guard let item = memoryItem(id, context: context), item.isAsset else {
                record.skipped.append("找不到要修改的资产")
                return
            }
            record.assetsBefore.append(item.backup)
            if let title = change.title { item.title = title }
            if let category = change.category { setCategory(category, of: item) }
            if let value = change.value { item.assetValue = value }
            if let currency = change.currency { item.assetCurrency = currency }
            if let liability = change.liability { item.assetLiability = liability }
            if let rate = change.interestRate { item.assetInterestRate = rate }
            if let note = change.note { item.summary = note }
            if item.assetCurrency == nil, item.assetValue != nil || item.assetLiability != nil {
                item.assetCurrency = "CNY"
            }
            // 同资产页的编辑表单:保存一次就算核对过一次。
            item.assetUpdatedAt = Date()
            MemoryPipeline.finishStructuredSave(item, context: context)
            record.lines.append(line(for: item, created: false))
        }
    }

    /// 换分类:分类就是紧跟在保留标签后面的那个标签(同 `AssetEditView.save`)。
    private static func setCategory(_ category: String, of item: MemoryItem) {
        let old = AssetCategory.category(of: item.tags, reserved: MemoryItem.reservedTagNames)
        var tags = item.tags.filter { $0 != old }
        if category != "其他", !tags.contains(category) {
            let index = tags.lastIndex { MemoryItem.reservedTagNames.contains($0) }.map { $0 + 1 } ?? 0
            tags.insert(category, at: index)
        }
        item.tags = tags
    }

    private static func line(for item: MemoryItem, created: Bool) -> LibraryEditRecord.Line {
        var parts: [String] = []
        if let value = item.assetValue {
            parts.append(AssetFormat.currency(value, code: item.assetCurrencyOrDefault))
        }
        if let liability = item.assetLiability {
            parts.append("负债 " + AssetFormat.currency(liability, code: item.assetCurrencyOrDefault))
        }
        parts.append(AssetCategory.category(of: item.tags, reserved: MemoryItem.reservedTagNames))
        return .init(domain: .asset, created: created, uuid: item.uuid, title: item.title,
                     detail: parts.joined(separator: " · "))
    }

    private static func applyFeed(_ op: FeedOp, into record: inout LibraryEditRecord,
                                  context: ModelContext) async {
        switch op {
        case .subscribe(let draft):
            let existing = NewsStore.feeds(in: context)
            // 只给了名字:先看是不是已经订过,再在推荐源里模糊找。
            var address = draft.url
            var kind = draft.kind
            if address == nil, let name = draft.name {
                if let same = FeedMatch.best(name, in: existing, title: \.title, url: \.url) {
                    record.skipped.append("「\(same.title)」已经订阅过了")
                    return
                }
                guard let preset = FeedMatch.best(name, in: NewsStore.presets,
                                                  title: \.title, url: \.url) else {
                    record.skipped.append("没找到「\(name)」的订阅地址,发个链接给我")
                    return
                }
                address = preset.url
                kind = preset.kind
            }
            guard let address else { return }
            do {
                let feed = try await NewsStore.subscribe(address, kind: kind, context: context)
                record.lines.append(.init(domain: .feed, created: true, uuid: feed.uuid,
                                          title: feed.title, detail: feed.url))
            } catch let error as NewsStore.SubscribeError {
                if case .alreadySubscribed(let title) = error {
                    record.skipped.append("「\(title)」已经订阅过了")
                } else {
                    record.skipped.append("\(draft.label):\(error.localizedDescription)")
                }
            } catch {
                record.skipped.append("\(draft.label):\(error.localizedDescription)")
            }
        case .update(let id, let change):
            guard let feed = NewsStore.feeds(in: context).first(where: { $0.uuid == id }) else {
                record.skipped.append("找不到要修改的订阅")
                return
            }
            record.feedsBefore.append(feed.backup)
            if let title = change.title { NewsStore.rename(feed, to: title, context: context) }
            if let kind = change.kind { feed.kindRaw = kind.rawValue }
            if let enabled = change.enabled { feed.enabled = enabled }
            var detail = feed.url
            if !feed.enabled { detail = "已停用 · " + detail }
            record.lines.append(.init(domain: .feed, created: false, uuid: feed.uuid,
                                      title: feed.title, detail: detail))
        }
    }

    // MARK: - 撤销

    static func revert(_ record: LibraryEditRecord, context: ModelContext) -> LibraryEditRecord {
        for line in record.lines where line.created {
            switch line.domain {
            case .asset:
                if let item = memoryItem(line.uuid, context: context) {
                    MemoryPipeline.delete(item, context: context)
                }
            case .feed:
                if let feed = NewsStore.feeds(in: context).first(where: { $0.uuid == line.uuid }) {
                    NewsStore.delete(feed, context: context)
                }
            }
        }
        for before in record.assetsBefore {
            guard let item = memoryItem(before.uuid, context: context) else { continue }
            before.apply(to: item)
            MemoryPipeline.finishStructuredSave(item, context: context)
        }
        for before in record.feedsBefore {
            guard let feed = NewsStore.feeds(in: context).first(where: { $0.uuid == before.uuid }) else { continue }
            NewsStore.rename(feed, to: before.title, context: context)
            before.apply(to: feed)
        }
        try? context.save()
        var reverted = record
        reverted.reverted = true
        return reverted
    }

    private static func memoryItem(_ uuid: UUID, context: ModelContext) -> MemoryItem? {
        var descriptor = FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.uuid == uuid })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
