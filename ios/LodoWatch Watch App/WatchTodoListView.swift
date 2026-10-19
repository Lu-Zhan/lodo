import SwiftUI
import SwiftData
import LodoCore

/// Watch 首页:待办列表 + 完成/稍等 + 语音入口(右下角麦克风,点了直接开始听)。
/// 不含手动编辑表单——按用户要求,增删改一律走语音 + 一键确认(WatchAgentView)。
/// 表盘上的 Lodo 快捷按钮(`LodoWatchWidget`)打开 `lodowatch://listen`,同样直接开始听。
struct WatchTodoListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    private var pending: [TaskItem]

    /// 每次唤起一个新值:表盘按钮在助手已经开着时再点一次,也会换成新的一轮重新开始听。
    @State private var agentSession: WatchAgentSession?

    var body: some View {
        NavigationStack {
            List {
                if pending.isEmpty {
                    ContentUnavailableView("暂无任务", systemImage: "checkmark.circle")
                }
                ForEach(pending) { task in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).font(.headline)
                        Text(task.caption).font(.caption2).foregroundStyle(.secondary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("完成") { complete(task) }.tint(.green)
                    }
                    .swipeActions(edge: .leading) {
                        // 收集里的事项没有提醒,不给稍等。
                        if !task.isInbox {
                            Button("稍等") { snooze(task) }.tint(.orange)
                        }
                    }
                }
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
            .task {
                WatchNotificationManager.shared.configure(container: context.container)
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
