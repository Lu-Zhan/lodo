import SwiftUI
import SwiftData
import LodoCore

/// Watch 首页:待办列表 + 完成/稍等 + 语音入口。
/// 不含手动编辑表单——按用户要求,增删改一律走语音 + 一键确认(WatchAgentView)。
struct WatchTodoListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    private var pending: [TaskItem]

    @State private var showAgent = false

    var body: some View {
        NavigationStack {
            List {
                if pending.isEmpty {
                    ContentUnavailableView("暂无待办", systemImage: "checkmark.circle")
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
                        Button("稍等") { snooze(task) }.tint(.orange)
                    }
                }
            }
            .navigationTitle("Lodo")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAgent = true
                    } label: {
                        Image(systemName: "waveform")
                    }
                    .accessibilityLabel("语音助手")
                }
            }
            .sheet(isPresented: $showAgent) {
                WatchAgentView(pending: pending, context: context)
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

#Preview {
    WatchTodoListView()
        .modelContainer(for: TaskItem.self, inMemory: true)
}
