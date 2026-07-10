import SwiftUI
import SwiftData
import LodoCore

/// 已完成列表页(第二个 tab):按完成时间倒序;右滑恢复未完成,左滑删除。
struct DoneListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.nextRemindAt) private var allTasks: [TaskItem]

    private var done: [TaskItem] {
        allTasks.filter { $0.status == .done }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if done.isEmpty {
                    ContentUnavailableView("还没有完成的事项", systemImage: "tray")
                }
                ForEach(done) { task in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).strikethrough()
                        if let doneAt = task.doneAt {
                            Text("完成于 \(TaskItem.format(doneAt))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    // 右滑(满滑)恢复为未完成
                    .swipeActions(edge: .leading) {
                        Button {
                            Haptics.success()
                            restore(task)
                        } label: {
                            Label("未完成", systemImage: "arrow.uturn.backward")
                        }
                        .tint(.orange)
                    }
                    // 左滑(满滑)删除
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Haptics.impact()
                            context.delete(task)
                            try? context.save()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("已完成")
        }
    }

    /// 恢复为待办:回到 start 阶段,提醒时间取原定时间(已过期会直接进到期卡)。
    private func restore(_ task: TaskItem) {
        task.statusRaw = TaskStatus.pending.rawValue
        task.phaseRaw = TaskPhase.start.rawValue
        task.doneAt = nil
        task.nextRemindAt = task.remindAt
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
    }
}
