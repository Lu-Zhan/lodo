import SwiftUI
import LodoCore

/// 待办行:标题+说明,到期未处理的标红并带"该开始了/完成了吗"提示,滑动
/// 操作换成完成+改期+稍等;没到期的完成+删除。今天/未来/全部三个筛选态
/// (TodoListView)和总览 tab(OverviewView)共用同一份实现。改期候选/loading/
/// 错误是这一行自己的 @State,互相独立、互不干扰(SwiftData 的 @Model 天然
/// Identifiable,ForEach 按 persistentModelID 走,不会因为筛选态切换而错位)。
struct TaskRowView: View {
    let task: TaskItem
    let now: Date
    var onEdit: () -> Void
    /// 完成时命中耗时采样条件,把 (title, planned) 交给调用方排队展示
    /// (各自维护自己的 askDurationQueue,见 TodoListView/OverviewView)。
    var onAskDuration: (String, Int) -> Void = { _, _ in }

    @Environment(\.modelContext) private var context
    @State private var rescheduleLoading = false
    @State private var rescheduleCandidates: [(label: String, date: Date)]?
    @State private var rescheduleError: String?
    @State private var rescheduleTask: Task<Void, Never>?

    private var overdue: Bool { task.nextRemindAt <= now }

    private var dueCaption: String {
        if task.phase == .end { return "时间到 — 完成了吗?" }
        if task.durationMinutes > 0 { return "\(task.caption) — 该开始了!" }
        return task.caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(task.title)
                        if overdue, rescheduleLoading {
                            Spacer()
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("正在改期")
                        }
                    }
                    Text(overdue ? dueCaption : task.caption)
                        .font(.footnote)
                        .foregroundStyle(overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            .buttonStyle(.plain)
            if overdue, let rescheduleCandidates {
                HorizontalChipRow {
                    ForEach(rescheduleCandidates, id: \.label) { candidate in
                        Button(candidate.label) {
                            applyReschedule(candidate.date)
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                        .tint(.accentColor)
                    }
                    Button {
                        withAnimation(.snappy) { self.rescheduleCandidates = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    #if os(iOS)
                    .hoverEffect(.highlight)
                    #endif
                    .accessibilityLabel("收起改期候选")
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
            if let rescheduleError {
                Text(rescheduleError).font(.caption2).foregroundStyle(.red)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                Haptics.success()
                complete()
            } label: {
                Label(task.phase == .start && task.durationMinutes > 0
                      ? "开始了" : "完成",
                      systemImage: task.phase == .start && task.durationMinutes > 0
                      ? "play.fill" : "checkmark")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing) {
            if overdue {
                // 改期是第一个 action:长滑(full swipe)直接触发它;
                // 稍等作为第二个 action,短滑露出后需要点按。
                Button {
                    requestReschedule()
                } label: {
                    Label("改期", systemImage: "calendar.badge.clock")
                }
                .tint(.blue)
                .disabled(rescheduleLoading)
                Button {
                    TaskActions.snooze(task, context: context)
                } label: {
                    Label("+\(AppSettings.snoozeMinutes)M", systemImage: "clock")
                }
                .tint(.orange)
                .accessibilityLabel("稍等 \(AppSettings.snoozeMinutes) 分钟")
            } else {
                Button(role: .destructive) {
                    Haptics.impact()
                    withAnimation(.snappy) {
                        TaskActions.delete(task, context: context)
                    }
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private func complete() {
        withAnimation(.snappy) {
            if let (title, planned) = TaskActions.complete(task, context: context) {
                onAskDuration(title, planned)
            }
        }
    }

    private func requestReschedule() {
        rescheduleTask?.cancel()
        rescheduleLoading = true
        rescheduleCandidates = nil
        rescheduleError = nil
        rescheduleTask = Task {
            do {
                let candidates = try await TaskActions.requestReschedule(for: task)
                guard !Task.isCancelled else { return }
                withAnimation(.snappy) { rescheduleCandidates = candidates }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                rescheduleError = error.localizedDescription
            }
            rescheduleLoading = false
        }
    }

    private func applyReschedule(_ date: Date) {
        Haptics.success()
        TaskActions.applyReschedule(task, to: date, context: context)
        withAnimation(.snappy) { rescheduleCandidates = nil }
    }
}

/// 完成后的实际耗时轻量条(智能采样);今天/未来/全部/总览 共用同一个展示,
/// 各自维护自己的 askDurationQueue 决定何时展示/出队哪一条。
struct AskDurationBanner: View {
    let title: String
    let planned: Int
    var onPick: (Int) -> Void
    var onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("「\(title)」实际用了多久?").font(.subheadline)
            HorizontalChipRow {
                ForEach(TaskActions.durationChips(planned: planned), id: \.self) { minutes in
                    Button("\(minutes) 分钟") {
                        Haptics.success()
                        DurationMemory.recordActual(title: title, planned: planned, minutes: minutes)
                        onPick(minutes)
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
                Button("跳过") { onSkip() }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
