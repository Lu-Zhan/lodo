import SwiftUI
import SwiftData
import LodoCore

/// 定时任务的新建/编辑表单。字段先落在本地 @State 草稿上,点"完成"才写回模型
/// (新建的任务这时才 insert)——取消就是真的什么都没改。
struct RoutineEditView: View {
    let routine: AIRoutine
    let isNew: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var name: String
    @State private var prompt: String
    @State private var times: [String]
    @State private var repeatType: RepeatType
    @State private var days: Set<Int>
    @State private var includeTasks: Bool
    @State private var useWebSearch: Bool
    @State private var notify: Bool

    @State private var previewText: String?
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var showDeleteConfirm = false

    init(routine: AIRoutine, isNew: Bool) {
        self.routine = routine
        self.isNew = isNew
        _name = State(initialValue: routine.name)
        _prompt = State(initialValue: routine.prompt)
        _times = State(initialValue: routine.times.isEmpty ? ["08:00"] : routine.times)
        _repeatType = State(initialValue: routine.repeatType)
        _days = State(initialValue: Set(routine.days))
        _includeTasks = State(initialValue: routine.includeTasks)
        _useWebSearch = State(initialValue: routine.useWebSearch)
        _notify = State(initialValue: routine.notify)
    }

    private var canSave: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("任务名(如:今日穿搭)", text: $name)
                    TextEditor(text: $prompt)
                        .frame(minHeight: 90)
                        .font(.body)
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("要 AI 每次做什么,如:看看今天上海的天气,给一句穿衣建议")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("任务")
                } footer: {
                    Text("指令原样发给 AI,写清楚要什么内容;每次只会返回一段不超过 120 字的文字。")
                }

                scheduleSection
                optionsSection
                previewSection

                if !isNew {
                    Section {
                        Button("删除这条定时任务", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "新建定时任务" : "定时任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        previewTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save() }.disabled(!canSave)
                }
            }
            .confirmationDialog("删除这条定时任务?", isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    RoutineRunner.delete(routine, context: context)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("它的运行历史也会一起删除。")
            }
            .onDisappear { previewTask?.cancel() }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 560)
        #endif
    }

    // MARK: - 时间

    @ViewBuilder
    private var scheduleSection: some View {
        Section {
            Picker("重复", selection: $repeatType) {
                Text("每天").tag(RepeatType.daily)
                Text("每周").tag(RepeatType.weekly)
            }
            .pickerStyle(.segmented)
            if repeatType == .weekly {
                HStack {
                    ForEach(0..<7, id: \.self) { i in
                        Toggle(String(weekdayNames[i].dropFirst()), isOn: dayBinding(i))
                            .toggleStyle(.button)
                    }
                }
            }
            ForEach(times.indices, id: \.self) { i in
                DatePicker("时间 \(i + 1)", selection: timeBinding(i),
                           displayedComponents: .hourAndMinute)
            }
            .onDelete { offsets in
                times.remove(atOffsets: offsets)
                if times.isEmpty { times = ["08:00"] }
            }
            Button {
                times.append("08:00")
            } label: {
                Label("添加时间点", systemImage: "plus")
            }
        } header: {
            Text("什么时候跑")
        } footer: {
            Text(scheduleFooter)
        }
    }

    private var scheduleFooter: String {
        if repeatType == .weekly && days.isEmpty {
            return "至少选一天,否则这条任务永远不会触发。"
        }
        let draft = AIRoutine(name: name, prompt: prompt, times: times,
                              repeatType: repeatType, days: Array(days))
        guard let next = draft.nextRun() else { return "当前设置算不出下一次触发时间。" }
        return "下一次:\(TaskItem.format(next))。一天可以设多个时间点。"
    }

    // MARK: - 选项

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            Toggle("带上今天的待办", isOn: $includeTasks)
            // 没配 Tavily key 也让开——运行时自会退回不联网(见 RoutineRunner.generate),
            // 禁用一个模板默认打开的开关反而让用户既关不掉也不知道为什么。
            Toggle("允许联网搜索", isOn: $useWebSearch)
            Toggle("结果发通知", isOn: $notify)
        } header: {
            Text("选项")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text("总结/复盘类任务打开「带上今天的待办」;天气、行情这类要开「允许联网搜索」。")
                if !WebSearchClient.isConfigured {
                    Text("联网搜索需要先在「AI 设置」里配置 Tavily API key。")
                }
                if !notify {
                    Text("关掉通知后,结果只在这里和「总览」里显示。")
                }
            }
        }
    }

    // MARK: - 试运行

    @ViewBuilder
    private var previewSection: some View {
        Section {
            Button {
                runPreview()
            } label: {
                if previewTask != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在生成…")
                    }
                } else {
                    Label("试运行一次", systemImage: "play.circle")
                }
            }
            .disabled(!canSave || previewTask != nil)
            if let previewText {
                Text(previewText).font(.footnote)
            }
            if let previewError {
                Text(previewError).font(.footnote).foregroundStyle(.red)
            }
        } footer: {
            Text("先看看 AI 会给出什么内容,不会保存进历史记录。")
        }
    }

    private func runPreview() {
        previewText = nil
        previewError = nil
        previewTask = Task {
            do {
                let text = try await RoutineRunner.preview(
                    name: name.isEmpty ? "定时任务" : name, prompt: prompt,
                    includeTasks: includeTasks, useWebSearch: useWebSearch, context: context)
                previewText = text
            } catch is CancellationError {
                // 取消/关页面,不提示
            } catch {
                previewError = error.localizedDescription
            }
            previewTask = nil
        }
    }

    // MARK: - 保存

    private func save() {
        previewTask?.cancel()
        routine.name = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "定时任务" : name.trimmingCharacters(in: .whitespaces)
        routine.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        routine.times = times.isEmpty ? ["08:00"] : times
        routine.repeatType = repeatType
        routine.days = Array(days)
        routine.includeTasks = includeTasks
        routine.useWebSearch = useWebSearch
        routine.notify = notify
        if isNew { context.insert(routine) }
        try? context.save()
        RoutineRunner.refreshSchedule(context: context)
        dismiss()
    }

    // MARK: - 绑定

    private func dayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { days.contains(day) },
            set: { on in
                if on { days.insert(day) } else { days.remove(day) }
            }
        )
    }

    /// "HH:MM" 字符串 ↔ DatePicker 的 Date(与 ReminderSettingsView 同一种写法)。
    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(
            get: { AppSettings.time(index < times.count ? times[index] : "08:00", on: Date()) },
            set: { date in
                guard index < times.count else { return }
                times[index] = AppSettings.hhmm(from: date)
            }
        )
    }
}
