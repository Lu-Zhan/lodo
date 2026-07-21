import SwiftUI
import SwiftData
import LodoCore

/// 全局 agent 路由、批量操作确认。
extension TodoListView {
    /// 全局 agent:带上当前待办列表,把一句话解析成操作(开启记忆能力:
    /// 收藏/记忆问答也走同一入口)。单条新建/修改直达表单(表单即确认);
    /// 批量或含完成/删除的进确认清单;单条收藏/查记忆直接执行/作答;
    /// 关键信息缺失时透传反问。uuid 用最新 pending 列表重新匹配。
    func route(_ text: String) async throws -> AgentReply {
        let taskContext = pending.map { (uuid: $0.uuid.uuidString, task: ParsedTask(from: $0)) }
        switch try await DeepSeekClient.command(text, tasks: taskContext, memoryEnabled: true) {
        case .clarify(let question, let options):
            return .clarify(question: question, options: options)
        case .actions(let actions):
            if actions.count == 1 {
                if case .create(let parsed) = actions[0] {
                    sheet = .create(parsed, nil)
                    return .routed
                }
                if case .update(let uuid, let parsed) = actions[0] {
                    guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else {
                        throw DeepSeekError.parse("找不到要修改的事项")
                    }
                    sheet = .edit(task, parsed)
                    return .routed
                }
                if case .memorize(let text) = actions[0] {
                    MemoryPipeline.saveText(text, context: context)
                    return .answer(
                        text: "已收藏「\(MemorySearch.truncate(text, limit: 20))」,AI 正在整理成记忆条目。",
                        related: [])
                }
                if case .askMemory(let question) = actions[0] {
                    return try await answerFromMemory(question)
                }
            }
            pendingActions = actions
            return .confirm(actions.map(describe))
        }
    }

