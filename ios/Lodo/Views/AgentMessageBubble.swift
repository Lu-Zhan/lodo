import SwiftUI
import SwiftData
import LodoCore

/// 结构化消息卡片(confirm/answer/executed/memorizeSuggestion)统一的卡片容器语言,
/// 和 askContent/AgentTaskCard/memoryResultContent 已有的卡片视觉一致——纯文本 .text
/// 消息不套这层,保留"对话文字 vs. 结构化内容"的区分(参考 Claude 对话里散文与
/// 工具/卡片类内容的分野)。
private extension View {
    func agentCard() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quaternary,
                        in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
    }
}

/// 一条消息的气泡渲染;confirm 的按钮只在 isLatest(这条是当前 thread 最新
/// 一条)时可交互——历史消息一律纯展示,避免翻旧账时执行过时的批量操作。
struct AgentMessageBubble: View {
    let message: AgentMessage
    let isLatest: Bool
    var onConfirm: () -> Void = {}
    var onCancelConfirm: () -> Void = {}
    var onUndo: () -> Void = {}
    var onMemorizeSuggestion: () -> Void = {}
    var onCancelMemoryResult: () -> Void = {}
    var onToggleCreatedTask: () -> Void = {}
    var onTaskProposalConfirm: () -> Void = {}
    var onTaskProposalCancel: () -> Void = {}
    var onTaskProposalTap: () -> Void = {}
    var onAskSubmit: ([[String]]) -> Void = { _ in }
    var onAskCancel: () -> Void = {}
    var onCopy: () -> Void = {}
    var onQuote: () -> Void = {}
    /// 仅用户气泡的长按菜单会用到,AI 气泡不传。
    var onEdit: () -> Void = {}
    /// 打字机动画的分界线:createdAt 早于这个时间的 .text 回复直接整段显示
    /// (对话历史滚回视野时不重播),晚于它的才当作"这次会话里刚收到的新回复"
    /// 播放逐字动画。默认 .distantPast——不传就等于永远不播。
    var typingBaseline: Date = .distantPast

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

    /// ask/askResult 消息的题目与答案;同样解码失败时退化显示 message.content。
    private var askSnapshot: AgentAskSnapshot? {
        guard let data = message.askSnapshotData else { return nil }
        return try? JSONDecoder().decode(AgentAskSnapshot.self, from: data)
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
                if let quoted = message.quotedContent, !quoted.isEmpty {
                    Label(quoted, systemImage: "quote.bubble")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if !message.content.isEmpty {
                    Text(message.content)
                }
            }
            .padding(12)
            // 自己发出的气泡填主题色,AI 那侧保持原来的中性底——两边一眼分得开。
            // 附件名/引用摘要在实色底上跟着用白字,不再用 .secondary(蓝底上发灰)。
            .background(Color.accentColor,
                        in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
            .foregroundStyle(.white)
            .contextMenu {
                Button { onCopy() } label: { Label("复制", systemImage: "doc.on.doc") }
                Button { onQuote() } label: { Label("引用", systemImage: "quote.bubble") }
                Button { onEdit() } label: { Label("修改", systemImage: "pencil") }
            }
        }
    }

    @ViewBuilder
    private var assistantBubble: some View {
        HStack {
            if hasCopyableContent {
                content.contextMenu {
                    Button { onCopy() } label: { Label("复制", systemImage: "doc.on.doc") }
                    Button { onQuote() } label: { Label("引用", systemImage: "quote.bubble") }
                }
            } else {
                content
            }
            // 询问卡/记录卡本身就是一整块卡片,铺满消息列表的宽度(左右留白对称);
            // 其余气泡保留右侧那 40pt 让位,和右对齐的用户气泡区分开。
            if !fillsWidth { Spacer(minLength: 40) }
        }
    }

