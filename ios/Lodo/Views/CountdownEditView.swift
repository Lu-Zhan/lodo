import SwiftUI
import SwiftData
import LodoCore

/// 倒数日的新建/编辑表单。开始、结束各自可以选多个提醒;「显示在锁屏小组件」
/// 最多勾 3 件(`CountdownPlan.widgetLimit`),满了的时候这一项的开关变灰并说明。
struct CountdownEditView: View {
    /// nil = 新建。
    let event: CountdownEvent?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var allEvents: [CountdownEvent]

    @State private var title = ""
    @State private var allDay = true
    @State private var start = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now)
    @State private var hasEnd = false
    @State private var end = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: 8, to: .now) ?? .now)
    @State private var startReminders: [Int] = []
    @State private var endReminders: [Int] = []
    @State private var showInWidget = false
    @State private var notes = ""
    @State private var didLoad = false
    @State private var confirmingDelete = false

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasInvalidRange: Bool {
        guard hasEnd else { return false }
        return allDay
            ? Calendar.current.startOfDay(for: end) < Calendar.current.startOfDay(for: start)
            : end < start
    }
    private var canSave: Bool { !trimmedTitle.isEmpty && !hasInvalidRange }

    /// 除了这一件,已经勾了几件显示在小组件上。
    private var otherWidgetCount: Int {
        allEvents.filter { $0.showInWidget && $0.uuid != event?.uuid }.count
    }
    private var widgetFull: Bool { !showInWidget && otherWidgetCount >= CountdownPlan.widgetLimit }

    /// 表单里当前填的内容,用来实时显示"还有几天"。
    private var draft: CountdownEntry {
        CountdownEntry(title: trimmedTitle, start: start, end: hasEnd ? end : nil, allDay: allDay)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称,如 东京旅行、驾照考试", text: $title)
                }

                if !hasInvalidRange {
                    Section {
                        TimelineView(.everyMinute) { context in
                            let spans = CountdownPlan.spans(draft, now: context.date)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(CountdownText.text(spans[0], hasEnd: hasEnd))
                                    .font(.title2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.tint)
                                if spans.count > 1 {
                                    Text(CountdownText.text(spans[1], hasEnd: true))
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    Toggle("全天", isOn: $allDay)
                    DatePicker("开始", selection: $start,
                               displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    Toggle("有结束时间", isOn: $hasEnd.animation(.lodoAware(.snappy)))
                    if hasEnd {
                        DatePicker("结束", selection: $end,
                                   displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    }
                    if hasInvalidRange {
                        Text("结束早于开始,改一下才能保存。")
                            .font(.subheadline)
                            .foregroundStyle(LodoColor.critical)
                    }
                } footer: {
                    Text("全天的事按日子算,结束那天整天都还算进行中。")
                }

                Section {
                    NavigationLink {
                        CountdownReminderPicker(title: "开始提醒", selection: $startReminders)
                    } label: {
                        LabeledContent("开始提醒", value: CountdownText.offsetsSummary(startReminders))
                    }
                    if hasEnd {
                        NavigationLink {
                            CountdownReminderPicker(title: "结束提醒", selection: $endReminders)
                        } label: {
                            LabeledContent("结束提醒",
                                           value: CountdownText.offsetsSummary(endReminders))
                        }
                    }
                } header: {
                    Text("提醒")
                } footer: {
                    if allDay {
                        Text("全天的事按「设置 → 提醒」里的全天提醒时间(\(AppSettings.allDayTime))提醒。")
                    }
                }

                Section {
                    Toggle("显示在锁屏小组件", isOn: $showInWidget)
                        .disabled(widgetFull)
                } footer: {
                    Text(widgetFull
                         ? "锁屏「倒数日」小组件最多显示 3 件,已经选满了。先在别的倒数日里关掉一件。"
                         : "锁屏「倒数日」小组件最多显示 3 件,按日子从近到远排。")
                }

                Section("备注") {
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                if event != nil {
                    Section {
                        Button("删除倒数日", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(LocalizedStringKey(event == nil ? "添加倒数日" : "编辑倒数日"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("删除这个倒数日?提醒也会一起取消。",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) { delete() }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let event else { return }
        title = event.title
        allDay = event.allDay
        start = event.startDate
        if let value = event.endDate {
            hasEnd = true
            end = value
        } else {
            end = Calendar.current.date(byAdding: .day, value: 1, to: event.startDate) ?? end
        }
        startReminders = event.startReminders
        endReminders = event.endReminders
        showInWidget = event.showInWidget
        notes = event.notes
    }

    private func save() {
        let calendar = Calendar.current
        let target = event ?? {
            let created = CountdownEvent()
            context.insert(created)
            return created
        }()
        target.title = trimmedTitle
        target.allDay = allDay
        // 全天的只存日子(0 点),免得"几点"在别的时区/改设置后让它挪一天。
        target.startDate = allDay ? calendar.startOfDay(for: start) : start
        target.endDate = hasEnd ? (allDay ? calendar.startOfDay(for: end) : end) : nil
        target.startReminders = Array(Set(startReminders)).sorted()
        target.endReminders = hasEnd ? Array(Set(endReminders)).sorted() : []
        target.showInWidget = showInWidget && (otherWidgetCount < CountdownPlan.widgetLimit
                                               || event?.showInWidget == true)
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try? context.save()
        CountdownNotifier.reschedule(context: context)
        WidgetBridge.sync(context: context)
        Haptics.success()
        dismiss()
    }

    private func delete() {
        guard let event else { return }
        context.delete(event)
        try? context.save()
        CountdownNotifier.reschedule(context: context)
        WidgetBridge.sync(context: context)
        dismiss()
    }
}

/// 提醒多选:每一项一行,点一下勾上/取消。
private struct CountdownReminderPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: [Int]

    var body: some View {
        List {
            Section {
                ForEach(CountdownPlan.reminderPresets, id: \.self) { offset in
                    Button {
                        if let index = selection.firstIndex(of: offset) {
                            selection.remove(at: index)
                        } else {
                            selection.append(offset)
                        }
                    } label: {
                        HStack {
                            Text(CountdownText.offsetText(offset))
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection.contains(offset) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .pressableCard()
                    .accessibilityAddTraits(selection.contains(offset) ? .isSelected : [])
                }
            } footer: {
                Text("可以选多个。")
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
