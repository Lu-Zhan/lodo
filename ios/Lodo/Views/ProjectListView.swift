import SwiftUI
import SwiftData
import LodoCore

/// 按项目分组的待办清单("要处理的项目"):一个项目一个 Section,按项目里最早
/// 一条事项的 nextRemindAt 排序(最紧急的项目排前面),没填项目的统一归到
/// "未分类"、固定殿后。行直接复用 TaskRowView,滑动完成/改期/稍等/删除都继承。
/// 不叠加 TodoListView 现有的今天/未来/全部/已完成筛选——项目是另一个独立维度,
/// v1 不在同一屏混两个筛选轴。
struct ProjectListView: View {
    private static let unclassifiedKey = "未分类"

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    private var pending: [TaskItem]

    @State private var now = Date()
    @State private var editTask: TaskItem?

    private var groups: [(project: String, tasks: [TaskItem])] {
        let dict = Dictionary(grouping: pending) { task -> String in
            let trimmed = task.project?.trimmingCharacters(in: .whitespaces) ?? ""
            return trimmed.isEmpty ? Self.unclassifiedKey : trimmed
        }
        let named = dict.filter { $0.key != Self.unclassifiedKey }
            .map { (project: $0.key, tasks: $0.value.sorted { $0.nextRemindAt < $1.nextRemindAt }) }
            .sorted { ($0.tasks.first?.nextRemindAt ?? .distantFuture)
                    < ($1.tasks.first?.nextRemindAt ?? .distantFuture) }
        var result = named
        if let bucket = dict[Self.unclassifiedKey], !bucket.isEmpty {
            result.append((Self.unclassifiedKey, bucket.sorted { $0.nextRemindAt < $1.nextRemindAt }))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if pending.isEmpty {
                    ContentUnavailableView("暂无待办事项", systemImage: "folder")
                } else {
                    List {
                        ForEach(groups, id: \.project) { group in
                            Section {
                                ForEach(group.tasks) { task in
                                    TaskRowView(task: task, now: now, onEdit: { editTask = task })
                                }
                            } header: {
                                sectionHeader(group.project, count: group.tasks.count)
                            }
                        }
                    }
                }
            }
            .navigationTitle("按项目查看")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(item: $editTask) { task in
                TaskEditView(existing: task, parsed: nil, attachment: task.attachment) { parsed in
                    TaskActions.apply(parsed, to: task, context: context)
                }
            }
            .task(id: nextWakeDate) {
                let interval = nextWakeDate.timeIntervalSinceNow + 1
                if interval > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                now = Date()
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var nextWakeDate: Date {
        pending.map(\.nextRemindAt).filter { $0 > now }.min() ?? now.addingTimeInterval(60)
    }

    private func sectionHeader(_ project: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ProjectColor.color(for: project == Self.unclassifiedKey ? nil : project))
                .frame(width: 8, height: 8)
            Text(project)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary)
        }
    }
}
