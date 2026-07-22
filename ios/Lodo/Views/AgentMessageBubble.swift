import SwiftUI
import SwiftData
import LodoCore

/// 一条消息的气泡渲染;confirm 的按钮只在 isLatest(这条是当前 thread 最新
/// 一条)时可交互——历史消息一律纯展示,避免翻旧账时执行过时的批量操作。
struct AgentMessageBubble: View {
    let message: AgentMessage
    let isLatest: Bool
    var onConfirm: () -> Void = {}
    var onCancelConfirm: () -> Void = {}
    var onUndo: () -> Void = {}

    @Environment(\.modelContext) private var context

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        }
    }

    /// 按 attachmentMemoryUUIDs 原有顺序查出条目;条目已被删除的 uuid 直接跳过
    /// (不阻塞气泡渲染,只是那个附件不再显示)。
    private var attachments: [MemoryItem] {
        guard !message.attachmentMemoryUUIDs.isEmpty else { return [] }
        let uuids = message.attachmentMemoryUUIDs
        let fetched = (try? context.fetch(FetchDescriptor<MemoryItem>(
            predicate: #Predicate<MemoryItem> { uuids.contains($0.uuid) }))) ?? []
        let byUUID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.uuid, $0) })
        return uuids.compactMap { byUUID[$0] }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !attachments.isEmpty {
                    ForEach(attachments, id: \.uuid) { item in
                        Label(item.title.isEmpty ? (item.originalFileName ?? "附件") : item.title,
                              systemImage: item.kind.symbol)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                if !message.content.isEmpty {
                    Text(message.content)
                }
            }
            .padding(12)
            .background(.tint, in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
            .foregroundStyle(.white)
        }
    }

    private var assistantBubble: some View {
        HStack {
            content
                .padding(12)
                .background(.fill.quaternary,
                            in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
            Spacer(minLength: 40)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            Text(message.content).font(.subheadline)
        case .confirm:
            confirmContent
        case .clarify:
            Label(message.content, systemImage: "questionmark.circle").font(.subheadline)
        case .answer:
            answerContent
        case .executed:
            executedContent
        }
    }

    private var executedContent: some View {
        HStack(spacing: 10) {
            Label(message.content, systemImage: "checkmark.circle").font(.subheadline)
            if isLatest {
                Spacer(minLength: 12)
                Button {
                    onUndo()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        }
    }

    private var confirmContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(message.content.components(separatedBy: "\n"), id: \.self) { line in
                Label(line, systemImage: icon(for: line)).font(.subheadline)
            }
            if isLatest {
                HStack {
                    Button("取消") { onCancelConfirm() }
                        .buttonStyle(.bordered)
                    Button {
                        Haptics.success()
                        onConfirm()
                    } label: {
                        Label("确认执行", systemImage: "checkmark")
                    }
                    .glassProminentButton()
                }
            }
        }
    }

    private var answerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message.content, systemImage: "sparkles").font(.subheadline)
            ForEach(message.relatedTitles, id: \.self) { title in
                Label(title, systemImage: "bookmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(for line: String) -> String {
        if line.hasPrefix("新建") { return "plus.circle" }
        if line.hasPrefix("修改") { return "pencil.circle" }
        if line.hasPrefix("完成") { return "checkmark.circle" }
        if line.hasPrefix("删除") { return "trash.circle" }
        if line.hasPrefix("收藏") { return "bookmark.circle" }
        return "circle"
    }
}
