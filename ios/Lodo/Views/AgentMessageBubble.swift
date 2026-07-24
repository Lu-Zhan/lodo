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
    var onMemorizeSuggestion: () -> Void = {}
    var onTaskProposalConfirm: () -> Void = {}
    var onTaskProposalCancel: () -> Void = {}
    var onTaskProposalTap: () -> Void = {}

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

    /// memoryResult 消息指向的条目;查不到(已被删除)时卡片自然不渲染。
    private var resultMemoryItem: MemoryItem? {
        guard let uuid = message.resultMemoryUUID else { return nil }
        return try? context.fetch(FetchDescriptor<MemoryItem>(
            predicate: #Predicate<MemoryItem> { $0.uuid == uuid })).first
    }

    /// taskProposal/taskResult 消息的字段快照;解码失败(理论上不会发生)时
    /// 调用方退化显示 message.content。
    private var taskSnapshot: AgentTaskSnapshot? {
        guard let data = message.taskSnapshotData else { return nil }
        return try? JSONDecoder().decode(AgentTaskSnapshot.self, from: data)
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
        case .memorizeSuggestion:
            memorizeSuggestionContent
        case .taskProposal:
            taskProposalContent
        case .taskResult:
            taskResultContent
        case .memoryResult:
            memoryResultContent
        }
    }

    @ViewBuilder
    private var taskProposalContent: some View {
        if let taskSnapshot {
            VStack(alignment: .leading, spacing: 10) {
                AgentTaskCard(snapshot: taskSnapshot, onTap: isLatest ? onTaskProposalTap : nil)
                if isLatest {
                    HStack {
                        Button("取消") { onTaskProposalCancel() }
                            .buttonStyle(.bordered)
                        Button {
                            Haptics.success()
                            onTaskProposalConfirm()
                        } label: {
                            Label(taskSnapshot.existingUUID == nil ? "确认新建" : "确认修改",
                                  systemImage: "checkmark")
                        }
                        .glassProminentButton()
                    }
                }
            }
        } else {
            Text(message.content).font(.subheadline)
        }
    }

    @ViewBuilder
    private var taskResultContent: some View {
        if let taskSnapshot {
            VStack(alignment: .leading, spacing: 10) {
                Text(message.content).font(.subheadline)
                AgentTaskCard(snapshot: taskSnapshot, onTap: nil)
            }
        } else {
            Text(message.content).font(.subheadline)
        }
    }

    @ViewBuilder
    private var memoryResultContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message.content).font(.subheadline)
            if let item = resultMemoryItem {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.kind.symbol)
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title.isEmpty ? (item.originalFileName ?? "正在整理…") : item.title)
                        if !item.summary.isEmpty {
                            Text(item.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassBackground(RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
            }
        }
    }

    private var memorizeSuggestionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message.content, systemImage: "bookmark.circle").font(.subheadline)
            if isLatest {
                Button {
                    Haptics.success()
                    onMemorizeSuggestion()
                } label: {
                    Label("收藏这条", systemImage: "bookmark")
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
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

/// taskProposal/taskResult 共用的事项卡片:标题 + caption,视觉上贴近
/// TaskRowView 但不带 swipe actions。onTap 为 nil 时不可点(结果卡片是只读
/// 历史,不像提案卡片那样能跳去表单微调)。
private struct AgentTaskCard: View {
    let snapshot: AgentTaskSnapshot
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.parsed.title)
                Text(snapshot.parsed.caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassBackground(RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }
}
