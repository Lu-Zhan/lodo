import SwiftUI
import SwiftData
import LodoCore

/// 已完成列表页(第二个 tab):按完成时间倒序;右滑恢复未完成,左滑删除。
struct DoneListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.nextRemindAt) private var allTasks: [TaskItem]

    @AppStorage(AppSettings.insightEnabledKey) private var insightEnabled = true
    @State private var insight: String?

    private static let insightWeekKey = "insightWeek"
    private static let insightTextKey = "insightText"

    private var done: [TaskItem] {
        allTasks.filter { $0.status == .done }
            .sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                if insightEnabled, let insight {
                    Section("本周洞察") {
                        Label(insight, systemImage: "sparkles")
                            .font(.subheadline)
                    }
                }
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
            .task { await loadInsight() }
        }
    }

    /// 每周完成洞察:本地统计近 7 天完成情况,AI 只负责说成一句正向的话;
    /// 同一 ISO 周缓存,失败静默不显示。
    private func loadInsight() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-insight") {
            insight = "这周完成 12 件,比上周多 3 件;晚上 9 点后你的完成率最高,阅读类放晚上试试。"
            return
        }
        #endif
        guard insightEnabled, KeychainHelper.apiKey != nil else { return }
        let calendar = Calendar.current
        let stamp = "\(calendar.component(.yearForWeekOfYear, from: Date()))-" +
            "\(calendar.component(.weekOfYear, from: Date()))"
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.insightWeekKey) == stamp,
           let cached = defaults.string(forKey: Self.insightTextKey) {
            insight = cached
            return
        }
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let twoWeeksAgo = now.addingTimeInterval(-14 * 86400)
        let recent = done.filter { ($0.doneAt ?? .distantPast) > weekAgo }
        guard !recent.isEmpty else { return }
        let previous = done.filter {
            let doneAt = $0.doneAt ?? .distantPast
            return doneAt > twoWeeksAgo && doneAt <= weekAgo
        }
        var stats = "近 7 天完成 \(recent.count) 件(再往前 7 天完成 \(previous.count) 件)"
        let hours = recent.compactMap { task in
            task.doneAt.map { calendar.component(.hour, from: $0) }
        }
        if let topHour = Dictionary(grouping: hours, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key {
            stats += ";最常完成时段:\(topHour) 点左右"
        }
        stats += ";最近完成:" + recent.prefix(5).map(\.title).joined(separator: "、")
        guard let text = try? await DeepSeekClient.weeklyInsight(stats: stats) else { return }
        defaults.set(stamp, forKey: Self.insightWeekKey)
        defaults.set(text, forKey: Self.insightTextKey)
        insight = text
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