    private var hasCopyableContent: Bool {
        !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fillsWidth: Bool {
        message.kind == .ask || message.kind == .askResult || message.kind == .tripPlan
            || message.kind == .tripEdit
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .text:
            TypewriterText(fullText: message.content, animates: message.createdAt > typingBaseline)
                .font(.body)
                .textSelection(.enabled)
        case .confirm:
            confirmContent
        case .ask:
            askContent
        case .askResult:
            askResultContent
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
        case .tripPlan:
            AgentTripPlanCard(message: message, isLatest: isLatest)
        case .tripEdit:
            AgentTripEditCard(message: message)
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
            Text(message.content).font(.body)
        }
    }

    /// 待回答的询问卡:只有"当前 thread 最新一条"才可交互,历史里那些没答完的
    /// 退化成只读记录卡(和 confirm/taskProposal 的按钮只在最新一条生效同一个道理)。
    @ViewBuilder
    private var askContent: some View {
        if let askSnapshot {
            if isLatest {
                AgentAskCard(snapshot: askSnapshot, onSubmit: onAskSubmit, onCancel: onAskCancel)
            } else {
                AgentAskRecordCard(snapshot: askSnapshot)
            }
        } else {
            Text(message.content).font(.body)
        }
    }

    @ViewBuilder
    private var askResultContent: some View {
        if let askSnapshot {
            AgentAskRecordCard(snapshot: askSnapshot)
        } else {
            Text(message.content).font(.body)
        }
    }

