import Foundation
import SwiftData
import LodoCore

/// Watch 上的「记一下 / 问一下」:记忆条目和手机是同一张 `MemoryItem` 表(经 CloudKit
/// 私有库同步过来),这里只做手表够得着的那部分——
/// - 记:纯文字,当场调一次 `DeepSeekClient.memorize` 整理标题摘要标签,直接落成 ready;
///   整理失败用首句兜底。**不建 MemoryChunk**(手表上没有端上 embedding),所以手机的
///   语义检索暂时搜不到手表记的条目,关键词检索照样能命中。
/// - 查:关键词粗排 + 已完成任务的历史,同手机 `retrieveMemoryCandidates` 没有向量的那条
///   退化路径(手机上 embedding 不可用时也是这样)。
@MainActor
enum WatchMemory {
    typealias Candidate = (uuid: String, title: String, summary: String, tags: [String],
                           excerpt: String, isTaskHistory: Bool)

    /// 用户明确说「记一下…」。返回落库条目的标题(给回执用)。
    /// 整理途中被取消(用户点了取消 / 关掉了助手)抛 `CancellationError`,**不落库**——
    /// 原来把取消当成整理失败、拿原文兜底照样存了一条。
    static func save(_ text: String, context: ModelContext) async throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = MemoryItem(kind: .text, sourceText: MemorySearch.truncate(trimmed), status: .ready)
        do {
            let tags = existingTags(in: context)
            let entry = try await DeepSeekClient.memorize(
                text: trimmed, filename: nil, kind: MemoryKind.text.label, existingTags: tags)
            item.title = entry.title
            item.summary = entry.summary
            item.tags = entry.tags
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            item.title = String(trimmed.prefix(20))
        }
        try Task.checkCancellation()
        context.insert(item)
        try? context.save()
        return item.title
    }

    /// 对话里顺带提到的事实(`auto_memorize`),去重规则同手机 `MemoryPipeline.saveAutoMemory`:
    /// 新内容是已有自动记录的更完整版本就原地更新,被已有的包含就跳过。
    static func saveAuto(title: String, text: String, context: ModelContext) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !text.isEmpty else { return }
        let autoItems = ((try? context.fetch(FetchDescriptor<MemoryItem>())) ?? [])
            .filter { $0.tags.contains(MemoryItem.autoTagName) }
        if let elaborated = autoItems.first(where: {
            text.count > $0.summary.count && text.localizedStandardContains($0.summary)
        }) {
            elaborated.title = title
            elaborated.summary = text
            elaborated.sourceText = MemorySearch.truncate(text)
        } else if autoItems.contains(where: { $0.summary.localizedStandardContains(text) }) {
            return
        } else {
            context.insert(MemoryItem(
                kind: .text, title: title, summary: text, tags: [MemoryItem.autoTagName],
                sourceText: MemorySearch.truncate(text), status: .ready))
        }
        try? context.save()
    }

    /// 「上次…是什么时候」「xx 的密码提示是什么」:检索 + 让模型照着检索结果回答。
    static func answer(_ question: String, context: ModelContext) async throws -> String {
        let candidates = retrieve(question, context: context)
        guard !candidates.isEmpty else {
            return "没有找到相关的记忆。"
        }
        let (answer, _) = try await DeepSeekClient.askMemory(
            question: question,
            items: candidates.map { candidate in
                (uuid: candidate.uuid, title: candidate.title, summary: candidate.summary,
                 tags: candidate.tags,
                 excerpt: (candidate.isTaskHistory ? "[待办历史] " : "") + candidate.excerpt)
            })
        return answer
    }

    /// ReAct `search_memory` 的观察结果,格式和手机逐字一致(模型那边看到的是同一种东西)。
    static func observation(for query: String, context: ModelContext) -> String {
        let candidates = retrieve(query, context: context)
        guard !candidates.isEmpty else { return "没有找到相关记忆内容" }
        return candidates.map { candidate in
            candidate.isTaskHistory ? "[待办历史] 「\(candidate.title)」\(candidate.excerpt)"
                : "「\(candidate.title)」\(candidate.excerpt) [id:\(candidate.uuid)]"
        }
        .joined(separator: "\n")
    }

    static func retrieve(_ question: String, context: ModelContext) -> [Candidate] {
        // 「AI 与资产隔离」(默认开)同手机:资产条目不进检索,否则会被当成摘录发给模型。
        // 手表上没有这个设置界面,读的是手表本机的值(没设过 = 开)。
        let excludesAssets = AppSettings.assetsAIIsolated
        let items = ((try? context.fetch(FetchDescriptor<MemoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? [])
            .filter { !(excludesAssets && $0.isAsset) }
        let ranked = MemorySearch.rank(
            question: question,
            items: items.enumerated().map { index, item in
                (index: index,
                 text: "\(item.title) \(item.summary) \(item.tags.joined(separator: " ")) \(item.sourceText)",
                 createdAt: item.createdAt)
            })
        let memory: [Candidate] = ranked.map { index in
            let item = items[index]
            return (uuid: item.uuid.uuidString, title: item.title, summary: item.summary,
                    tags: item.tags,
                    excerpt: MemorySearch.truncate(item.sourceText, limit: MemorySearch.maxExcerptChars),
                    isTaskHistory: false)
        }

        let done = ((try? context.fetch(FetchDescriptor<TaskItem>(
            predicate: #Predicate<TaskItem> { $0.statusRaw == "done" },
            sortBy: [SortDescriptor(\.doneAt, order: .reverse)]))) ?? []).filter { !$0.isMedicationReminder }
        let matched = MemorySearch.matchTaskHistory(
            question: question,
            items: done.enumerated().map { index, task in (index: index, title: task.title) })
        let history: [Candidate] = matched.map { index in
            let task = done[index]
            let excerpt = String(format: LocalizedStrings.text(.ios_core_completed_at,
                                                               language: AppSettings.language),
                                 TaskItem.format(task.doneAt ?? task.remindAt))
            return (uuid: "task:\(task.uuid.uuidString)", title: task.title, summary: "",
                    tags: [], excerpt: excerpt, isTaskHistory: true)
        }
        return memory + history
    }

    private static func existingTags(in context: ModelContext) -> [String] {
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        var seen = Set<String>()
        var tags: [String] = []
        for tag in items.flatMap(\.tags) where tag != MemoryItem.autoTagName && seen.insert(tag).inserted {
            tags.append(tag)
        }
        return tags
    }
}
