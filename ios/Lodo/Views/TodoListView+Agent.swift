import SwiftUI
import SwiftData
import LodoCore

/// 全局 agent 路由、批量操作确认。
extension TodoListView {
    /// 全局 agent:带上当前待办列表,把一句话解析成操作(开启记忆能力:
    /// 收藏/记忆问答也走同一入口)。单条新建/修改直达表单(表单即确认);
    /// 批量或含完成/删除的进确认清单;单条收藏/查记忆直接执行/作答;
    /// 关键信息缺失时透传反问。uuid 用最新 pending 列表重新匹配。
    ///
    /// ReAct 循环:模型如果先要查记忆/联网搜索才能给最终答案,会先返回一个
    /// .toolCall(只读、不落库),执行完把结果喂回去再问一轮,最多 3 轮(1 次初始 +
    /// 2 次工具调用,两种工具可以混用),超过就报错——不能无限转,也不允许写操作
    /// 在这个循环里未经确认就被模型自己执行。onThought 用来给聊天页展示
    /// "正在查记忆…"/"正在联网搜索…"这类轻量提示,循环结束(不管哪个分支返回)
    /// 提示自然被 AgentView 清掉。
    func route(
        _ text: String, threadUUID: UUID, history: [(role: String, content: String)] = [],
        onThought: (String) -> Void = { _ in }
    ) async throws -> AgentReply {
        // 撤销走本地固定短语匹配,不进 AI 循环——这是确定性操作,交给模型理解
        // 反而多一次网络请求、多一种出错可能,不值得。要求整句话就是这几个词
        // 之一(不是"包含"),避免误伤"撤销一份合同"这类正常事项标题。
        if isUndoCommand(text) {
            return performUndo(threadUUID: threadUUID)
        }

        let taskContext = pending.map { (uuid: $0.uuid.uuidString, task: ParsedTask(from: $0)) }
        var reasoningHistory = history
        var currentText = text
        let webSearchEnabled = WebSearchClient.isConfigured

        for _ in 0..<3 {
            switch try await DeepSeekClient.command(
                currentText, tasks: taskContext, memoryEnabled: true,
                webSearchEnabled: webSearchEnabled, history: reasoningHistory) {
            case .clarify(let question, let options):
                return .clarify(question: question, options: options)
            case .toolCall(let thought, .searchMemory(let query)):
                onThought(thought)
                let candidates = await retrieveMemoryCandidates(query)
                let observation = candidates.isEmpty ? "没有找到相关记忆内容" :
                    candidates.map { "「\($0.title)」\($0.excerpt)" }.joined(separator: "\n")
                reasoningHistory.append((role: "assistant", content: "思考:\(thought);查记忆:\(query)"))
                reasoningHistory.append((role: "user", content: "记忆检索结果:\n\(observation)"))
                currentText = "(请基于以上记忆检索结果继续处理最初的请求:\(text))"
            case .toolCall(let thought, .webSearch(let query)):
                onThought(thought)
                let observation: String
                do {
                    let results = try await WebSearchClient.search(query)
                    observation = results.isEmpty ? "没有搜到相关结果" :
                        results.map { "「\($0.title)」\($0.snippet)\n来源:\($0.url)" }
                            .joined(separator: "\n\n")
                } catch {
                    observation = "联网搜索失败:\(error.localizedDescription)"
                }
                reasoningHistory.append((role: "assistant", content: "思考:\(thought);联网搜索:\(query)"))
                reasoningHistory.append((role: "user", content: "搜索结果:\n\(observation)"))
                currentText = "(请基于以上搜索结果继续处理最初的请求:\(text))"
            case .toolCall(let thought, .webFetch(let urlString)):
                onThought(thought)
                let observation: String
                if let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
                    let extraction = await ContentExtractor.extract(url: url)
                    observation = extraction.text.isEmpty ? "抓取失败或页面无正文内容" : extraction.text
                } else {
                    observation = "无效链接:\(urlString)"
                }
                reasoningHistory.append((role: "assistant", content: "思考:\(thought);抓取链接:\(urlString)"))
                reasoningHistory.append((role: "user", content: "链接内容:\n\(observation)"))
                currentText = "(请基于以上链接内容继续处理最初的请求:\(text))"
            case .actions(let actions):
                if actions.count == 1 {
                    if case .create(let parsed) = actions[0] {
                        return .routeToForm(existing: nil, parsed: parsed)
                    }
                    if case .update(let uuid, let parsed) = actions[0] {
                        guard let task = pending.first(where: { $0.uuid.uuidString == uuid }) else {
                            throw DeepSeekError.parse("找不到要修改的事项")
                        }
                        return .routeToForm(existing: task, parsed: parsed)
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
                    if case .answer(let text) = actions[0] {
                        return .answer(text: text, related: [])
                    }
                }
                pendingActions = actions
                return .confirm(actions.map(describe))
            }
        }
        throw DeepSeekError.parse("多轮推理超过上限,换个说法试试")
    }