    /// 新建和修改都是先落库再报告(见 route()),这张卡是事后反悔的入口,但两者
    /// 形态有意不同:
    /// - **新建**:整张卡就是个开关,最左边一枚蓝色对号表示"这条有效",点一下删掉
    ///   事项、对号变成灰色 ✕,再点一下按同一份快照重新建回来。开关不限"最新一条"
    ///   ——它动的就是卡片上写着的那一条,翻旧账也不会误伤别的东西(不像"撤销上
    ///   一批"那样依赖当前上下文)。
    /// - **修改**:右边一颗撤销箭头,语义是"改回原样",走 lastUndo 快照,因此仍然
    ///   只在最新一条可点。
    /// 老对话里点"确认新建"产生的结果卡 createdUUID 是 nil,两种按钮都不带
    /// (那种流程本来就已经确认过一次)。
    @ViewBuilder
    private var taskResultContent: some View {
        if let taskSnapshot {
            VStack(alignment: .leading, spacing: 10) {
                Text(taskSnapshot.createdRemoved == true ? "已取消新建" : message.content)
                    .font(.body)
                if taskSnapshot.createdUUID != nil {
                    AgentTaskCard(snapshot: taskSnapshot,
                                  isActive: taskSnapshot.isCreatedActive,
                                  onTap: onToggleCreatedTask)
                } else if isLatest, taskSnapshot.existingUUID != nil {
                    HStack(spacing: 8) {
                        AgentTaskCard(snapshot: taskSnapshot, onTap: nil)
                        Button {
                            onUndo()
                        } label: {
                            Label("撤销", systemImage: "arrow.uturn.backward")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("撤销")
                    }
                } else {
                    AgentTaskCard(snapshot: taskSnapshot, onTap: nil)
                }
            }
        } else {
            Text(message.content).font(.body)
        }
    }

    @ViewBuilder
    private var memoryResultContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let item = resultMemoryItem, item.isAutoRecorded {
                // AI 主动记下的重点事实(auto_memorize)和用户主动收藏(memorize/
                // suggestMemorize 确认)共用这张卡片,但要让用户一眼看出这条是
                // AI 自己记的、不是自己刚收藏的——用 sparkles 图标 + 不同文案区分。
                Label(message.content, systemImage: "sparkles").font(.body)
            } else {
                Text(message.content).font(.body)
            }
            if let item = resultMemoryItem {
                HStack(spacing: 8) {
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
                    .glassBackground(
                        RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
                    // 收藏/自动记录也是默认就存,这颗 ✕ 是事后反悔的入口,
                    // 和新建待办那张卡同一个位置、同一个图标。
                    if isLatest {
                        Button {
                            onCancelMemoryResult()
                        } label: {
                            Label("取消", systemImage: "xmark").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("取消收藏")
                    }
                }
            }
        }
    }

    private var memorizeSuggestionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message.content, systemImage: "bookmark.circle").font(.body)
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
        .agentCard()
    }

    private var executedContent: some View {
        HStack(spacing: 10) {
            Label(message.content, systemImage: "checkmark.circle").font(.body)
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
        .agentCard()
    }

    private var confirmContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(message.content.components(separatedBy: "\n"), id: \.self) { line in
                Label(line, systemImage: icon(for: line)).font(.body)
            }
            if isLatest {
                HStack {
                    Button("取消") { onCancelConfirm() }
                        .buttonStyle(.bordered)
                    Button {
                        hasDestructiveLine ? Haptics.warning() : Haptics.success()
                        onConfirm()
                    } label: {
                        Label("确认执行", systemImage: "checkmark")
                    }
                    .glassProminentButton()
                }
            }
        }
        .agentCard()
    }

    /// 批量操作里混了"删除"时,确认按钮给更慎重的 warning 触感,而不是和纯新建/
    /// 修改一样的 success——与下面 icon(for:) 用同一套前缀判断。
    private var hasDestructiveLine: Bool {
        message.content.components(separatedBy: "\n").contains { $0.hasPrefix("删除") }
    }

    private var answerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message.content, systemImage: "sparkles").font(.body)
            ForEach(message.relatedTitles, id: \.self) { title in
                Label(title, systemImage: "bookmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .agentCard()
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

/// 尽量把助手的纯文本渲染成 Markdown(粗体/斜体/行内代码/链接等)——DeepSeek
/// 输出不保证是合法 Markdown,只解析行内语法(不识别标题/列表等块级语法,
/// 避免一句话开头恰好是 "#"/"-" 被误判成块级结构),解析失败就原样退化成
/// 字面文本,不会丢内容或崩溃。TypewriterText 逐字动画期间也用这个解析
/// 逐段增长的前缀——中途撞上没闭合的 Markdown 语法会短暂显示原始符号,
/// 下一个字补上后自然纠正,是打字机效果本身能接受的过渡态。
private func markdownText(_ raw: String) -> Text {
    if let attributed = try? AttributedString(
        markdown: raw,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
        return Text(attributed)
    }
    return Text(raw)
}

/// AI 纯文字回复的打字机效果:animates 为 true 时逐字显示 + 每字一次轻触振动,
/// 为 false 时直接整段显示(历史消息滚回视野走这条路,不重播动画)。
/// 用 Character(不是 UTF8 字节)计数逐字前进,emoji/组合字符也不会切断。
private struct TypewriterText: View {
    let fullText: String
    let animates: Bool

    @State private var revealedCount = 0

    private var characters: [Character] { Array(fullText) }

    var body: some View {
        Group {
            if animates {
                markdownText(String(characters.prefix(revealedCount)))
            } else {
                markdownText(fullText)
            }
        }
        .task(id: fullText) {
            guard animates else { return }
            revealedCount = 0
            for _ in characters {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 28_000_000)
                revealedCount += 1
                Haptics.tick()
            }
        }
    }
}

/// taskProposal/taskResult 共用的事项卡片:标题 + caption,视觉上贴近
/// TaskRowView 但不带 swipe actions。onTap 为 nil 时不可点(只读历史,不像
/// 提案卡片/新建开关那样能点)。
/// isActive 非 nil 时最左边多一枚状态图标:蓝色对号 = 这条事项有效,灰色 ✕ =
/// 已被点掉。**只读态是靠 .disabled 变灰的**,所以带状态图标那种(可点)标题
/// 是正常的主色黑字,不会被 disabled 洗淡。
private struct AgentTaskCard: View {
    let snapshot: AgentTaskSnapshot
    var isActive: Bool?
    var onTap: (() -> Void)?

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                if let isActive {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor)
                                                  : AnyShapeStyle(.secondary))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.parsed.title)
                        .foregroundStyle(.primary)
                    Text(snapshot.parsed.caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassBackground(RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
        .accessibilityLabel(isActive == nil ? snapshot.parsed.title
                            : (isActive == true ? "已新建:\(snapshot.parsed.title),点两下取消"
                                                : "已取消:\(snapshot.parsed.title),点两下重新新建"))
    }
}
