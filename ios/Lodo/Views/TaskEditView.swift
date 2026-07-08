import SwiftUI
import LodoCore

/// 创建/编辑共用表单;编辑模式下支持 AI 自然语言指令修改。
struct TaskEditView: View {
    let existing: TaskItem?
    var onSave: (ParsedTask) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var repeatType: RepeatType
    @State private var day: Date
    @State private var time: Date
    @State private var allDay: Bool
    @State private var weekdays: Set<Int>
    @State private var times: [Date]
    @State private var duration: Int

    @State private var aiInstruction = ""
    @State private var aiBusy = false
    @State private var errorText: String?

    init(existing: TaskItem?, parsed: ParsedTask?, onSave: @escaping (ParsedTask) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let source: ParsedTask? = parsed ?? existing.map { task in
            ParsedTask(title: task.title, remindAt: task.remindAt, allDay: task.allDay,
                       durationMinutes: task.durationMinutes, repeatType: task.repeatType,
                       repeatDays: task.repeatDays, repeatTimes: task.repeatTimes)
        }
        let base = source?.remindAt ?? Date().addingTimeInterval(300)
        _title = State(initialValue: source?.title ?? "")
        _repeatType = State(initialValue: source?.repeatType ?? .none)
        _day = State(initialValue: base)
        _time = State(initialValue: base)
        _allDay = State(initialValue: source?.allDay ?? false)
        _weekdays = State(initialValue: Set(source?.repeatDays ?? []))
        _times = State(initialValue: (source?.repeatTimes ?? []).map {
            AppSettings.time($0, on: Date())
        })
        _duration = State(initialValue: source?.durationMinutes ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("事项内容", text: $title)
                    Picker("重复", selection: $repeatType) {
                        Text("不重复").tag(RepeatType.none)
                        Text("每天").tag(RepeatType.daily)
                        Text("每周").tag(RepeatType.weekly)
                    }
                    .pickerStyle(.segmented)
                }

                if repeatType == .none {
                    Section {
                        DatePicker("日期", selection: $day, displayedComponents: .date)
                        Toggle("全天", isOn: $allDay)
                        if !allDay {
                            DatePicker("时间", selection: $time, displayedComponents: .hourAndMinute)
                        }
                    } footer: {
                        if allDay {
                            Text("全天事项将在当天 \(AppSettings.allDayTime) 提醒(可在设置中修改)")
                        }
                    }
                } else {
                    if repeatType == .weekly {
                        Section("周几") {
                            HStack {
                                ForEach(0..<7, id: \.self) { i in
                                    Toggle(String(weekdayNames[i].dropFirst()), isOn: Binding(
                                        get: { weekdays.contains(i) },
                                        set: { on in
                                            if on { weekdays.insert(i) } else { weekdays.remove(i) }
                                        }
                                    ))
                                    .toggleStyle(.button)
                                }
                            }
                        }
                    }
                    Section("提醒时间点") {
                        ForEach(times.indices, id: \.self) { i in
                            DatePicker("时间 \(i + 1)", selection: $times[i],
                                       displayedComponents: .hourAndMinute)
                        }
                        .onDelete { times.remove(atOffsets: $0) }
                        Button {
                            times.append(AppSettings.time("09:00", on: Date()))
                        } label: {
                            Label("添加时间点", systemImage: "plus")
                        }
                    }
                }

                Section {
                    Stepper("时长:\(duration == 0 ? "无" : "\(duration) 分钟")",
                            value: $duration, in: 0...480, step: 5)
                } footer: {
                    Text("有时长的事项会在开始和结束各提醒一次")
                }

                if existing != nil {
                    Section("AI 修改") {
                        TextField("例如:改到明天晚上8点 / 改成每天早晚各提醒一次",
                                  text: $aiInstruction)
                            .onSubmit { applyAI() }
                        Button {
                            applyAI()
                        } label: {
                            if aiBusy {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("应用修改", systemImage: "sparkles")
                            }
                        }
                        .disabled(aiBusy ||
                                  aiInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle(existing == nil ? "新建事项" : "编辑事项")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch repeatType {
        case .none: return true
        case .daily: return !times.isEmpty
        case .weekly: return !times.isEmpty && !weekdays.isEmpty
        }
    }

    /// 当前表单值 → ParsedTask(重复事项 remindAt 取下一次发生时间)。
    private func makeParsed() -> ParsedTask? {
        guard isValid else { return nil }
        let timeStrings = Array(Set(times.map { AppSettings.hhmm(from: $0) })).sorted()
        var parsed = ParsedTask(
            title: title.trimmingCharacters(in: .whitespaces),
            remindAt: Date(),
            allDay: repeatType == .none && allDay,
            durationMinutes: duration,
            repeatType: repeatType,
            repeatDays: repeatType == .weekly ? weekdays.sorted() : [],
            repeatTimes: repeatType == .none ? [] : timeStrings
        )
        if repeatType == .none {
            parsed.remindAt = allDay
                ? AppSettings.time(AppSettings.allDayTime, on: day)
                : Calendar.current.date(
                    bySettingHour: Calendar.current.component(.hour, from: time),
                    minute: Calendar.current.component(.minute, from: time),
                    second: 0, of: day) ?? day
        } else {
            let probe = TaskData(title: parsed.title, remindAt: Date(),
                                 repeatType: parsed.repeatType,
                                 repeatDays: parsed.repeatDays,
                                 repeatTimes: parsed.repeatTimes)
            guard let first = Scheduler.nextOccurrence(probe, after: Date()) else { return nil }
            parsed.remindAt = first
        }
        return parsed
    }

    private func save() {
        guard let parsed = makeParsed() else {
            errorText = "请补全事项内容和时间设置"
            return
        }
        onSave(parsed)
        dismiss()
    }

    private func applyAI() {
        let instruction = aiInstruction.trimmingCharacters(in: .whitespaces)
        guard !instruction.isEmpty, !aiBusy, let current = makeParsed() else { return }
        aiBusy = true
        errorText = nil
        Task {
            defer { aiBusy = false }
            do {
                let updated = try await DeepSeekClient.edit(current, instruction: instruction)
                title = updated.title
                repeatType = updated.repeatType
                allDay = updated.allDay
                day = updated.remindAt
                time = updated.remindAt
                weekdays = Set(updated.repeatDays)
                times = updated.repeatTimes.map { AppSettings.time($0, on: Date()) }
                duration = updated.durationMinutes
                aiInstruction = ""
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