    /// 记忆问答:语义检索(命中 chunk 原文当摘录)与关键词粗排(整条截断兜底)取并集。
    /// 库为空本地短路,不发请求。语义检索不可用时自动退化成纯关键词,和"转为待办"
    /// 等其他记忆功能一样不因为 AI 能力缺失而不可用。
    private func answerFromMemory(_ question: String) async throws -> AgentReply {
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        guard !items.isEmpty else {
            return .answer(text: "你还没有任何收藏,先在「记忆」页收藏一些内容吧。", related: [])
        }
        let candidates = await retrieveMemoryCandidates(question)
        let (answer, relatedUUIDs) = try await DeepSeekClient.askMemory(
            question: question, items: candidates)
        let relatedTitles = relatedUUIDs.compactMap { uuid -> String? in
            guard let item = items.first(where: { $0.uuid.uuidString == uuid }) else { return nil }
            return item.title.isEmpty ? "(整理中)" : item.title
        }
        return .answer(text: answer, related: relatedTitles)
    }

    /// 语义检索(命中 chunk 原文当摘录)与关键词粗排(整条截断兜底)取并集,给出
    /// 命中的记忆条目片段;不生成自然语言回答——ReAct 工具步骤和 answerFromMemory
    /// 共用这一段,前者把结果原样喂回模型让它自己继续推理,省一次多余的 AI 调用。
    private func retrieveMemoryCandidates(
        _ question: String
    ) async -> [(uuid: String, title: String, summary: String, tags: [String], excerpt: String)] {
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        guard !items.isEmpty else { return [] }
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
        return orderedUUIDs.prefix(MemorySearch.maxAskItems)
            .compactMap { uuid -> (uuid: String, title: String, summary: String, tags: [String], excerpt: String)? in
                guard let item = itemsByUUID[uuid] else { return nil }
                let excerpt = semanticExcerpts[uuid] ?? MemorySearch.truncate(
                    item.sourceText, limit: MemorySearch.maxExcerptChars)
                return (uuid: item.uuid.uuidString, title: item.title, summary: item.summary,
                        tags: item.tags, excerpt: excerpt)
            }
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
        case .answer:
            // 防御性分支:parseCommand 已把 answer 与写操作混合时丢弃,
            // 正常不会走到这里(route() 已把单条 answer 短路直接返回)。
            return "回答问题"
        }
    }

    private func title(of uuid: String) -> String? {
        pending.first { $0.uuid.uuidString == uuid }?.title
    }

    /// 执行确认后的批量操作;不关闭 agent 聊天页,由 AgentView 自己往当前
    /// thread 追加一条结果消息。等待确认期间,目标事项可能已被通知按钮/
    /// 小组件/Siri 改动或完成/删除;找不到时计入 missingCount,而不是静默
    /// 跳过——否则用户会以为全部操作都成功了。执行前把每条操作的"改回原样"
    /// 快照存进 lastUndo,供后面撤销用;新的一批会整体覆盖上一批,连同
    /// threadUUID 一起记——同时开着好几个 thread 时,撤销要认得这批操作是
    /// 从哪个 thread confirm 的,不能被别的 thread 后来居上的一批覆盖后误撤销。
    func performPendingActions(threadUUID: UUID) {
        var missingCount = 0
        var undoOps: [UndoOp] = []
        for action in pendingActions {
            switch action {
            case .create(let parsed):
                let created = saveNew(parsed)
                undoOps.append(.created(uuid: created.uuid))
            case .update(let uuid, let parsed):
                if let task = pending.first(where: { $0.uuid.uuidString == uuid }) {
                    undoOps.append(.updated(before: task.backup))
                    apply(parsed, to: task)
                } else {
                    missingCount += 1
                }
            case .complete(let uuid):
                if let task = pending.first(where: { $0.uuid.uuidString == uuid }) {
                    let before = task.backup
                    let history = NotificationManager.shared.complete(task, context: context)
                    undoOps.append(.completed(before: before, insertedHistoryUUID: history?.uuid))
                } else {
                    missingCount += 1
                }
            case .delete(let uuid):
                if let task = pending.first(where: { $0.uuid.uuidString == uuid }) {
                    undoOps.append(.deleted(before: task.backup))
                    NotificationManager.shared.cancelChain(for: task.uuid)
                    context.delete(task)
                } else {
                    missingCount += 1
                }
            case .memorize(let text):
                // 防御性分支:正常单条 memorize 已在 route() 里直接执行;混在批次
                // 里执行时也要记进 undoOps,否则撤销批次时这条记忆会被漏掉。
                if let created = MemoryPipeline.saveText(text, context: context) {
                    undoOps.append(.memorized(uuid: created.uuid))
                }
            case .askMemory, .answer:
                // 防御性分支:查询/回答类操作没有可执行的落库动作。
                break
            }
        }
        pendingActions = []
        lastUndo = undoOps.isEmpty ? nil : undoOps
        lastUndoThreadUUID = undoOps.isEmpty ? nil : threadUUID
        try? context.save()
        WidgetBridge.sync(context: context)
        if missingCount > 0 {
            actionsWarning = "有 \(missingCount) 项操作未执行:对应事项已不存在"
        }
    }

    // MARK: - 撤销

    /// 要求整句话就是这几个固定短语之一,不做"包含"匹配。
    private func isUndoCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["撤销", "撤销上一步", "撤销上一条", "撤回", "撤回上一步", "undo"].contains(trimmed)
    }

    /// 把 lastUndo 记录的上一批操作按相反方向改回去:新建 → 删除,修改/完成 →
    /// 用之前的快照覆盖回去,删除 → 用快照重新插入(uuid 不变)。用完清空,
    /// 只能撤销最近一批,不支持多级撤销栈。internal(不是 private):聊天页
    /// "已完成执行"气泡上的撤销按钮(AgentView 的 onUndo)直接调这个,
    /// 不需要再走一遍文字指令匹配。threadUUID 必须和 lastUndoThreadUUID 对上——
    /// 不对就说明这批操作是别的 thread 留下的,拒绝撤销(不然会在 thread A
    /// 里意外撤销了 thread B 后来执行的操作)。
    func performUndo(threadUUID: UUID) -> AgentReply {
        guard let ops = lastUndo, lastUndoThreadUUID == threadUUID else {
            return .answer(text: "没有可撤销的操作。", related: [])
        }
        var missingCount = 0
        for op in ops.reversed() {
            switch op {
            case .created(let uuid):
                guard let task = taskByUUID(uuid) else { missingCount += 1; continue }
                NotificationManager.shared.cancelChain(for: task.uuid)
                context.delete(task)
            case .updated(let before):
                guard let task = taskByUUID(before.uuid) else { missingCount += 1; continue }
                before.apply(to: task)
                NotificationManager.shared.rebuild(for: task)
            case .completed(let before, let insertedHistoryUUID):
                if let task = taskByUUID(before.uuid) {
                    before.apply(to: task)
                    NotificationManager.shared.rebuild(for: task)
                } else {
                    missingCount += 1
                }
                if let insertedHistoryUUID, let history = taskByUUID(insertedHistoryUUID) {
                    context.delete(history)
                }
            case .deleted(let before):
                let task = TaskItem(title: before.title, remindAt: before.remindAt)
                before.apply(to: task)
                context.insert(task)
                NotificationManager.shared.rebuild(for: task)
            case .memorized(let uuid):
                guard let item = (try? context.fetch(FetchDescriptor<MemoryItem>(
                    predicate: #Predicate<MemoryItem> { $0.uuid == uuid }))).flatMap(\.first) else {
                    missingCount += 1
                    continue
                }
                MemoryPipeline.delete(item, context: context)
            }
        }
        lastUndo = nil
        lastUndoThreadUUID = nil
        try? context.save()
        WidgetBridge.sync(context: context)
        let suffix = missingCount > 0 ? "(\(missingCount) 项因事项已不存在无法撤销)" : ""
        return .answer(text: "已撤销上一步操作\(suffix)。", related: [])
    }

    private func taskByUUID(_ uuid: UUID) -> TaskItem? {
        pending.first(where: { $0.uuid == uuid }) ?? doneTasks.first(where: { $0.uuid == uuid })
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
