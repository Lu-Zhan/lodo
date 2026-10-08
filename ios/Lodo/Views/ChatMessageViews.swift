import SwiftUI
import SwiftData
import LodoCore

// MARK: - 气泡

struct ChatMessageBubble: View {
    let message: ChatRoomMessage
    let showsSender: Bool
    let state: ChatTimelineState
    let memberCount: Int?
    let onAnswer: ([[String]]) -> Void
    let onSummarize: () -> Void
    let onRecall: () -> Void

    @Environment(\.lodoAccent) private var lodoAccent

    var body: some View {
        switch message.kind {
        case .system:
            Text(message.content)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        case .ask:
            VStack(alignment: .leading, spacing: 3) {
                senderLine
                ChatAskBubble(message: message, state: state, memberCount: memberCount,
                              onAnswer: onAnswer, onSummarize: onSummarize)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .askAnswer:
            // 回答排在中间、小一号:它是对提问卡的回应,不是一句聊天。
            Label(message.fromMe
                  ? String(localized: "我回答了 AI 的提问", bundle: .appLanguage())
                  : String(localized: "\(message.senderName)回答了 AI 的提问", bundle: .appLanguage()),
                  systemImage: "checkmark.bubble")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .text, .ai, .card, .image, .file:
            HStack(alignment: .bottom) {
                if message.fromMe { Spacer(minLength: 48) }
                VStack(alignment: message.fromMe ? .trailing : .leading, spacing: 3) {
                    if showsSender || message.kind == .ai {
                        senderLine
                    }
                    content
                        .contextMenu { menu }
                    if message.kind == .ai, let proposal = message.proposal {
                        ChatProposalView(message: message, proposal: proposal, state: state)
                    }
                }
                if !message.fromMe { Spacer(minLength: 48) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch message.kind {
        case .card:
            if let card = message.card { ChatCardView(card: card) } else { bubble }
        case .image, .file:
            ChatAttachmentView(message: message)
        default:
            bubble
        }
    }

    @ViewBuilder
    private var menu: some View {
        if !message.content.isEmpty, message.kind == .text || message.kind == .ai {
            Button {
                Clipboard.copy(message.content)
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
        if ChatRecall.canRecall(fromMe: message.fromMe, kind: message.kind,
                                createdAt: message.createdAt, now: .now) {
            Button(role: .destructive, action: onRecall) {
                Label("撤回", systemImage: "arrow.uturn.backward")
            }
        }
    }

    @ViewBuilder
    private var senderLine: some View {
        if message.kind == .ai || message.kind == .ask {
            Label(message.fromMe
                  ? String(localized: "我的 AI", bundle: .appLanguage())
                  : String(localized: "\(message.senderName)的 AI", bundle: .appLanguage()),
                  systemImage: "sparkles")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text(message.senderName)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bubble: some View {
        let text = Text(message.content)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        if message.kind == .ai {
            // AI 的回复和「我的 AI 助手」那边同一种玻璃卡片。
            text.agentCard(padding: 0, hugsContent: true)
        } else if message.fromMe {
            text
                .foregroundStyle(lodoAccent.onFill)
                .background(lodoAccent.fill,
                            in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
        } else {
            text
                .background(.fill.tertiary,
                            in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
        }
    }
}

// MARK: - 图片 / 文件

/// 聊天里的图片(缩略图)和文件(图标 + 名字 + 大小),点了用系统 Quick Look 打开。
/// 文件还没从 iCloud 下来(或者超过 50 MB 没传)时如实说明。
private struct ChatAttachmentView: View {
    let message: ChatRoomMessage
    @State private var previewURL: URL?

    private var url: URL? {
        guard !message.filePath.isEmpty,
              let url = AppGroup.containerURL?.appending(path: message.filePath),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var body: some View {
        Button {
            previewURL = url
        } label: {
            if message.kind == .image, let url, let image = platformImage(fromFile: url) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
            } else {
                HStack(spacing: 10) {
                    Image(systemName: message.kind == .image ? "photo" : "doc.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.fileName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .foregroundStyle(.primary)
                        Text(url.map { ByteCountFormatter.string(fromByteCount: fileSize($0), countStyle: .file) }
                             ?? String(localized: "还没有下载到这台设备", bundle: .appLanguage()))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: 260, alignment: .leading)
                .background(.fill.tertiary,
                            in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
            }
        }
        .pressableCard()
        .disabled(url == nil)
        .quickLookPreview($previewURL)
        .accessibilityLabel(message.kind == .image ? Text("图片") : Text(message.fileName))
    }

    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private func platformImage(fromFile url: URL) -> Image? {
        #if os(iOS)
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #else
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #endif
    }
}

// MARK: - 群里的提问

/// AI 在群里提的问题:还没答 → 可作答的提问卡(没有"跳过");答过了/已经汇总 → 只读卡,
/// 写着谁答了几个、我的选择;提问的人(那台设备)可以不等大家答完先「现在汇总」。
private struct ChatAskBubble: View {
    let message: ChatRoomMessage
    let state: ChatTimelineState
    let memberCount: Int?
    let onAnswer: ([[String]]) -> Void
    let onSummarize: () -> Void

    var body: some View {
        Group {
            if let snapshot = message.ask {
                let closed = state.isClosed(message.uuid)
                if !closed, state.myAnswer(message.uuid) == nil {
                    AgentAskCard(snapshot: snapshot, onSubmit: onAnswer, onCancel: {}, allowsCancel: false)
                } else {
                    record(snapshot, closed: closed)
                }
            }
        }
        // 报位置给时间线:滚出屏幕时输入栏上方挂「问题:… ›」。
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ChatAskFrameKey.self,
                    value: [message.uuid: geometry.frame(in: .named(ChatAskFrameKey.space))])
            }
        }
    }

    private func record(_ snapshot: AgentAskSnapshot, closed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(snapshot.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 3) {
                    Text(question.question)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let mine = state.myAnswer(message.uuid), index < mine.count {
                        Text(mine[index].joined(separator: "、"))
                            .font(.body.weight(.medium))
                    }
                }
            }
            HStack(spacing: 8) {
                let answered = state.respondents(message.uuid).count
                Label(memberCount.map { String(localized: "\(answered)/\($0) 人已回答", bundle: .appLanguage()) }
                      ?? String(localized: "\(answered) 人已回答", bundle: .appLanguage()),
                      systemImage: closed ? "checkmark.circle.fill" : "person.2")
                    .font(.footnote)
                    .foregroundStyle(closed ? AnyShapeStyle(LodoColor.positive) : AnyShapeStyle(.secondary))
                if closed {
                    Text("已汇总").font(.footnote).foregroundStyle(LodoColor.positive)
                }
                Spacer(minLength: 0)
                if message.fromMe, !closed, answered > 0 {
                    Button("现在汇总", action: onSummarize)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .font(.footnote)
                }
            }
        }
        .agentCard(padding: 14)
    }
}

// MARK: - 内容卡片

/// 聊天里分享的内容卡片。按钮按"这台设备上有没有这份内容"分:
/// 有 → 「打开」进到那一页;没有但它是一份共享(带链接)→ 「加入共享」;
/// 都没有 → 只能「查看内容」看分享那一刻的快照。
private struct ChatCardView: View {
    let card: ChatCard

    @Environment(\.modelContext) private var context
    @Environment(\.itemNavigator) private var navigator
    @Environment(\.openURL) private var openURL
    @State private var showsBody = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: card.reference.kind.symbol)
                    .foregroundStyle(.tint)
                Text(card.reference.kind.displayTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if card.shareURL != nil {
                    Label("共享中", systemImage: "person.2.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            Text(card.reference.title)
                .font(.headline)
                .lineLimit(2)
            let preview = card.preview()
            if !preview.isEmpty {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            HStack(spacing: 8) {
                if let destination = localDestination {
                    Button("打开") { navigator?.open(destination) }
                        .buttonStyle(.borderedProminent)
                } else if let raw = card.shareURL, let url = URL(string: raw) {
                    Button("加入共享") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                }
                Button("查看内容") { showsBody = true }
                    .buttonStyle(.bordered)
            }
            .font(.subheadline)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.fill.tertiary,
                    in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
        .sheet(isPresented: $showsBody) {
            ChatCardBodySheet(card: card)
        }
    }

    /// 这台设备上有这份内容时去哪儿打开它。只认能落到具体页面的几类;
    /// 任务、人脉、菜单这些没有对应的跳转目标,只给「查看内容」。
    private var localDestination: AppDestination? {
        guard navigator != nil else { return nil }
        let id = card.reference.id
        switch card.reference.kind {
        case .trip:
            return exists(FetchDescriptor<TravelTrip>(predicate: #Predicate { $0.uuid == id })) ? .trip(id) : nil
        case .asset:
            return exists(FetchDescriptor<MemoryItem>(predicate: #Predicate { $0.uuid == id })) ? .assets : nil
        case .finance:
            return exists(FetchDescriptor<FinanceEntry>(predicate: #Predicate { $0.uuid == id })) ? .assets : nil
        case .countdown:
            return exists(FetchDescriptor<CountdownEvent>(predicate: #Predicate { $0.uuid == id })) ? .countdown : nil
        case .news:
            return exists(FetchDescriptor<NewsArticle>(predicate: #Predicate { $0.uuid == id })) ? .news : nil
        case .task, .contact, .menu:
            return nil
        }
    }

    private func exists<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) -> Bool {
        ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }
}

/// 卡片的完整快照。
private struct ChatCardBodySheet: View {
    let card: ChatCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(card.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(card.reference.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

extension AgentReferenceKind {
    /// 界面上的种类名(随应用语言)。`promptLabel` 是喂给模型的,别混用。
    var displayTitle: LocalizedStringKey {
        switch self {
        case .task: return "任务"
        case .countdown: return "倒数日"
        case .trip: return "旅行"
        case .asset: return "资产"
        case .finance: return "收支"
        case .contact: return "人脉"
        case .menu: return "菜单"
        case .news: return "新闻"
        }
    }
}


enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
