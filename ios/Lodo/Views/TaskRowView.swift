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
                            .font(.subheadline)
                        if overdue, rescheduleLoading {
                            Spacer()
                            ProgressView().controlSize(.small)
                                .accessibilityLabel("正在改期")
                        }
                    }
                    Text(overdue ? dueCaption : task.caption)
                        .font(.caption)
                        .foregroundStyle(overdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            }
            .pressableCard()
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
                        withAnimation(.lodoAware(.snappy)) { self.rescheduleCandidates = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .pressable()
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
        // 比系统默认的行内边距紧一档(默认竖向 11):一屏能多放几条,配合上面
        // 小一号的字号,列表整体更密。横向沿用 insetGrouped 的 16,不动。
        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
        // 全部行操作都收在 trailing(向左滑)这一侧:向右拖是抽屉的方向,
        // 留任何 leading action 都会和它抢同一个手势(见 AppShellView.sidebarDrag)。
        // "完成"排在最靠外 = 它是 full swipe 那一个,等于把原来"用力右滑完成"
        // 原样镜像过来,方向变了但力度语义没变;顺带把删除从第一个挤走,
        // 用力一滑就误删的路也就没了。
        .swipeActions(edge: .trailing) {
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
            if overdue {
                Button {
                    requestReschedule()
                } label: {
                    Label("改期", systemImage: "calendar.badge.clock")
                }
                .tint(.blue)
                .disabled(rescheduleLoading)
                Button {
                    Haptics.impact(.light)
                    TaskActions.snooze(task, context: context)
                } label: {
                    // 全 app 文案是中文,这里别留一个英文缩写("+15M");具体多少
                    // 分钟放旁白标签里,滑动按钮本身在窄屏上多半只显示图标。
                    Label("稍等", systemImage: "clock")
                }
                .tint(.orange)
                .accessibilityLabel("稍等 \(AppSettings.snoozeMinutes) 分钟")
                Button {
                    Haptics.impact(.light)
                    TaskActions.ignore(task, context: context)
                } label: {
                    Label("忽略", systemImage: "bell.slash")
                }
                .tint(.gray)
            } else {
                Button(role: .destructive) {
                    Haptics.impact()
                    withAnimation(.lodoAware(.snappy)) {
                        TaskActions.delete(task, context: context)
                    }
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private func complete() {
        withAnimation(.lodoAware(.snappy)) {
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
                withAnimation(.lodoAware(.snappy)) { rescheduleCandidates = candidates }
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
        withAnimation(.lodoAware(.snappy)) { rescheduleCandidates = nil }
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
                    .pressable()
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