    /// 记忆问答:语义检索(命中 chunk 原文当摘录)与关键词粗排(整条截断兜底)取并集,
    /// 交给 AI 作答;库为空本地短路,不发请求。语义检索不可用时自动退化成纯关键词,
    /// 和"转为待办"等其他记忆功能一样不因为 AI 能力缺失而不可用。
    private func answerFromMemory(_ question: String) async throws -> AgentReply {
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        guard !items.isEmpty else {
            return .answer(text: "你还没有任何收藏,先在「记忆」页收藏一些内容吧。", related: [])
        }
        let itemsByUUID = Dictionary(uniqueKeysWithValues: items.map { ($0.uuid, $0) })

        // 语义检索:命中的是具体 chunk,原文直接当摘录用,不再是整条内容的前 400 字。
        var semanticExcerpts: [UUID: String] = [:]
        var semanticOrder: [UUID] = []
        if let queryVector = await embedQueryBestEffort(question) {
            let chunks = (try? context.fetch(FetchDescriptor<MemoryChunk>())) ?? []
            let chunkByUUID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.uuid, $0) })
            let candidates = chunks.filter { !$0.embedding.isEmpty }
                .map { (id: $0.uuid, vector: $0.embedding) }
            let topChunkUUIDs = VectorSearch.topK(
                query: queryVector, candidates: candidates, k: MemorySearch.maxAskItems)
            for chunkUUID in topChunkUUIDs {
                guard let chunk = chunkByUUID[chunkUUID],
                      itemsByUUID[chunk.itemUUID] != nil,
                      semanticExcerpts[chunk.itemUUID] == nil else { continue }
                semanticExcerpts[chunk.itemUUID] = chunk.text
                semanticOrder.append(chunk.itemUUID)
            }
        }

        // 关键词粗排照旧保留:精确匹配人名/编号这类语义检索未必擅长的场景兜底。
        let ranked = MemorySearch.rank(
            question: question,
            items: items.enumerated().map { index, item in
                (index: index,
                 text: "\(item.title) \(item.summary) \(item.tags.joined(separator: " ")) \(item.sourceText)",
                 createdAt: item.createdAt)
            })
        let keywordOrder = ranked.map { items[$0].uuid }

        // 合并去重:语义命中优先,关键词补位,按原有条目数上限截断。
        var seen = Set<UUID>()
        var orderedUUIDs: [UUID] = []
        for uuid in semanticOrder + keywordOrder where !seen.contains(uuid) {
            seen.insert(uuid)
            orderedUUIDs.append(uuid)
        }
        let candidates = orderedUUIDs.prefix(MemorySearch.maxAskItems)
            .compactMap { uuid -> (uuid: String, title: String, summary: String, tags: [String], excerpt: String)? in
                guard let item = itemsByUUID[uuid] else { return nil }
                let excerpt = semanticExcerpts[uuid] ?? MemorySearch.truncate(
                    item.sourceText, limit: MemorySearch.maxExcerptChars)
                return (uuid: item.uuid.uuidString, title: item.title, summary: item.summary,
                        tags: item.tags, excerpt: excerpt)
            }
        let (answer, relatedUUIDs) = try await DeepSeekClient.askMemory(
            question: question, items: candidates)
        let relatedTitles = relatedUUIDs.compactMap { uuid -> String? in
            guard let item = items.first(where: { $0.uuid.uuidString == uuid }) else { return nil }
            return item.title.isEmpty ? "(整理中)" : item.title
        }
        return .answer(text: answer, related: relatedTitles)
    }

    /// 端上给问题算向量;不可用/结果为空返回 nil,调用方据此跳过语义检索只用关键词。
    private func embedQueryBestEffort(_ question: String) async -> [Float]? {
        #if (os(iOS) || os(macOS)) && canImport(NaturalLanguage)
        if let vectors = try? await OnDeviceEmbeddingProvider().embed([question]),
           let first = vectors.first, !first.isEmpty {
            return first
        }
        #endif
        return nil
    }

    private func describe(_ action: AIAction) -> String {
        switch action {
        case .create(let parsed):
            var caption = TaskItem.format(parsed.remindAt)
            if parsed.durationMinutes > 0 { caption += " · \(parsed.durationMinutes) 分钟" }
            return "新建:\(parsed.title)(\(caption))"
        case .update(_, let parsed):
            return "修改:\(parsed.title)(\(TaskItem.format(parsed.remindAt)))"
        case .complete(let uuid):
            return "完成:\(title(of: uuid) ?? "未知事项")"
        case .delete(let uuid):
            return "删除:\(title(of: uuid) ?? "未知事项")"
        case .memorize(let text):
            // 防御性分支:route() 已把单条 memorize 短路直接执行,
            // 混合批次里理论上不会出现,兜底给出可读描述。
            return "收藏:\(MemorySearch.truncate(text, limit: 20))"
        case .askMemory:
            // 防御性分支:parseCommand 已把 ask_memory 与写操作混合时丢弃,
            // 正常不会走到这里。
            return "查询记忆"
        }
    }

    private func title(of uuid: String) -> String? {
        pending.first { $0.uuid.uuidString == uuid }?.title
    }

    /// 执行确认后的批量操作,完毕关闭 agent。等待确认期间,目标事项可能已被
    /// 通知按钮/小组件/Siri 改动或完成/删除;找不到时计入 missingCount,
    /// 而不是静默跳过——否则用户会以为全部操作都成功了。
    func performPendingActions() {
        var missingCount = 0
        for action in pendingActions {
            switch action {
            case .create(let parsed):
                saveNew(parsed)
            case .update(let uuid, let parsed):
                if let task = pending.first(where: { $0.uuid.uuidString == uuid }) {
                    apply(parsed, to: task)
                } else {
                    missingCount += 1
                }
            case .complete(let uuid):
                if let task = pending.first(where: { $0.uuid.uuidString == uuid }) {
                    NotificationManager.shared.complete(task, context: context)
                } else {
                    missingCount += 1
                }
            case .delete(let uuid):
                if let task = pending.first(where: { $0.uuid.uuidString == uuid }) {
                    NotificationManager.shared.cancelChain(for: task.uuid)
                    context.delete(task)
                } else {
                    missingCount += 1
                }
            case .memorize(let text):
                // 防御性分支:正常单条 memorize 已在 route() 里直接执行。
                MemoryPipeline.saveText(text, context: context)
            case .askMemory:
                // 防御性分支:查询类操作没有可执行的落库动作。
                break
            }
        }
        pendingActions = []
        try? context.save()
        WidgetBridge.sync(context: context)
        sheet = nil
        if missingCount > 0 {
            actionsWarning = "有 \(missingCount) 项操作未执行:对应事项已不存在"
        }
    }

    /// 消费深链/tab 按钮的路由请求;有 sheet 打开时不打断(如 agent 正在确认),
    /// 由 sheet onDismiss 再补一次消费。
    func consumeRoutes() {
        guard sheet == nil else { return }
        if let request = agentRequest {
            agentRequest = nil
            let autoStart = agentAutoStart
            agentAutoStart = false
            sheet = .agent(prefill: request.isEmpty ? nil : request, autoStart: autoStart)
        }
    }
}
