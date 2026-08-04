import SwiftUI
import SwiftData
import LodoCore

/// 设置 → 定时任务:用户自定义的 AI 例行任务列表(新建/开关/试运行/看历史结果)。
/// 每条任务到点自动跑一次用户写的指令,详见 `RoutineRunner`。
struct RoutineListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AIRoutine.createdAt) private var routines: [AIRoutine]
    @Query(sort: [SortDescriptor(\AIRoutineRun.createdAt, order: .reverse)])
    private var runs: [AIRoutineRun]

    /// 正在编辑的任务 + 是不是刚新建的(取消要连模型一起丢掉)。
    @State private var editing: RoutineDraftTarget?
    @State private var runningUUID: UUID?
    @State private var runError: String?

    var body: some View {
        List {
            Section {
                if routines.isEmpty {
                    ContentUnavailableView(
                        "还没有定时任务", systemImage: "clock.badge",
                        description: Text("用右上角的 + 添加,比如每天早上让 AI 总结今天的待办。"))
                } else {
                    ForEach(routines) { routine in
                        row(routine)
                    }
                    .onDelete { offsets in
                        for routine in offsets.map({ routines[$0] }) {
                            RoutineRunner.delete(routine, context: context)
                        }
                    }
                }
            } footer: {
                Text("到设定时间自动执行,结果推送给你。系统会挑合适的时机在后台完成,如果没赶上,到点会先提醒你打开 app,打开后立刻补跑。")
            }

            if !recentRuns.isEmpty {
                Section("最近结果") {
                    ForEach(recentRuns) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(run.routineName).font(.subheadline.weight(.medium))
                                if run.manual {
                                    Text("试运行").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(TaskItem.format(run.createdAt))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(run.text)
                                .font(.footnote)
                                .foregroundStyle(run.failed ? .red : .primary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("定时任务")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(AIRoutine.presets) { preset in
                        Button {
                            create(from: preset)
                        } label: {
                            Label(preset.name, systemImage: preset.symbol)
                        }
                    }
                    Divider()
                    Button {
                        create(from: nil)
                    } label: {
                        Label("自定义", systemImage: "square.and.pencil")
                    }
                } label: {
                    Label("添加定时任务", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { target in
            RoutineEditView(routine: target.routine, isNew: target.isNew)
        }
        .alert("运行失败", isPresented: Binding(
            get: { runError != nil }, set: { if !$0 { runError = nil } }
        )) {
            Button("好", role: .cancel) { runError = nil }
        } message: {
            Text(runError ?? "")
        }
        .onAppear { RoutineRunner.refreshSchedule(context: context) }
    }

    /// 最近 10 条结果(全部任务混在一起,按时间倒序)。
    private var recentRuns: [AIRoutineRun] { Array(runs.prefix(10)) }

    private func row(_ routine: AIRoutine) -> some View {
        HStack {
            Button {
                editing = RoutineDraftTarget(routine: routine, isNew: false)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(routine.name.isEmpty ? "未命名任务" : routine.name)
                        .foregroundStyle(.primary)
                    Text(subtitle(routine))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if runningUUID == routine.uuid {
                ProgressView().controlSize(.small)
            } else {
                Toggle("启用", isOn: Binding(
                    get: { routine.enabled },
                    set: { routine.enabled = $0; save() }
                ))
                .labelsHidden()
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                runNow(routine)
            } label: {
                Label("立即运行", systemImage: "play.fill")
            }
            .tint(.accentColor)
        }
    }

    /// 副标题:重复方式 + 下一次触发;停用时只说停用。
    private func subtitle(_ routine: AIRoutine) -> String {
        guard routine.enabled else { return "\(routine.caption) · 已停用" }
        guard let next = routine.nextRun() else { return routine.caption }
        return "\(routine.caption) · 下一次 \(TaskItem.format(next))"
    }

    private func create(from preset: AIRoutine.Preset?) {
        // 先不插库:用户在编辑页点取消就什么都没发生,不用再回收一条空任务。
        let routine = preset.map { AIRoutine(preset: $0) } ?? AIRoutine(name: "", prompt: "")
        editing = RoutineDraftTarget(routine: routine, isNew: true)
    }

    /// 列表里手动跑一次:落一条历史记录,不推通知(人就在 app 里看着)。
    private func runNow(_ routine: AIRoutine) {
        runningUUID = routine.uuid
        Task {
            let result = await RoutineRunner.run(routine, context: context,
                                                 manual: true, notify: false)
            runningUUID = nil
            if case .failure(let error) = result, !(error is CancellationError) {
                runError = error.localizedDescription
            }
        }
    }

    private func save() {
        try? context.save()
        RoutineRunner.refreshSchedule(context: context)
    }
}

/// sheet(item:) 要一个 Identifiable 的值:带上"是不是新建的",编辑页据此决定
/// 保存时要不要 insert(新建的任务在点"完成"之前不入库)。
struct RoutineDraftTarget: Identifiable {
    let routine: AIRoutine
    let isNew: Bool

    var id: UUID { routine.uuid }
}
