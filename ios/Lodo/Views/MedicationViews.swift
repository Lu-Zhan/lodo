import SwiftUI
import SwiftData
import LodoCore

// 健康页「用药」一组:今天每种药的服药时间点(点一下记「已服用」)、在吃的药、记一笔、
// 从健康 App 导入。开了提醒的药自动建一条重复任务纠缠提醒,完成任务 = 记一笔服药
// (见 MedicationStore)。纯计算在 LodoCore/MedicationPlan.swift。
//
// 和健康开关无关:手记就能用,Mac 上也有。健康 App 的用药只读——能把药和服药记录导进来,
// lodo 里记的写不回去(HealthKit 不开放第三方写服药记录)。用药数据不发给 AI。

struct MedicationSection: View {
    let healthEnabled: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: [SortDescriptor(\Medication.createdAt)]) private var meds: [Medication]
    @Query(sort: [SortDescriptor(\MedicationDose.takenAt, order: .reverse)]) private var doses: [MedicationDose]
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @AppStorage(AppSettings.medicationVisibleKey) private var medicationVisible = true

    @State private var now = Date()
    @State private var editing: MedicationEditTarget?
    @State private var confirmHide = false
    /// 离那一顿还早(超过一小时)时点了大按钮:先问一句再记。
    @State private var earlySlot: MedicationPlan.Slot?
    @State private var logging = false
    @State private var importing = false

    /// 截图参数 --demo-health-records-scroll 滚到这一组。
    static let anchor = "medicationAnchor"

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }
    private var active: [Medication] { meds.filter { !$0.archived } }
    private var slots: [MedicationPlan.Slot] {
        MedicationPlan.todaySlots(active.map(\.entry), doses: doses.map(\.entry), now: now)
    }
    private var canImportFromHealth: Bool { healthEnabled && HealthKitBridge.medicationsSupported }

    var body: some View {
        Section {
            if meds.isEmpty {
                introRow
                    .id(Self.anchor)
            } else {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                    slotRow(slot)
                        .id(index == 0 ? Self.anchor : "slot-\(index)")
                }
                ForEach(active) { med in
                    NavigationLink {
                        MedicationDetailView(medication: med)
                    } label: {
                        medRow(med)
                    }
                }
                let archived = meds.filter(\.archived)
                if !archived.isEmpty {
                    NavigationLink {
                        List(archived) { med in
                            NavigationLink { MedicationDetailView(medication: med) } label: { medRow(med) }
                        }
                        .pageTitle("已停用的药")
                    } label: {
                        HStack {
                            Text("已停用的药")
                            Spacer()
                            Text("\(archived.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                NavigationLink {
                    MedicationDoseListView()
                } label: {
                    HStack {
                        Text("服药记录")
                        Spacer()
                        Text("\(doses.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        } header: {
            HStack(spacing: 16) {
                Text("用药")
                Spacer()
                // 今天该吃的那一顿用下面的大按钮记;这里是补记以前的、记一次跳过、按需吃的药。
                if !meds.isEmpty {
                    Button("补记") { logging = true }
                        .font(.subheadline)
                        .textCase(nil)
                }
                Menu {
                    Button { editing = MedicationEditTarget(medication: nil) } label: {
                        Label("添加药品", systemImage: "plus")
                    }
                    if canImportFromHealth {
                        Button { importing = true } label: {
                            Label("从健康 App 导入", systemImage: "heart.text.square")
                        }
                    }
                    Divider()
                    Button { confirmHide = true } label: {
                        Label("隐藏用药管理", systemImage: "eye.slash")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加")
            }
            // sheet/task 挂在标题行上:挂在 Section 上会分摊到每一行。
            .sheet(item: $editing) { MedicationEditView(medication: $0.medication) }
            .sheet(isPresented: $logging) { MedicationDoseLogView(preset: nil) }
            .sheet(isPresented: $importing) { MedicationHealthImportView() }
            .alert("提前记录这一顿?", isPresented: Binding(
                get: { earlySlot != nil }, set: { if !$0 { earlySlot = nil } }
            )) {
                Button("取消", role: .cancel) { earlySlot = nil }
                Button("记录") {
                    if let slot = earlySlot { record(slot) }
                    earlySlot = nil
                }
            } message: {
                if let slot = earlySlot {
                    Text("离 \(timeText(slot.time)) 那一顿还早,现在记下就算这一顿已经吃了。")
                }
            }
            .alert("隐藏用药管理?", isPresented: $confirmHide) {
                Button("取消", role: .cancel) {}
                Button("隐藏") { medicationVisible = false }
            } message: {
                Text("药品和服药记录都会保留,已开的用药提醒照常响。可以在「设置 → 健康」里重新显示。")
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { now = Date() }
            }
        } footer: {
            if !meds.isEmpty {
                Text("开了提醒的药会自动建一条重复任务按时提醒,在任务里点完成就记一笔服药。用药记录不会发给 AI。")
            }
        }
    }

    private var introRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("用药管理", systemImage: "pills")
                .font(.body.weight(.medium))
            Text("记下在吃的药和时间,需要提醒时 lodo 会自动建一条任务按时提醒;完成任务或手动记一笔,都会留下服药记录。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("添加药品") { editing = MedicationEditTarget(medication: nil) }
                    .buttonStyle(.borderedProminent)
                if canImportFromHealth {
                    Button("从健康 App 导入") { importing = true }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 每种药今天还没记的第一顿:只有它带「记录已服用」的大按钮(服药记录按先后依次
    /// 对上时间点,点后面那顿会被算成前面那顿)。
    private func isNextSlot(_ slot: MedicationPlan.Slot) -> Bool {
        MedicationPlan.nextUnrecordedSlot(of: slot.medicationID, in: slots) == slot
    }

    private func timeText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    private func slotRow(_ slot: MedicationPlan.Slot) -> some View {
        let time = timeText(slot.time)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // 只是状态,不再是按钮:记一顿用下面的大按钮(小圆圈太难点中)。
                Image(systemName: slotSymbol(slot.state))
                    .font(.title3)
                    .foregroundStyle(slotColor(slot.state))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.dosage.isEmpty ? slot.name : "\(slot.name) \(slot.dosage)")
                        .font(.body.weight(.medium))
                    Text(slotCaption(slot, time: time))
                        .font(.footnote)
                        .foregroundStyle(slot.state == .due ? AnyShapeStyle(LodoColor.critical) : AnyShapeStyle(.secondary))
                }
            }
            .accessibilityElement(children: .combine)
            if isNextSlot(slot) {
                Button {
                    if MedicationPlan.isEarly(slot, now: Date()) {
                        earlySlot = slot
                    } else {
                        record(slot)
                    }
                } label: {
                    Label("记录已服用", systemImage: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel(Text("记录已服用 \(slot.name) \(time)"))
            }
        }
        .padding(.vertical, 2)
    }

    /// 记下这一顿。按库里最新的记录再核对一遍它还是不是"下一顿"(连点、通知那边刚点过完成),
    /// 不是就不记。
    private func record(_ slot: MedicationPlan.Slot) {
        guard let med = meds.first(where: { $0.uuid == slot.medicationID }) else { return }
        now = Date()
        if MedicationStore.logNextDose(med, slotTime: slot.time, context: context) {
            Haptics.success()
        }
    }

    private func slotIsDone(_ state: MedicationPlan.SlotState) -> Bool {
        switch state {
        case .taken, .skipped: return true
        case .upcoming, .due: return false
        }
    }

    private func slotSymbol(_ state: MedicationPlan.SlotState) -> String {
        switch state {
        case .taken: return "checkmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        case .upcoming, .due: return "circle"
        }
    }

    private func slotColor(_ state: MedicationPlan.SlotState) -> Color {
        switch state {
        case .taken: return LodoColor.positive
        case .skipped: return LodoColor.muted
        case .due: return LodoColor.critical
        case .upcoming: return .secondary
        }
    }

    private func slotCaption(_ slot: MedicationPlan.Slot, time: String) -> String {
        let bundle = Bundle.appLanguage()
        switch slot.state {
        case .taken(let at):
            let taken = at.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
            return String(localized: "\(time) · \(taken) 已服用", bundle: bundle, locale: locale)
        case .skipped:
            return String(localized: "\(time) · 已跳过", bundle: bundle, locale: locale)
        case .due:
            return String(localized: "\(time) · 还没吃", bundle: bundle, locale: locale)
        case .upcoming:
            return time
        }
    }

    private func medRow(_ med: Medication) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pills")
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(med.name).font(.body.weight(.medium))
                Text(MedicationText.schedule(med, locale: locale))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if MedicationStore.reminderActive(med, context: context) {
                Image(systemName: med.alarm ? "alarm.fill" : "bell.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("提醒已开")
            }
        }
    }
}

/// sheet(item:) 要 Identifiable;nil = 新建。
struct MedicationEditTarget: Identifiable {
    let id = UUID()
    let medication: Medication?
}

enum MedicationText {
    /// 「每天 08:00、20:00 · 1 片」「周一、周五 08:00」「按需服用」。
    static func schedule(_ med: Medication, locale: Locale) -> String {
        let bundle = Bundle.appLanguage()
        var parts: [String] = []
        if med.times.isEmpty {
            parts.append(String(localized: "按需服用", bundle: bundle, locale: locale))
        } else {
            let times = Array(Set(med.times)).sorted().joined(separator: "、")
            if med.days.isEmpty {
                parts.append(String(localized: "每天 \(times)", bundle: bundle, locale: locale))
            } else {
                let days = Array(Set(med.days)).sorted().map { LocalizedContent.weekdayShortName($0) }
                    .joined(separator: "、")
                parts.append("\(days) \(times)")
            }
        }
        let dosage = med.dosage.trimmingCharacters(in: .whitespaces)
        if !dosage.isEmpty { parts.append(dosage) }
        if med.healthConceptID != nil {
            parts.append(String(localized: "已关联健康 App", bundle: bundle, locale: locale))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 编辑药品

struct MedicationEditView: View {
    let medication: Medication?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var name: String
    @State private var dosage: String
    @State private var note: String
    @State private var times: [Date]
    @State private var days: Set<Int>
    @State private var reminder: Bool
    @State private var alarm: Bool
    @State private var alarmDenied = false
    @State private var confirmDelete = false

    init(medication: Medication?) {
        self.medication = medication
        _name = State(initialValue: medication?.name ?? "")
        _dosage = State(initialValue: medication?.dosage ?? "")
        _note = State(initialValue: medication?.note ?? "")
        _times = State(initialValue: (medication?.times ?? []).sorted().map { AppSettings.time($0, on: Date()) })
        _days = State(initialValue: Set(medication?.days ?? []))
        _reminder = State(initialValue: medication?.reminderEnabled ?? true)
        _alarm = State(initialValue: medication?.alarm ?? false)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("药品名称", text: $name)
                    TextField("每次用量(如 1 片)", text: $dosage)
                }
                Section {
                    ForEach(times.indices, id: \.self) { i in
                        DatePicker("时间 \(i + 1)", selection: $times[i], displayedComponents: .hourAndMinute)
                    }
                    .onDelete { times.remove(atOffsets: $0) }
                    Button {
                        times.append(AppSettings.time(times.isEmpty ? "08:00" : "20:00", on: Date()))
                    } label: {
                        Label("添加时间点", systemImage: "plus")
                    }
                } header: {
                    Text("服药时间")
                } footer: {
                    Text("不填时间点就是按需服用,不提醒。")
                }
                if !times.isEmpty {
                    Section {
                        HStack {
                            ForEach(0..<7, id: \.self) { i in
                                Toggle(LocalizedContent.weekdayShortName(i), isOn: Binding(
                                    get: { days.contains(i) },
                                    set: { on in if on { days.insert(i) } else { days.remove(i) } }))
                                .toggleStyle(.button)
                            }
                        }
                    } header: {
                        Text("周几")
                    } footer: {
                        Text("都不选就是每天。")
                    }
                    Section {
                        Toggle("按时提醒", isOn: $reminder)
                        if reminder, TaskAlarms.isSupported {
                            Toggle("用闹钟提醒", isOn: $alarm)
                                .onChange(of: alarm) { _, on in
                                    guard on else { return }
                                    Task {
                                        let granted = await TaskAlarms.requestAuthorization()
                                        alarmDenied = !granted
                                        if !granted { alarm = false }
                                    }
                                }
                        }
                    } footer: {
                        if alarmDenied {
                            Text("没有闹钟权限,可以到系统「设置 → lodo」里打开「闹钟与计时器」。")
                        } else {
                            Text("提醒会自动建成一条重复任务,没完成就按稍等间隔反复提醒;完成任务就记一笔服药。")
                        }
                    }
                }
                Section("备注") {
                    TextField("可选", text: $note, axis: .vertical)
                }
                if let medication {
                    Section {
                        Button(medication.archived ? "恢复服用" : "停用(保留记录)") {
                            medication.archived.toggle()
                            MedicationStore.save(medication, context: context)
                            dismiss()
                        }
                        Button("删除药品", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .pageTitle(medication == nil ? "添加药品" : "编辑药品")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(trimmedName.isEmpty)
                }
            }
            .confirmationDialog("删除这种药?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let medication { MedicationStore.delete(medication, context: context) }
                    dismiss()
                }
            } message: {
                Text("提醒任务会一起删掉,已有的服药记录保留。")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func save() {
        let med = medication ?? {
            let created = Medication(name: trimmedName)
            context.insert(created)
            return created
        }()
        med.name = trimmedName
        med.dosage = dosage.trimmingCharacters(in: .whitespacesAndNewlines)
        med.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        med.times = Array(Set(times.map { AppSettings.hhmm(from: $0) })).sorted()
        med.days = days.count == 7 ? [] : days.sorted()
        med.reminderEnabled = reminder && !med.times.isEmpty
        med.alarm = alarm && med.reminderEnabled
        MedicationStore.save(med, context: context)
        dismiss()
    }
}

// MARK: - 详情

struct MedicationDetailView: View {
    let medication: Medication

    @Environment(\.modelContext) private var context
    @Query private var doses: [MedicationDose]
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @State private var editing: MedicationEditTarget?
    @State private var logging = false

    init(medication: Medication) {
        self.medication = medication
        let id = medication.uuid
        _doses = Query(filter: #Predicate<MedicationDose> { $0.medicationUUID == id },
                       sort: [SortDescriptor(\MedicationDose.takenAt, order: .reverse)])
    }

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }

    var body: some View {
        List {
            Section {
                LabeledContent("用法", value: MedicationText.schedule(medication, locale: locale))
                LabeledContent("提醒") {
                    Text(MedicationStore.reminderActive(medication, context: context) ? "开" : "关")
                }
                if !medication.note.isEmpty {
                    Text(medication.note).foregroundStyle(.secondary)
                }
                let adherence = MedicationPlan.adherence([medication.entry], doses: doses.map(\.entry),
                                                         days: 7, now: Date())
                if adherence.expected > 0 {
                    LabeledContent("最近 7 天") {
                        Text("\(adherence.taken)/\(adherence.expected)").monospacedDigit()
                    }
                }
            }
            Section {
                Button {
                    logging = true
                } label: {
                    Label("记一笔服药", systemImage: "checkmark.circle")
                }
            }
            Section("服药记录") {
                if doses.isEmpty {
                    Text("还没有记录").foregroundStyle(.secondary)
                }
                ForEach(doses.prefix(60)) { dose in
                    MedicationDoseRow(dose: dose)
                }
            }
        }
        .pageTitle("\(medication.name)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑") { editing = MedicationEditTarget(medication: medication) }
            }
        }
        .sheet(item: $editing) { MedicationEditView(medication: $0.medication) }
        .sheet(isPresented: $logging) { MedicationDoseLogView(preset: medication) }
    }
}

struct MedicationDoseRow: View {
    let dose: MedicationDose

    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: dose.status == .taken ? "checkmark.circle.fill" : "minus.circle.fill")
                .foregroundStyle(dose.status == .taken ? LodoColor.positive : LodoColor.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(dose.dosage.isEmpty ? dose.name : "\(dose.name) \(dose.dosage)")
                    .font(.body.weight(.medium))
                Text(caption).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                context.delete(dose)
                try? context.save()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var caption: String {
        let bundle = Bundle.appLanguage()
        let time = dose.takenAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
        var parts = [time]
        if dose.status == .skipped { parts.append(String(localized: "已跳过", bundle: bundle, locale: locale)) }
        switch dose.source {
        case .task: parts.append(String(localized: "完成提醒任务", bundle: bundle, locale: locale))
        case .health: parts.append(String(localized: "来自健康 App", bundle: bundle, locale: locale))
        case .manual: break
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 全部服药记录

struct MedicationDoseListView: View {
    @Query(sort: [SortDescriptor(\MedicationDose.takenAt, order: .reverse)]) private var doses: [MedicationDose]

    var body: some View {
        List {
            if doses.isEmpty {
                Text("还没有记录").foregroundStyle(.secondary)
            }
            ForEach(doses.prefix(300)) { dose in
                MedicationDoseRow(dose: dose)
            }
        }
        .pageTitle("服药记录")
    }
}

// MARK: - 记一笔

struct MedicationDoseLogView: View {
    let preset: Medication?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Medication.createdAt)]) private var meds: [Medication]
    @State private var selected: UUID?
    @State private var date = Date()
    @State private var skipped = false

    init(preset: Medication?) {
        self.preset = preset
        _selected = State(initialValue: preset?.uuid)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("药品", selection: $selected) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(meds.filter { !$0.archived }) { med in
                            Text(med.name).tag(Optional(med.uuid))
                        }
                    }
                    DatePicker("时间", selection: $date, in: ...Date())
                    Toggle("这次跳过了", isOn: $skipped)
                }
            }
            .formStyle(.grouped)
            .pageTitle("记一笔服药")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let med = meds.first(where: { $0.uuid == selected }) {
                            MedicationStore.logDose(med, at: date, status: skipped ? .skipped : .taken,
                                                    context: context)
                        }
                        dismiss()
                    }
                    .disabled(selected == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 280)
        #endif
    }
}

// MARK: - 从健康 App 导入

struct MedicationHealthImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var items: [HealthKitBridge.HealthMedication] = []
    @State private var loading = true
    @State private var imported: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loading {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在读取健康 App…").foregroundStyle(.secondary)
                        }
                    } else if items.isEmpty {
                        Text("健康 App 里没有可导入的药,或者还没允许 lodo 读取。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            if imported.contains(item.id) {
                                Image(systemName: "checkmark").foregroundStyle(LodoColor.positive)
                            } else {
                                Button("导入") {
                                    MedicationStore.importHealthMedication(item, context: context)
                                    imported.insert(item.id)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                } footer: {
                    Text("导入后,健康 App 里这几种药的服药记录会同步到 lodo。健康 App 不允许其他 app 写入服药记录,所以 lodo 里记的不会出现在健康 App 里。")
                }
                Section {
                    Button("选择允许读取的药") {
                        Task { await load(requestAccess: true) }
                    }
                }
            }
            .pageTitle("从健康 App 导入")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        Task {
                            await MedicationStore.importHealthDoses(context: context)
                            dismiss()
                        }
                    }
                }
            }
            // 按药授权的那张单子系统每次都会弹,所以只在第一次自动弹;之后靠下面那颗按钮。
            .task {
                let key = "medicationAccessRequested"
                let first = !UserDefaults.standard.bool(forKey: key)
                UserDefaults.standard.set(true, forKey: key)
                await load(requestAccess: first)
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 360)
        #endif
    }

    private func load(requestAccess: Bool) async {
        loading = true
        if requestAccess { await HealthKitBridge.requestMedicationAuthorization() }
        items = await MedicationStore.unlinkedHealthMedications(context: context)
        loading = false
    }
}

