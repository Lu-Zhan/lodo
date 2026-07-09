import SwiftUI
import SwiftData
import EventKit

/// 系统「提醒事项」连接页:权限、系统待办列表与导入、lodo 事项导出。
struct RemindersView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.nextRemindAt) private var allTasks: [TaskItem]
    @State private var bridge = RemindersBridge.shared

    private var importedIDs: Set<String> {
        Set(allTasks.compactMap(\.ekIdentifier))
    }

    private var pendingTasks: [TaskItem] {
        allTasks.filter { $0.status == .pending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if bridge.hasAccess {
                    connectedList
                } else {
                    ContentUnavailableView {
                        Label("未连接系统提醒事项", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text(bridge.authStatus == .denied
                             ? "访问已被拒绝,请到系统设置中为 lodo 开启提醒事项权限。"
                             : "连接后可以把系统待办导入 lodo,也可以把 lodo 事项导出到系统提醒事项。")
                    } actions: {
                        if bridge.authStatus != .denied {
                            Button("连接提醒事项") {
                                Task { await bridge.requestAccess() }
                            }
                            .glassProminentButton()
                        }
                    }
                }
            }
            .navigationTitle("提醒事项")
            .toolbar {
                if bridge.hasAccess {
                    ToolbarItem {
                        Button {
                            Task { await bridge.refresh() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .task {
                if bridge.hasAccess { await bridge.refresh() }
            }
        }
    }

    private var connectedList: some View {
        List {
            if let error = bridge.lastError {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            Section {
                if bridge.systemReminders.isEmpty {
                    Text("系统里没有未完成的提醒事项").foregroundStyle(.secondary)
                }
                ForEach(bridge.systemReminders, id: \.calendarItemIdentifier) { reminder in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reminder.title ?? "未命名")
                            if let due = reminder.dueDateComponents,
                               let date = Calendar.current.date(from: due) {
                                Text(TaskItem.format(date))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if importedIDs.contains(reminder.calendarItemIdentifier) {
                            Label("已导入", systemImage: "checkmark")
                                .labelStyle(.titleAndIcon)
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Button("导入") {
                                bridge.importReminder(reminder, into: context)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } header: {
                Text("系统提醒事项(未完成)")
            } footer: {
                Text("导入后由 lodo 接管纠缠式提醒。")
            }

            Section {
                if pendingTasks.isEmpty {
                    Text("lodo 里暂无待办").foregroundStyle(.secondary)
                }
                ForEach(pendingTasks) { task in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                            Text(task.caption).font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(task.ekIdentifier == nil ? "导出" : "更新") {
                            bridge.export(task)
                            try? context.save()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: {
                Text("导出 lodo 事项")
            } footer: {
                Text("写入系统提醒事项默认列表;重复事项只导出下一次发生的时间。")
            }
        }
    }
}
