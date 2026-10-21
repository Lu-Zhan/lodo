import SwiftUI
import SwiftData
import LodoCore

/// Watch 首页:只看今天——今天到期的任务、今天放进收集的事(完成/稍等),
/// 和今天记下的记忆(`WatchToday` 定判据),外加语音入口(右下角麦克风,点了直接开始听)。
/// 不含手动编辑表单——按用户要求,增删改一律走语音 + 一键确认(WatchAgentView)。
/// 表盘上的 Lodo 快捷按钮(`LodoWatchWidget`)打开 `lodowatch://listen`,同样直接开始听。
struct WatchTodoListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    private var pending: [TaskItem]

    /// 每次唤起一个新值:表盘按钮在助手已经开着时再点一次,也会换成新的一轮重新开始听。
    @State private var agentSession: WatchAgentSession?
    /// "今天"的基准。过 0 点、回前台时刷新,否则手表一直亮着的那页会停在昨天。
    @State private var now = Date.now

    /// 待办里和提醒有关的内容。它一变(含 CloudKit 从手机同步过来的新增/改期/完成/删除/改成收集)
    /// 就重新对账一遍通知链——原来只在首页第一次出现时排一次,之后手机上的改动手表上不会重排。
    private var reminderKey: [String] {
        pending.map { "\($0.uuid.uuidString)|\($0.remindAt.timeIntervalSince1970)|\($0.nextRemindAt.timeIntervalSince1970)|\($0.title)" }
    }

    private var todayTasks: [TaskItem] {
        pending.filter {
            WatchToday.includesTask(isInbox: $0.isInbox, createdAt: $0.createdAt, remindAt: $0.remindAt,
                                    now: now)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if WatchDatabase.isTemporary {
                    Text("数据库打不开,这次的改动不会保存。重启手表上的 Lodo 再试。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Section("今天") {
                    if todayTasks.isEmpty {
                        Text("今天没有任务").foregroundStyle(.secondary)
                    }
                    ForEach(todayTasks) { task in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.headline)
                            Text(task.caption).font(.caption2).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            Button { complete(task) } label: { Label("完成", systemImage: "checkmark") }.tint(.green)
                        }
                        .swipeActions(edge: .leading) {
                            // 收集里的事项没有提醒,不给稍等。
                            if !task.isInbox {
                                Button { snooze(task) } label: { Label("稍等", systemImage: "clock") }.tint(.orange)
                            }
                        }
                    }
                }
                WatchTodayMemoriesSection(dayStart: Calendar.current.startOfDay(for: now), now: now)
            }
            .navigationTitle("Lodo")
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button {
                        agentSession = WatchAgentSession()
                    } label: {
                        Image(systemName: "mic.fill")
                    }
                    .tint(Color.accentColor)
                    .accessibilityLabel("语音助手")
                }
            }
            .sheet(item: $agentSession) { _ in
                WatchAgentView()
            }
            .onOpenURL { url in
                guard WatchAgentSession.isListenURL(url) else { return }
                agentSession = WatchAgentSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                now = .now
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                now = .now
                WatchNotificationManager.shared.refreshAll()
            }
            // 停在首页跨过 0 点时主动换天:NSCalendarDayChanged 不保证准时到。
            .task(id: Calendar.current.startOfDay(for: now)) {
                let wait = WatchToday.nextDayStart(after: now).timeIntervalSinceNow
                try? await Task.sleep(for: .seconds(max(wait, 0) + 1))
                if !Task.isCancelled { now = .now }
            }
            .task {
                WatchNotificationManager.shared.configure(container: context.container)
            }
            // 第一次出现时排一次;之后待办一变就合并 0.5 秒再对账(同步常常一次进来好几条)。
            .task(id: reminderKey) {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                WatchNotificationManager.shared.refreshAll()
            }
        }
    }

    private func complete(_ task: TaskItem) {
        WatchNotificationManager.shared.complete(task, context: context)
    }

    private func snooze(_ task: TaskItem) {
        WatchNotificationManager.shared.snooze(task, context: context)
    }
}

/// 「今天的记忆」:今天记下的条目,点进去看全文。还没整理出标题的(刚在手表上说的)
/// 标题退回原文开头——那是用户自己刚说的话;健康类按标签不在这里显示(`WatchToday`)。按今天 0 点起查,
/// 过 0 点时外面换一个 dayStart,@Query 跟着重建。
private struct WatchTodayMemoriesSection: View {
    @Query private var items: [MemoryItem]
    private let now: Date

    init(dayStart: Date, now: Date) {
        let dayEnd = WatchToday.nextDayStart(after: dayStart)
        _items = Query(filter: #Predicate<MemoryItem> { $0.createdAt >= dayStart && $0.createdAt < dayEnd },
                       sort: \MemoryItem.createdAt, order: .reverse)
        self.now = now
    }

    private var visible: [MemoryItem] {
        items.filter {
            WatchToday.includesMemory(createdAt: $0.createdAt, tags: $0.tags, now: now)
        }
    }

    var body: some View {
        Section("今天的记忆") {
            if visible.isEmpty {
                Text("今天还没有记忆").foregroundStyle(.secondary)
            }
            ForEach(visible) { item in
                NavigationLink {
                    WatchMemoryDetailView(item: item)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.watchTitle).font(.headline).lineLimit(2)
                        Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct WatchMemoryDetailView: View {
    let item: MemoryItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.watchTitle).font(.headline)
                if item.status == .processing {
                    Text("整理中…").font(.caption2).foregroundStyle(.secondary)
                }
                let body = item.summary.isEmpty ? item.sourceText : item.summary
                if !body.isEmpty, body != item.watchTitle {
                    Text(body).font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension MemoryItem {
    /// 还没整理出标题时(手表上刚记的、手机还在整理)退回摘要或原文开头。
    var watchTitle: String {
        for text in [title, summary, sourceText] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(60)) }
        }
        return "记忆"
    }
}

/// 一次语音助手会话(sheet 盖在首页上,左上角系统关闭键退出)。
struct WatchAgentSession: Identifiable {
    let id = UUID()

    static let listenURL = URL(string: "lodowatch://listen")!

    static func isListenURL(_ url: URL) -> Bool {
        url.scheme == listenURL.scheme && url.host == listenURL.host
    }
}

#Preview {
    WatchTodoListView()
        .modelContainer(for: [TaskItem.self, MemoryItem.self], inMemory: true)
}
