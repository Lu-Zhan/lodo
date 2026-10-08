import Foundation
import SwiftData
import LodoCore

/// 把 AI 对话里「引用」的 app 内条目整理成一段发给模型的文字(`AgentReference.promptBlock`
/// 的正文)。在选中那一刻取内容——和从记忆库选条目时取 sourceText 同一个时机,
/// 用户看到的就是发出去的那一版。
///
/// 输出是**喂给模型的格式**,不随应用语言变(同 `[待办历史]` 这类上下文标签)。
@MainActor
enum AgentReferenceRenderer {
    static func body(for reference: AgentReference, in context: ModelContext) -> String {
        let id = reference.id
        switch reference.kind {
        case .task:
            guard let item = fetchFirst(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.uuid == id }),
                                        in: context) else { return missing }
            return renderTask(item)
        case .countdown:
            guard let event = fetchFirst(FetchDescriptor<CountdownEvent>(predicate: #Predicate { $0.uuid == id }),
                                         in: context) else { return missing }
            return renderCountdown(event)
        case .trip:
            guard let trip = fetchFirst(FetchDescriptor<TravelTrip>(predicate: #Predicate { $0.uuid == id }),
                                        in: context) else { return missing }
            return TravelStore.promptSummary(for: trip, includeIDs: true, in: context)
        case .asset, .contact, .menu:
            guard let item = fetchFirst(FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.uuid == id }),
                                        in: context) else { return missing }
            switch reference.kind {
            case .asset: return renderAsset(item)
            case .contact: return renderContact(item, in: context)
            default: return renderMenu(item, in: context)
            }
        case .finance:
            guard let entry = fetchFirst(FetchDescriptor<FinanceEntry>(predicate: #Predicate { $0.uuid == id }),
                                         in: context) else { return missing }
            return renderFinance(entry)
        case .news:
            guard let article = fetchFirst(FetchDescriptor<NewsArticle>(predicate: #Predicate { $0.uuid == id }),
                                           in: context) else { return missing }
            return renderNews(article)
        }
    }

    private static let missing = "(这一条已经被删除了)"

