import Foundation
import SwiftData
import CoreSpotlight
import UniformTypeIdentifiers
import LodoCore

/// 把任务、倒数日、记忆、人脉、旅行、菜单(资产默认不进)写进系统搜索(Spotlight)。
/// 哪几类能搜到在设置里选(`SpotlightCategory`,存 `AppSettings.spotlightCategoriesKey`)。
///
/// 和共享同步同一个思路:**不逐处挂钩子**,监听 `ModelContext.didSave`,合并 3 秒后整类重建
/// (先删整个 domain 再写)。每类按内容算一个指纹,和上次写进去的一样就跳过——AI 对话这类
/// 和索引无关的保存不会触发重建。健康类数据(体检、用药、经期、健康资料)一律不进索引。
/// 点搜索结果进来:`CSSearchableItemActionType` 的 NSUserActivity,由外壳 `openSpotlightItem` 处理。
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()

    private var container: ModelContainer?
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    /// 每类上次写进索引的内容指纹(只在进程内记;重启后第一次会整类重写一遍)。
    private var fingerprints: [SpotlightCategory: Int] = [:]

    /// 每类最多写多少条(记忆库可能很大,Spotlight 只要最近的那些)。
    private static let limit = 1500

    static var enabledCategories: Set<SpotlightCategory> {
        let raw = UserDefaults.standard.string(forKey: AppSettings.spotlightCategoriesKey)
        // 设置页没动过时 @AppStorage 不写值;写过 "default" 的同样当没设过。
        return SpotlightCategory.decode(raw == SettingsView.spotlightUnset ? nil : raw)
    }

    func configure(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        observer = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SpotlightIndexer.shared.schedule() }
        }
        schedule(delay: .seconds(2))
    }

    /// 合并一阵子里的多次保存。
    func schedule(delay: Duration = .seconds(3)) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await reindex()
        }
    }

    /// 设置里改了开关:关掉的类别立刻从索引里删掉,打开的立刻写。
    func settingsChanged() {
        fingerprints = [:]
        schedule(delay: .zero)
    }

    private func reindex() async {
        guard let context = container?.mainContext else { return }
        let index = CSSearchableIndex.default()
        let enabled = Self.enabledCategories
        for category in SpotlightCategory.allCases {
            guard enabled.contains(category) else {
                if fingerprints[category] != 0 {
                    try? await index.deleteSearchableItems(withDomainIdentifiers: [category.domain])
                    fingerprints[category] = 0
                }
                continue
            }
            let items = Self.items(for: category, context: context)
            let print = Self.fingerprint(items)
            guard fingerprints[category] != print else { continue }
            try? await index.deleteSearchableItems(withDomainIdentifiers: [category.domain])
            if !items.isEmpty { try? await index.indexSearchableItems(items) }
            fingerprints[category] = print
        }
    }

    private static func fingerprint(_ items: [CSSearchableItem]) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        for item in items {
            hasher.combine(item.uniqueIdentifier)
            hasher.combine(item.attributeSet.title)
            hasher.combine(item.attributeSet.contentDescription)
        }
        // 0 留给"已删空"。
        return hasher.finalize() | 1
    }

    // MARK: - 条目

    private static func item(_ category: SpotlightCategory, uuid: UUID, title: String,
                             description: String, keywords: [String] = []) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = description
        if !keywords.isEmpty { attributes.keywords = keywords }
        return CSSearchableItem(uniqueIdentifier: category.identifier(uuid),
                                domainIdentifier: category.domain, attributeSet: attributes)
    }

    private static func items(for category: SpotlightCategory, context: ModelContext) -> [CSSearchableItem] {
        let language = AppSettings.language
        switch category {
        case .task:
            var descriptor = FetchDescriptor<TaskItem>(
                predicate: #Predicate { $0.statusRaw == "pending" },
                sortBy: [SortDescriptor(\.nextRemindAt)])
            descriptor.fetchLimit = limit
            // 用药提醒是健康数据,不进系统搜索。
            return ((try? context.fetch(descriptor)) ?? []).filter { !$0.isMedicationReminder }.map { task in
                var parts = [LocalizedContent.dateCaption(task.nextRemindAt, language: language)]
                if let project = task.project, !project.isEmpty { parts.append("#\(project)") }
                return item(.task, uuid: task.uuid, title: task.title,
                            description: parts.joined(separator: " · "),
                            keywords: task.project.map { [$0] } ?? [])
            }
        case .countdown:
            let events = (try? context.fetch(FetchDescriptor<CountdownEvent>(
                predicate: #Predicate { $0.archived == false }))) ?? []
            return events.prefix(limit).map { event in
                let date = event.startDate.formatted(
                    Date.FormatStyle(date: .abbreviated, time: .omitted).locale(language.locale))
                let description = event.notes.isEmpty ? date : "\(date) · \(event.notes)"
                return item(.countdown, uuid: event.uuid, title: event.title, description: description)
            }
        case .trip:
            let trips = (try? context.fetch(FetchDescriptor<TravelTrip>(
                sortBy: [SortDescriptor(\.startDate, order: .reverse)]))) ?? []
            return trips.prefix(limit).map { trip in
                let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(language.locale)
                var parts = ["\(trip.startDate.formatted(style)) – \(trip.endDate.formatted(style))"]
                let place = [trip.city, trip.country].filter { !$0.isEmpty }.joined(separator: " · ")
                if !place.isEmpty { parts.append(place) }
                return item(.trip, uuid: trip.uuid, title: "\(trip.displayEmoji) \(trip.title)",
                            description: parts.joined(separator: " · "))
            }
        case .memory, .contact, .menu, .asset:
            var descriptor = FetchDescriptor<MemoryItem>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            descriptor.fetchLimit = 6000
            let all = (try? context.fetch(descriptor)) ?? []
            let picked: [MemoryItem]
            switch category {
            case .contact: picked = all.filter(\.isContact)
            case .menu: picked = all.filter(\.isMenu)
            case .asset: picked = all.filter(\.isAsset)
            default:
                // 普通记忆:去掉有自己类别的(人脉/菜单/资产)、行程项(旅行那类已经有)、
                // 以及一切健康资料(体检报告、打了「健康」的)。
                picked = all.filter {
                    !$0.isContact && !$0.isMenu && !$0.isAsset && !$0.isHealth && !$0.isCheckup
                        && $0.travelKind == nil
                }
            }
            return picked.prefix(limit).map { memory in
                let description: String
                switch category {
                case .contact:
                    description = [memory.contactNickname, memory.contactPhone, memory.contactEmail]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                case .asset:
                    // 不写金额:锁屏下拉就能搜到,只给名字和分类。
                    description = memory.tags.filter { !MemoryItem.reservedTagNames.contains($0) }
                        .joined(separator: " · ")
                default:
                    description = memory.summary
                }
                let keywords = memory.tags.filter { !MemoryItem.reservedTagNames.contains($0) }
                return item(category, uuid: memory.uuid, title: memory.title,
                            description: description, keywords: category == .asset ? [] : keywords)
            }
        }
    }
}
