import SwiftUI
import SwiftData

/// 已完成列表页(第二个 tab):按完成时间倒序,左滑删除。
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
                    .swipeActions {
                        Button(role: .destructive) {
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
}
