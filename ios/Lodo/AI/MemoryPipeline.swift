import Foundation
import SwiftData
import LodoCore

/// AI 收藏的统一入口:落文件 → 插入 processing 条目(卡片立即出现)→
/// 后台提取文本 + AI 整理 → 回填 ready;任一步失败转 failed(原文已保留,
/// 重试只重跑提取与整理)。未配置 AI 时收藏依然成功,标题用文件名/首行兜底。
@MainActor
enum MemoryPipeline {

    /// 收藏纯文字;文字本身就是一条 URL 时按链接收藏。
    static func saveText(_ text: String, context: ModelContext) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let url = detectedURL(in: trimmed) {
            saveURL(url, context: context)
            return
        }
        let item = MemoryItem(kind: .text, sourceText: MemorySearch.truncate(trimmed))
        insertAndOrganize(item, context: context)
    }

    /// 收藏链接。
    static func saveURL(_ url: URL, context: ModelContext) {
        let item = MemoryItem(kind: .link, urlString: url.absoluteString)
        insertAndOrganize(item, context: context)
    }

    /// 收藏本地文件:先拷进 App Group 的 Memory/ 再走整理。
    /// 调用方负责 security-scoped resource 的开与关(fileImporter/分享收件箱两侧不同)。
    static func saveFile(_ fileURL: URL, context: ModelContext) {
        let kind = MemorySearch.kind(forExtension: fileURL.pathExtension)
        let item = MemoryItem(kind: kind == .text ? .text : kind,
                              originalFileName: fileURL.lastPathComponent)
        guard let copied = copyIntoStore(from: fileURL, uuid: item.uuid) else { return }
        item.relativeFilePath = "Memory/\(copied.lastPathComponent)"
        insertAndOrganize(item, context: context)
    }

    /// 收藏粘贴板里的图片数据(没有源文件路径,直接写成 png)。
    static func saveImageData(_ data: Data, context: ModelContext) {
        guard let dir = AppGroup.memoryDirURL else { return }
        let item = MemoryItem(kind: .image, originalFileName: nil)
        let target = dir.appending(path: "\(item.uuid.uuidString).png")
        guard (try? data.write(to: target, options: .atomic)) != nil else { return }
        item.relativeFilePath = "Memory/\(target.lastPathComponent)"
        insertAndOrganize(item, context: context)
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

    /// 删除条目并清掉原始文件。
    static func delete(_ item: MemoryItem, context: ModelContext) {
        if let url = fileURL(of: item) {
            try? FileManager.default.removeItem(at: url)
        }
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
            try? context.save()
        }
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
}
