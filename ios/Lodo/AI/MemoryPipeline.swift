import Foundation
import SwiftData
import LodoCore

/// AI 收藏的统一入口:落文件 → 插入 processing 条目(卡片立即出现)→
/// 后台提取文本 + AI 整理 → 回填 ready;任一步失败转 failed(原文已保留,
/// 重试只重跑提取与整理)。未配置 AI 时收藏依然成功,标题用文件名/首行兜底。
@MainActor
enum MemoryPipeline {

    /// 收藏纯文字;文字本身就是一条 URL 时按链接收藏。返回新建的条目(agent
    /// 批量操作的撤销要记它的 uuid;其余调用方多数不关心,可丢弃)。
    @discardableResult
    static func saveText(_ text: String, context: ModelContext) -> MemoryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = detectedURL(in: trimmed) {
            return saveURL(url, context: context)
        }
        let item = MemoryItem(kind: .text, sourceText: MemorySearch.truncate(trimmed))
        insertAndOrganize(item, context: context)
        return item
    }

    /// 收藏链接。
    @discardableResult
    static func saveURL(_ url: URL, context: ModelContext) -> MemoryItem? {
        let item = MemoryItem(kind: .link, urlString: url.absoluteString)
        insertAndOrganize(item, context: context)
        return item
    }

    /// 收藏本地文件:先拷进 App Group 的 Memory/ 再走整理。
    /// 调用方负责 security-scoped resource 的开与关(fileImporter/分享收件箱两侧不同)。
    /// 返回新建的条目(聊天页附件想拿 uuid 关联消息;其余调用方多数不关心,可丢弃)。
    @discardableResult
    static func saveFile(_ fileURL: URL, context: ModelContext) -> MemoryItem? {
        let kind = MemorySearch.kind(forExtension: fileURL.pathExtension)
        let item = MemoryItem(kind: kind == .text ? .text : kind,
                              originalFileName: fileURL.lastPathComponent)
        guard let copied = copyIntoStore(from: fileURL, uuid: item.uuid) else { return nil }
        item.relativeFilePath = "Memory/\(copied.lastPathComponent)"
        insertAndOrganize(item, context: context)
        return item
    }

    /// 收藏粘贴板里的图片数据(没有源文件路径,直接写成 png)。
    @discardableResult
    static func saveImageData(_ data: Data, context: ModelContext) -> MemoryItem? {
        guard let dir = AppGroup.memoryDirURL else { return nil }
        let item = MemoryItem(kind: .image, originalFileName: nil)
        let target = dir.appending(path: "\(item.uuid.uuidString).png")
        guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        item.relativeFilePath = "Memory/\(target.lastPathComponent)"
        insertAndOrganize(item, context: context)
        return item
    }

    /// 记一笔资产:字段已经是结构化的(名称/金额/分类/备注),不需要像文字/
    /// 文件收藏那样靠 AI 提炼标题摘要,直接落成 ready 状态;仍然跑分片 + 向量
    /// 索引,备注也能被"问 AI"检索到。category 非空时额外打一个子分类标签,
    /// 和保留的 assetTagName 一起构成 tags,列表页据此归到"资产"分组里隐藏。
    static func saveAsset(
        title: String, value: Double?, category: String, note: String, context: ModelContext
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        var tags = [MemoryItem.assetTagName]
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCategory.isEmpty { tags.append(trimmedCategory) }
        let item = MemoryItem(
            kind: .text, title: trimmedTitle, summary: note, tags: tags,
            sourceText: MemorySearch.truncate(note), status: .ready, assetValue: value)
        context.insert(item)
        try? context.save()
        Task { @MainActor in
            await reindexChunks(item, context: context)
            try? context.save()
        }
    }

    /// 记一位联系人:字段是结构化的(姓名/昵称/联系方式/生日/喜好/备注),不需要
    /// 像文字/文件收藏那样靠 AI 提炼,直接落成 ready 状态;姓名/备注复用
    /// title/summary(和 saveAsset 的 note→summary 同思路)。sourceText 拼接
    /// 备注+喜好,供检索/问 AI 用。头像与附件落 App Group 的 Contacts/ 目录,
    /// 与"记忆条目原文件"(Memory/ 目录、relativeFilePath 字段)各自独立。
    @discardableResult
    static func saveContact(
        name: String, nickname: String, phone: String, email: String,
        birthday: Date?, preferences: String, note: String,
        avatarData: Data?, attachmentFileURLs: [URL], context: ModelContext
    ) -> MemoryItem? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let item = MemoryItem(
            kind: .text, title: trimmedName, summary: note,
            tags: [MemoryItem.contactTagName],
            sourceText: MemorySearch.truncate(
                [note, preferences].filter { !$0.isEmpty }.joined(separator: "\n")),
            status: .ready,
            contactNickname: nickname.isEmpty ? nil : nickname,
            contactPhone: phone.isEmpty ? nil : phone,
            contactEmail: email.isEmpty ? nil : email,
            contactBirthday: birthday,
            contactPreferences: preferences.isEmpty ? nil : preferences)
        if let avatarData, let dir = AppGroup.contactsDirURL {
            let target = dir.appending(path: "\(item.uuid.uuidString)-avatar.jpg")
            if (try? avatarData.write(to: target, options: .atomic)) != nil {
                item.contactAvatarRelativePath = "Contacts/\(target.lastPathComponent)"
            }
        }
        item.attachmentRelativePaths = attachmentFileURLs.compactMap(copyContactAttachment)
        context.insert(item)
        try? context.save()
        Task { @MainActor in
            await reindexChunks(item, context: context)
            try? context.save()
        }
        return item
    }

    /// A、B 之间已有边时更新 label,不叠加第二条("同事"改成"前同事"是覆盖,
    /// 不该和旧的并存)。两端相同(自己连自己)时不做任何事。
    static func upsertContactRelationship(
        between a: UUID, and b: UUID, label: String, context: ModelContext
    ) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, a != b else { return }
        let existing = (try? context.fetch(FetchDescriptor<ContactRelationship>())) ?? []
        if let edge = existing.first(where: { $0.involves(a) && $0.involves(b) }) {
            edge.label = trimmed
        } else {
            context.insert(ContactRelationship(memoryUUIDA: a, memoryUUIDB: b, label: trimmed))
        }
        try? context.save()
    }

    static func deleteContactRelationship(_ relationship: ContactRelationship, context: ModelContext) {
        context.delete(relationship)
        try? context.save()
    }

    /// 某个联系人条目牵涉的全部关系边,附带边另一端对应的 MemoryItem
    /// (对端条目被删掉后对应边理应已被 delete(_:context:) 一并清掉,这里仍
    /// 防御性地跳过找不到对端的边)。
    static func contactRelationships(
        of uuid: UUID, context: ModelContext
    ) -> [(relationship: ContactRelationship, other: MemoryItem)] {
        let edges = (try? context.fetch(FetchDescriptor<ContactRelationship>())) ?? []
        let involved = edges.filter { $0.involves(uuid) }
        guard !involved.isEmpty else { return [] }
        let others = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        let othersByUUID = Dictionary(uniqueKeysWithValues: others.map { ($0.uuid, $0) })
        return involved.compactMap { edge in
            guard let otherUUID = edge.other(than: uuid), let other = othersByUUID[otherUUID] else { return nil }
            return (relationship: edge, other: other)
        }
    }

    /// 联系人头像的绝对路径;无头像或(异地同步条目)文件缺失时为 nil。
    static func contactAvatarURL(of item: MemoryItem) -> URL? {
        guard let relative = item.contactAvatarRelativePath,
              let url = AppGroup.containerURL?.appending(path: relative),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 联系人全部文件附件的绝对路径,缺失的自动跳过。
    static func contactAttachmentURLs(of item: MemoryItem) -> [URL] {
        item.attachmentRelativePaths.compactMap { relative in
            guard let url = AppGroup.containerURL?.appending(path: relative),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    /// 整理失败的条目重试:重跑提取 + AI 整理。
    static func retry(_ item: MemoryItem, context: ModelContext) {
        item.statusRaw = MemoryStatus.processing.rawValue
        try? context.save()
        organize(item, context: context)
    }

    /// 记忆条目"转为待办"时拷贝的内容快照:标题/摘要/已提取文字/链接,
    /// 不带原始文件——原记忆条目之后被编辑或删除都不影响这份快照。
    static func makeAttachment(from item: MemoryItem) -> TaskAttachment {
        TaskAttachment(
            kind: item.kind,
            title: item.title.isEmpty ? (item.originalFileName ?? "") : item.title,
            summary: item.summary, text: item.sourceText,
            urlString: item.urlString, originalFileName: item.originalFileName)
    }

    /// 删除条目、清掉原始文件、清掉这条记忆的全部 MemoryChunk(避免孤儿数据);
    /// 联系人条目额外清掉头像/附件文件与牵涉的全部 ContactRelationship 边
    /// (非联系人条目这几步都是空操作)。
    static func delete(_ item: MemoryItem, context: ModelContext) {
        if let url = fileURL(of: item) {
            try? FileManager.default.removeItem(at: url)
        }
        if let avatarURL = contactAvatarURL(of: item) {
            try? FileManager.default.removeItem(at: avatarURL)
        }
        for url in contactAttachmentURLs(of: item) {
            try? FileManager.default.removeItem(at: url)
        }
        let owner = item.uuid
        let chunks = (try? context.fetch(FetchDescriptor<MemoryChunk>(
            predicate: #Predicate { $0.itemUUID == owner }))) ?? []
        for chunk in chunks { context.delete(chunk) }
        let edges = (try? context.fetch(FetchDescriptor<ContactRelationship>())) ?? []
        for edge in edges where edge.involves(owner) { context.delete(edge) }
        context.delete(item)
        try? context.save()
    }

    /// 消费 Share Extension 落在收件箱里的分享内容(app 冷启动/回前台时调用):
    /// 每个子目录一条(meta.json + 可选 payload 文件),入库走标准整理管线后删掉。
    static func consumeInbox(context: ModelContext) {
        guard let inbox = AppGroup.inboxDirURL,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: inbox, includingPropertiesForKeys: nil) else { return }
        for dir in entries where dir.hasDirectoryPath {
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let data = try? Data(contentsOf: dir.appending(path: "meta.json")),
                  let meta = try? JSONDecoder().decode([String: String].self, from: data),
                  let type = meta["type"] else { continue }
            switch type {
            case "text":
                if let text = meta["text"] { saveText(text, context: context) }
            case "url":
                if let urlString = meta["url"], let url = URL(string: urlString) {
                    saveURL(url, context: context)
                }
            case "file":
                if let filename = meta["filename"] {
                    saveFile(dir.appending(path: filename), context: context)
                }
            default:
                break
            }
        }
    }

    /// 条目原始文件的绝对路径;无文件或(异地同步条目)文件缺失时为 nil。
    static func fileURL(of item: MemoryItem) -> URL? {
        guard let relative = item.relativeFilePath,
              let url = AppGroup.containerURL?.appending(path: relative),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - 内部流程

    private static func insertAndOrganize(_ item: MemoryItem, context: ModelContext) {
        context.insert(item)
        try? context.save()
        organize(item, context: context)
    }

    /// 提取文本 + AI 整理;失败时给兜底标题并标记 failed。
    private static func organize(_ item: MemoryItem, context: ModelContext) {
        Task { @MainActor in
            let extraction = await extract(item)
            if !extraction.text.isEmpty { item.sourceText = extraction.text }
            do {
                guard DeepSeekClient.isConfigured else { throw DeepSeekError.noKey }
                let entry = try await DeepSeekClient.memorize(
                    text: item.sourceText,
                    filename: item.originalFileName ?? item.urlString,
                    kind: item.kind.label,
                    existingTags: MemoryTags.all(in: context))
                item.title = entry.title
                item.summary = entry.summary
                item.tags = entry.tags
                item.statusRaw = MemoryStatus.ready.rawValue
            } catch {
                if item.title.isEmpty {
                    item.title = fallbackTitle(for: item, suggested: extraction.suggestedTitle)
                }
                item.statusRaw = MemoryStatus.failed.rawValue
            }
            // 分片 + 语义向量:独立于上面 AI 整理是否成功,尽力而为
            // (embedding 失败时退化成关键词检索,不影响记忆本身可用)。
            await reindexChunks(item, context: context)
            try? context.save()
        }
    }

    /// 重新分片 + 算向量,替换这条记忆现有的 MemoryChunk(sourceText 变了就要重算)。
    private static func reindexChunks(_ item: MemoryItem, context: ModelContext) async {
        let owner = item.uuid
        let existing = (try? context.fetch(FetchDescriptor<MemoryChunk>(
            predicate: #Predicate { $0.itemUUID == owner }))) ?? []
        for chunk in existing { context.delete(chunk) }

        let pieces = MemoryChunker.split(item.sourceText)
        guard !pieces.isEmpty else { return }
        let vectors = await embedBestEffort(pieces)
        for (index, text) in pieces.enumerated() {
            let vector = index < vectors.count ? vectors[index] : []
            context.insert(MemoryChunk(itemUUID: owner, text: text, embedding: vector))
        }
    }

    /// 端上优先算向量;不可用/出错时返回等长的空向量数组,调用方据此退化
    /// (chunk 仍然入库,只是那条只能靠关键词检索命中)。云端兜底见 Phase 2。
    private static func embedBestEffort(_ texts: [String]) async -> [[Float]] {
        #if (os(iOS) || os(macOS)) && canImport(NaturalLanguage)
        if let vectors = try? await OnDeviceEmbeddingProvider().embed(texts),
           vectors.count == texts.count {
            return vectors
        }
        #endif
        return texts.map { _ in [] }
    }

    private static func extract(_ item: MemoryItem) async -> ContentExtractor.Extraction {
        if let url = fileURL(of: item) {
            return await ContentExtractor.extract(fileURL: url)
        }
        if let urlString = item.urlString, let url = URL(string: urlString) {
            return await ContentExtractor.extract(url: url)
        }
        return ContentExtractor.extract(text: item.sourceText)
    }

    /// AI 不可用/失败时的标题兜底:元数据标题 → 文件名 → 原文首行 → 链接 → "收藏"。
    private static func fallbackTitle(for item: MemoryItem, suggested: String?) -> String {
        if let suggested, !suggested.isEmpty { return suggested }
        if let name = item.originalFileName, !name.isEmpty { return name }
        if let firstLine = item.sourceText
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return MemorySearch.truncate(firstLine, limit: 20)
        }
        if let urlString = item.urlString { return urlString }
        return "收藏"
    }

    /// 整段文字就是一条 URL 时识别出来(不做正文里的链接抽取)。
    private static func detectedURL(in text: String) -> URL? {
        guard !text.contains(where: \.isNewline), !text.contains(" "),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func copyIntoStore(from source: URL, uuid: UUID) -> URL? {
        guard let dir = AppGroup.memoryDirURL else { return nil }
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension
        let target = dir.appending(path: "\(uuid.uuidString).\(ext)")
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        } catch {
            return nil
        }
    }

    /// 联系人附件可以有多个,每个都要独立文件名(不能像单文件字段那样用条目
    /// uuid 命名,会互相覆盖);uuid 前缀避免冲突,后面保留原文件名方便详情页
    /// 展示("<uuid>-原文件名.ext",详情页按固定长度剥掉前缀即可还原原名)。
    private static func copyContactAttachment(_ source: URL) -> String? {
        guard let dir = AppGroup.contactsDirURL else { return nil }
        let filename = "\(UUID().uuidString)-\(source.lastPathComponent)"
        let target = dir.appending(path: filename)
        do {
            try FileManager.default.copyItem(at: source, to: target)
            return "Contacts/\(filename)"
        } catch {
            return nil
        }
    }
}
