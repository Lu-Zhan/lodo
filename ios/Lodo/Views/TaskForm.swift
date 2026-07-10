import SwiftUI
import LodoCore

/// 创建/编辑表单的字段值与校验、转换逻辑,
/// TaskEditView 与 AddTaskView 的手动输入模块共用。
struct TaskFormModel {
    var title: String
    var repeatType: RepeatType
    var day: Date
    var time: Date
    var allDay: Bool
    var weekdays: Set<Int>
    var times: [Date]
    var duration: Int

    init(from source: ParsedTask? = nil) {
        let base = source?.remindAt ?? Date().addingTimeInterval(300)
        title = source?.title ?? ""
        repeatType = source?.repeatType ?? .none
        day = base
        time = base
        allDay = source?.allDay ?? false
        weekdays = Set(source?.repeatDays ?? [])
        times = (source?.repeatTimes ?? []).map { AppSettings.time($0, on: Date()) }
        duration = source?.durationMinutes ?? 0
    }

    var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch repeatType {
        case .none: return true
        case .daily: return !times.isEmpty
        case .weekly: return !times.isEmpty && !weekdays.isEmpty
        }
    }

    /// 当前表单值 → ParsedTask(重复事项 remindAt 取下一次发生时间)。
    func makeParsed() -> ParsedTask? {
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

    /// 用 AI 返回的字段覆盖当前表单值。
    mutating func apply(_ parsed: ParsedTask) {
        title = parsed.title
        repeatType = parsed.repeatType
        allDay = parsed.allDay
        day = parsed.remindAt
        time = parsed.remindAt
        weekdays = Set(parsed.repeatDays)
        times = parsed.repeatTimes.map { AppSettings.time($0, on: Date()) }
        duration = parsed.durationMinutes
    }
}

/// 表单字段区块(嵌在 Form 内使用)。
struct TaskFormSections: View {
    @Binding var form: TaskFormModel
    /// 第一个区块的标题(如"手动输入"),nil 则不显示。
    var header: String?
    /// AI 解析回填后为 true,首区块标题旁显示"AI 已填写"徽标。
    var aiFilled = false
    /// 时长来自 AI 记忆建议时为 true,时长行高亮提示。
    var suggestedDuration = false

    var body: some View {
        Section {
            TextField("事项内容", text: $form.title)
            Picker("重复", selection: $form.repeatType) {
                Text("不重复").tag(RepeatType.none)
                Text("每天").tag(RepeatType.daily)
                Text("每周").tag(RepeatType.weekly)
            }
            .pickerStyle(.segmented)
        } header: {
            HStack {
                if let header { Text(header) }
                if aiFilled {
                    Label("AI 已填写", systemImage: "sparkles")
                        .foregroundStyle(.tint)
                }
            }
        }
        .onChange(of: form.repeatType) { _, type in
            // 切到重复模式时补一个默认时间点,避免保存按钮无提示地不可用
            if type != .none && form.times.isEmpty {
                form.times.append(AppSettings.time("09:00", on: Date()))
            }
        }

        if form.repeatType == .none {
            Section {
                DatePicker("日期", selection: $form.day, displayedComponents: .date)
                Toggle("全天", isOn: $form.allDay)
                if !form.allDay {
                    DatePicker("时间", selection: $form.time,
                               displayedComponents: .hourAndMinute)
                }
            } footer: {
                if form.allDay {
                    Text("全天事项将在当天 \(AppSettings.allDayTime) 提醒(可在设置中修改)")
                }
            }
        } else {
            if form.repeatType == .weekly {
                Section("周几") {
                    HStack {
                        ForEach(0..<7, id: \.self) { i in
                            Toggle(String(weekdayNames[i].dropFirst()), isOn: Binding(
                                get: { form.weekdays.contains(i) },
                                set: { on in
                                    if on {
                                        form.weekdays.insert(i)
                                    } else {
                                        form.weekdays.remove(i)
                                    }
                                }
                            ))
                            .toggleStyle(.button)
                        }
                    }
                }
            }
            Section("提醒时间点") {
                ForEach(form.times.indices, id: \.self) { i in
                    DatePicker("时间 \(i + 1)", selection: $form.times[i],
                               displayedComponents: .hourAndMinute)
                }
                .onDelete { form.times.remove(atOffsets: $0) }
                Button {
                    form.times.append(AppSettings.time("09:00", on: Date()))
                } label: {
                    Label("添加时间点", systemImage: "plus")
                }
            }
        }

        Section {
            Stepper(value: $form.duration, in: 0...480, step: 5) {
                let text = "时长:\(form.duration == 0 ? "无" : "\(form.duration) 分钟")"
                if suggestedDuration {
                    Label(text, systemImage: "sparkles")
                        .foregroundStyle(.tint)
                } else {
                    Text(text)
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if suggestedDuration {
                    Text("时长为 AI 参考历史类似事项的建议")
                }
                Text("有时长的事项会在开始和结束各提醒一次")
            }
        }
    }
}
