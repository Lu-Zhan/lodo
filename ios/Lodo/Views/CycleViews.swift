import SwiftUI
import SwiftData
import LodoCore

// 健康页「经期」一组:今天是经期第几天 / 离下次还有几天、「经期开始了 / 结束了」一键记、
// 历史记录、经期提醒。纯计算在 LodoCore/CyclePlan.swift,合并与提醒在 CycleStore。
//
// 显不显示由设置里的「经期记录」决定(`AppSettings.cycleTrackingEnabled`:自动 = 健康 App
// 里是女性才开)。和健康开关无关:手记就能用,Mac 上也有;开了健康分析时再把健康 App 里的
// 经期记录合并进来(手记优先)。经期数据不发给 AI。

struct CycleSection: View {
    /// 健康分析开着(才去读健康 App 的经期)。
    let healthEnabled: Bool
    /// 下拉刷新时 +1,重新读健康 App。
    var refreshToken = 0

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: [SortDescriptor(\PeriodRecord.start)]) private var records: [PeriodRecord]
    @AppStorage(AppSettings.cycleReminderEnabledKey) private var reminderEnabled = true
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue

    @State private var healthPeriods: [CyclePlan.Period] = []
    @State private var now = Date()
    @State private var addingPast = false

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }
    private var periods: [CyclePlan.Period] {
        CyclePlan.merge(manual: records.map(\.period), health: healthPeriods, today: now)
    }
    private var summary: CyclePlan.Summary { CyclePlan.summary(periods, today: now) }
    private var inPeriod: Bool { summary.periodDay != nil }
    /// 还开着(没记结束日)的那段手记。
    private var openRecord: PeriodRecord? {
        records.last { CyclePlan.isOpen(start: $0.start, end: $0.end, today: now) }
    }

    var body: some View {
        Section {
            if periods.isEmpty {
                introRow
            } else {
                statusRow
                actionRow
                Toggle(isOn: $reminderEnabled) {
                    Label("经期提醒", systemImage: "bell")
                }
                NavigationLink {
                    CycleHistoryView(healthPeriods: healthPeriods)
                } label: {
                    HStack {
                        Text("经期记录")
                        Spacer()
                        Text("\(periods.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        } header: {
            HStack {
                Text("经期")
                Spacer()
                Button { addingPast = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("补记一次经期")
            }
            // sheet/task 挂在标题行上:挂在 Section 上会分摊到每一行。
            .sheet(isPresented: $addingPast) { PeriodEditView(record: nil) }
            .task(id: "\(healthEnabled)-\(refreshToken)") {
                // 经期的读权限单独问(不在健康分析那张总授权单里),第一次显示这组时问一次。
                let key = "cycleAccessRequested"
                if healthEnabled, !UserDefaults.standard.bool(forKey: key) {
                    UserDefaults.standard.set(true, forKey: key)
                    await HealthKitBridge.requestCycleAuthorization()
                }
                healthPeriods = await CycleStore.healthPeriods()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { now = Date() }
            }
            // 记录、健康数据、开关一变就按新的预测重排提醒。
            .onChange(of: reminderKey, initial: true) { _, _ in
                CycleStore.reschedule(summary: summary)
            }
        } footer: {
            Text("预测按最近几个周期的平均长度估算,仅供参考,不能用于避孕。经期记录只存在这台设备和你的 iCloud 里,不会发给 AI。")
        }
    }

    /// 影响提醒的那几样拼成一个键。
    private var reminderKey: String {
        "\(reminderEnabled)|\(summary.nextStart?.timeIntervalSince1970 ?? 0)|\(inPeriod)|\(summary.estimatedFromDefault)"
    }

    // MARK: - 行

    private var introRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("记录经期", systemImage: "drop")
                .font(.body.weight(.medium))
            Text("来了点一下「经期开始了」,结束时再点「结束了」。记过两次以上,lodo 会估下一次大概哪天来,并提前两天提醒。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("经期开始了") { CycleStore.startToday(records: records, context: context) }
                    .buttonStyle(.borderedProminent)
                Button("补记一次") { addingPast = true }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headline)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        let bundle = Bundle.appLanguage()
        if let day = summary.periodDay {
            return String(localized: "经期第 \(day) 天", bundle: bundle, locale: locale)
        }
        guard let days = summary.daysUntilNext else {
            return String(localized: "还没有足够的记录", bundle: bundle, locale: locale)
        }
        if days > 0 {
            return String(localized: "距下次经期约 \(days) 天", bundle: bundle, locale: locale)
        }
        if days == 0 {
            return String(localized: "预计今天开始", bundle: bundle, locale: locale)
        }
        return String(localized: "比预计晚了 \(-days) 天", bundle: bundle, locale: locale)
    }

    private var detail: String {
        let bundle = Bundle.appLanguage()
        var parts: [String] = []
        if let cycleDay = summary.cycleDay {
            parts.append(String(localized: "周期第 \(cycleDay) 天", bundle: bundle, locale: locale))
        }
        if let next = summary.nextStart {
            let date = next.formatted(Date.FormatStyle().month(.abbreviated).day().locale(locale))
            parts.append(String(localized: "预计 \(date)", bundle: bundle, locale: locale))
        }
        if let average = summary.averageCycle {
            parts.append(String(localized: "平均周期 \(average) 天", bundle: bundle, locale: locale))
        } else {
            parts.append(String(localized: "按 28 天估算", bundle: bundle, locale: locale))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionRow: some View {
        if let openRecord {
            Button {
                CycleStore.endToday(records: [openRecord], context: context)
            } label: {
                Label("经期结束了", systemImage: "checkmark.circle")
            }
        } else if !inPeriod {
            Button {
                CycleStore.startToday(records: records, context: context)
            } label: {
                Label("经期开始了", systemImage: "drop.fill")
            }
        }
    }
}

// MARK: - 历史

struct CycleHistoryView: View {
    let healthPeriods: [CyclePlan.Period]

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\PeriodRecord.start, order: .reverse)]) private var records: [PeriodRecord]
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @State private var editing: PeriodRecord?
    @State private var adding = false

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }

    private var periods: [CyclePlan.Period] {
        CyclePlan.merge(manual: records.map(\.period), health: healthPeriods, today: Date()).reversed()
    }

    private var summary: CyclePlan.Summary { CyclePlan.summary(periods, today: Date()) }

    var body: some View {
        List {
            Section {
                LabeledContent("平均周期") {
                    Text(summary.averageCycle.map { "\($0)" } ?? "—").monospacedDigit()
                }
                LabeledContent("平均经期") {
                    Text(summary.averagePeriod.map { "\($0)" } ?? "—").monospacedDigit()
                }
                if let variation = summary.variation {
                    LabeledContent("周期波动") {
                        Text("\(variation)").monospacedDigit()
                    }
                }
            } footer: {
                Text("单位:天。只算最近 6 个周期,明显漏记的(短于 15 天或长于 60 天)不计入。")
            }
            Section("记录") {
                ForEach(Array(periods.enumerated()), id: \.offset) { index, period in
                    row(period, cycleLength: cycleLength(after: index))
                }
            }
        }
        .pageTitle("经期记录")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("补记一次经期")
            }
        }
        .sheet(isPresented: $adding) { PeriodEditView(record: nil) }
        .sheet(item: $editing) { PeriodEditView(record: $0) }
    }

    /// periods 是从近到远排的:第 index 段的周期长度 = 它的开始日到上一段(更近那段)开始日。
    private func cycleLength(after index: Int) -> Int? {
        guard index > 0 else { return nil }
        return Calendar.current.dateComponents([.day], from: periods[index].start,
                                               to: periods[index - 1].start).day
    }

    @ViewBuilder
    private func row(_ period: CyclePlan.Period, cycleLength: Int?) -> some View {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        let end = period.end.map { $0.formatted(style) }
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(end.map { "\(period.start.formatted(style)) – \($0)" } ?? period.start.formatted(style))
                .font(.body.weight(.medium))
            HStack(spacing: 6) {
                if let end = period.end {
                    let days = (Calendar.current.dateComponents([.day], from: period.start, to: end).day ?? 0) + 1
                    Text("经期 \(days) 天")
                } else {
                    Text("还没结束")
                }
                if let cycleLength {
                    Text("·")
                    Text("周期 \(cycleLength) 天")
                }
                if period.fromHealth {
                    Text("·")
                    Text("来自健康 App")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if case .manual(let id) = period.source, let record = records.first(where: { $0.uuid == id }) {
            Button { editing = record } label: { content.contentShape(Rectangle()) }
                .pressableCard()
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        context.delete(record)
                        try? context.save()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
        } else {
            content
        }
    }
}

// MARK: - 编辑

struct PeriodEditView: View {
    let record: PeriodRecord?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var start: Date
    @State private var hasEnd: Bool
    @State private var end: Date
    @State private var note: String

    init(record: PeriodRecord?) {
        self.record = record
        let today = Calendar.current.startOfDay(for: Date())
        _start = State(initialValue: record?.start ?? today)
        _hasEnd = State(initialValue: record == nil ? true : record?.end != nil)
        _end = State(initialValue: record?.end
                     ?? Calendar.current.date(byAdding: .day, value: 4, to: record?.start ?? today) ?? today)
        _note = State(initialValue: record?.note ?? "")
    }

    private var valid: Bool { !hasEnd || end >= Calendar.current.startOfDay(for: start) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("开始", selection: $start, in: ...Date(), displayedComponents: .date)
                    Toggle("已经结束", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("结束", selection: $end, in: start..., displayedComponents: .date)
                    }
                }
                Section("备注") {
                    TextField("可选", text: $note, axis: .vertical)
                }
                if let record {
                    Section {
                        Button("删除这次记录", role: .destructive) {
                            context.delete(record)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .pageTitle(record == nil ? "补记经期" : "编辑经期")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!valid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 320)
        #endif
    }

    private func save() {
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: start)
        let endDay = hasEnd ? max(startDay, calendar.startOfDay(for: end)) : nil
        let target = record ?? {
            let created = PeriodRecord(start: startDay)
            context.insert(created)
            return created
        }()
        target.start = startDay
        target.end = endDay
        target.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        try? context.save()
        dismiss()
    }
}
