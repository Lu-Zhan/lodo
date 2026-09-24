import SwiftUI
import LodoCore

/// 待办页里的定时任务行:与 `TaskRowView` 视觉上明显区分——sparkles 图标 +
/// "AI 定时任务"胶囊标签,没有完成/稍等/忽略(定时任务没有"到期未处理"这个
/// 状态),只有立即运行/删除。今天已经跑过一次时把结果文本直接显示在副标题
/// 下面,不用再点进详情。
struct RoutineRowView: View {
    let routine: AIRoutine
    let now: Date
    /// 今天跑过的最新一条结果(没跑过传 nil)。
    let latestRunToday: AIRoutineRun?
    var onEdit: () -> Void

    @Environment(\.modelContext) private var context
    @State private var running = false
    @State private var runError: String?

    private var subtitle: String {
        guard routine.enabled else { return "\(routine.caption) · 已停用" }
        guard let next = routine.nextRun(after: now) else { return routine.caption }
        return "\(routine.caption) · 下一次 \(TaskItem.format(next))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(Color.accentColor)
                        Text(routine.name.isEmpty ? "未命名任务" : routine.name)
                        Text("AI 定时任务")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .foregroundStyle(Color.accentColor)
                        if running {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let latestRunToday {
                        Text(latestRunToday.text)
                            .font(.subheadline)
                            .foregroundStyle(latestRunToday.failed ? .red : .primary)
                    }
                    if let runError {
                        Text(runError).font(.caption).foregroundStyle(LodoColor.critical)
                    }
                }
            }
            .pressableCard()
        }
        // 全部收在 trailing:向右拖归抽屉(见 TaskRowView 同款注释)。
        .swipeActions(edge: .trailing) {
            Button {
                runNow()
            } label: {
                Label("立即运行", systemImage: "play.fill")
            }
            .tint(.accentColor)
            .disabled(running)
            Button(role: .destructive) {
                Haptics.impact()
                RoutineRunner.delete(routine, context: context)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// 待办页里手动跑一次:落一条历史记录,不推通知(人就在 app 里看着)。
    private func runNow() {
        running = true
        runError = nil
        Task {
            let result = await RoutineRunner.run(routine, context: context,
                                                 manual: true, notify: false)
            running = false
            if case .failure(let error) = result, !(error is CancellationError) {
                runError = error.localizedDescription
            }
        }
    }
}