#if DEBUG
/// 截图参数 `--demo-health-records`:塞两种药(一种开了提醒、一种按需)、今天一笔服药、
/// 三次经期,并把「经期记录」设成开启。库里已经有药品就不重复塞。
@MainActor
enum HealthRecordsDemo {
    static func seedIfRequested(context: ModelContext) {
        guard ProcessInfo.processInfo.arguments.contains("--demo-health-records"),
              ((try? context.fetchCount(FetchDescriptor<Medication>())) ?? 0) == 0 else { return }
        UserDefaults.standard.set(CyclePlan.Preference.on.rawValue, forKey: AppSettings.cycleTrackingKey)
        let vitamin = Medication(name: "维生素 D", dosage: "1 粒", times: ["08:00", "21:00"],
                                 reminderEnabled: true)
        let ibuprofen = Medication(name: "布洛芬", dosage: "200 毫克")
        context.insert(vitamin)
        context.insert(ibuprofen)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if let morning = calendar.date(bySettingHour: 8, minute: 12, second: 0, of: today), morning < Date() {
            context.insert(MedicationDose(medicationUUID: vitamin.uuid, name: vitamin.name,
                                          dosage: vitamin.dosage, takenAt: morning))
        }
        for offset in [-58, -30, -2] {
            guard let start = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let end = offset == -2 ? nil : calendar.date(byAdding: .day, value: 4, to: start)
            context.insert(PeriodRecord(start: start, end: end))
        }
        try? context.save()
        MedicationStore.syncTask(for: vitamin, context: context)
    }
}
#endif