    private static func fetchFirst<T: PersistentModel>(_ descriptor: FetchDescriptor<T>,
                                                       in context: ModelContext) -> T? {
        var descriptor = descriptor
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private static func lines(_ parts: [String?]) -> String {
        parts.compactMap { part in
            guard let part, !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return part
        }.joined(separator: "\n")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let minuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func amount(_ value: Double?, _ currency: String) -> String? {
        guard let value else { return nil }
        return "\(value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))) \(currency)"
    }

    // MARK: - 各类

    private static func renderTask(_ task: TaskItem) -> String {
        let when = task.allDay ? dayFormatter.string(from: task.nextRemindAt) + "(全天)"
                               : minuteFormatter.string(from: task.nextRemindAt)
        return lines([
            "状态:" + (task.status == .done ? "已完成" : "未完成"),
            task.status == .done ? task.doneAt.map { "完成于:" + minuteFormatter.string(from: $0) }
                                 : "下次提醒:" + when,
            task.isRecurring ? "重复:" + task.data.repeatLabel : nil,
            task.project.map { "项目:" + $0 },
            task.pinned ? "已置顶" : nil,
            task.attachment.map { "附带资料:" + [$0.title, $0.summary].joined(separator: " ") },
        ])
    }

    private static func renderCountdown(_ event: CountdownEvent) -> String {
        let summary = CountdownPlan.promptSummary([event.entry], now: Calendar.current.startOfDay(for: .now))
        let format = event.allDay ? dayFormatter : minuteFormatter
        return lines([
            // 归档的不进 promptSummary,退回只写日子。
            summary.isEmpty
                ? "开始:" + format.string(from: event.startDate)
                    + (event.endDate.map { ",结束:" + format.string(from: $0) } ?? "")
                : summary,
            event.archived ? "已归档" : nil,
            event.notes.isEmpty ? nil : "备注:" + event.notes,
        ])
    }

    private static func renderAsset(_ item: MemoryItem) -> String {
        let currency = item.assetCurrencyOrDefault
        return lines([
            "分类:" + AssetCategory.category(of: item.tags, reserved: MemoryItem.reservedTagNames),
            amount(item.assetValue, currency).map { "价值:" + $0 },
            amount(item.assetLiability, currency).map { "负债:" + $0 },
            item.assetInterestRate.map { "利率:\($0)%" },
            "上次更新:" + dayFormatter.string(from: item.assetUpdatedAtOrCreated),
            item.summary.isEmpty ? nil : "说明:" + item.summary,
        ])
    }

    private static func renderFinance(_ entry: FinanceEntry) -> String {
        let kind: String = switch entry.kind {
        case .income: "收入"
        case .expense: "固定支出"
        case .creditCard: "信用卡"
        }
        let cadence: String = switch entry.cadence {
        case .monthly: "每月"
        case .quarterly: "每季度"
        case .yearly: "每年"
        case .irregular: "不定期"
        }
        return lines([
            "类型:" + kind,
            entry.kind == .creditCard ? nil : amount(entry.amount, entry.currency).map { "金额:\($0)(\(cadence))" },
            entry.institution.isEmpty ? nil : "机构:" + entry.institution,
            entry.statementDay.map { "账单日:每月 \($0) 号" },
            entry.dayOfMonth.map { entry.kind == .creditCard ? "还款日:每月 \($0) 号" : "日期:每月 \($0) 号" },
            entry.endDate.map { "截止:" + dayFormatter.string(from: $0) },
            entry.notes.isEmpty ? nil : "备注:" + entry.notes,
        ])
    }

    private static func renderContact(_ item: MemoryItem, in context: ModelContext) -> String {
        let owner = item.uuid
        let edges = (try? context.fetch(FetchDescriptor<ContactRelationship>(
            predicate: #Predicate { $0.memoryUUIDA == owner || $0.memoryUUIDB == owner }))) ?? []
        var relations: [String] = []
        for edge in edges {
            guard let other = edge.other(than: owner),
                  let person = fetchFirst(FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.uuid == other }),
                                          in: context) else { continue }
            relations.append(edge.label.isEmpty ? person.title : "\(person.title)(\(edge.label))")
        }
        return lines([
            item.contactNickname.map { "昵称:" + $0 },
            item.contactPhone.map { "电话:" + $0 },
            item.contactEmail.map { "邮箱:" + $0 },
            item.contactBirthday.map { "生日:" + dayFormatter.string(from: $0) },
            item.contactPreferences.map { "喜好:" + $0 },
            relations.isEmpty ? nil : "关系:" + relations.joined(separator: "、"),
            item.summary.isEmpty ? nil : "备注:" + item.summary,
        ])
    }

    private static func renderMenu(_ item: MemoryItem, in context: ModelContext) -> String {
        let owner = item.uuid
        let dishes = (try? context.fetch(FetchDescriptor<MenuDish>(
            predicate: #Predicate { $0.menuUUID == owner },
            sortBy: [SortDescriptor(\.sortIndex)]))) ?? []
        let currency = item.menuCurrency ?? ""
        let dishLines = dishes.map { dish -> String in
            var line = "- " + dish.originalName
            if !dish.translatedName.isEmpty, dish.translatedName != dish.originalName {
                line += "(\(dish.translatedName))"
            }
            if let price = dish.price { line += " " + (amount(price, currency) ?? "") }
            if !dish.category.isEmpty { line += " [\(dish.category)]" }
            if dish.selected { line += " ✓已选" }
            if !dish.intro.isEmpty { line += ":" + dish.intro }
            return line
        }
        return lines([
            item.menuSourceLanguage.map { "原文语言:" + $0 },
            dishLines.isEmpty ? (item.summary.isEmpty ? nil : item.summary)
                              : "菜品(\(dishes.count) 道):\n" + dishLines.joined(separator: "\n"),
        ])
    }

    private static func renderNews(_ article: NewsArticle) -> String {
        let ai = article.aiSummary
        return lines([
            "来源:" + article.feedTitle,
            "发布:" + minuteFormatter.string(from: article.publishedAt),
            article.link.isEmpty ? nil : "链接:" + article.link,
            ai.map { "AI 总结:" + $0.summary + ($0.points.isEmpty ? "" : "\n" + $0.points.map { "- " + $0 }.joined(separator: "\n")) },
            article.summary.isEmpty ? nil : "摘要:" + article.summary,
        ])
    }
}
