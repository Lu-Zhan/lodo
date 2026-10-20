import SwiftUI
import SwiftData
import Charts
import LodoCore

// 健康页「经期」一组:今天是经期第几天 / 离下次还有几天、「经期开始了 / 结束了」一键记、
// 历史记录、经期提醒。纯计算在 LodoCore/CyclePlan.swift,合并与提醒在 CycleStore。
//
// 显不显示由设置里的「经期记录」决定(`AppSettings.cycleTrackingEnabled`:自动 = 健康 App
// 里是女性才开)。和健康开关无关:手记就能用,Mac 上也有;开了健康分析时再把健康 App 里的
// 经期记录合并进来(手记优先)。经期数据不发给 AI。

/// 健康 App 里读来的经期 + 经期提醒的协调器,只有这一份。
///
/// - **读**:健康页根节点按配置(经期开关、健康分析开关、下拉刷新次数)调 `refresh`。读取跑在
///   这里自己持有的任务上,**不随页面消失被取消**(推进二级页时根页面的 `.task` 会被取消,
///   读到一半丢掉的话,详情页里的改动就只能拿不全的数据去排提醒)。同一组配置读过、或正在读,
///   就不再读;每次领一个代次,回来时代次不对(又发了新的、开关被关了)就作废。
/// - **重排提醒**:写入点(开始/结束、补记、编辑、删除、切提醒开关)直接调
///   `CycleStore.rescheduleFromRecords`;**健康数据还没就绪时那一下不排**(`ready` 为 false),
///   等这里读完统一按最新数据排一次——不然只看到手记,会把按健康 App 历史排好的提醒撤掉。
@MainActor
@Observable
final class CycleHealthPeriods {
    static let shared = CycleHealthPeriods()
    private(set) var periods: [CyclePlan.Period] = []
    /// 健康 App 每天的出血量档位(和 `periods` 同一次读来)。
    private(set) var flows: [CycleFlow.HealthSample] = []
    /// `periods` 是不是当前配置下读完的结果(没开健康分析时直接算就绪:健康那一半本来就是空的)。
    private(set) var ready = false
    private var loadedKey: String?
    private var loading: (key: String, task: Task<Void, Never>)?
    private var generation = 0
    /// 最近一次的配置,写入点在没人发起过读取时(理论上不会)按它补一次。
    private var lastToken = 0

    func refresh(enabled: Bool, healthEnabled: Bool, token: Int, context: ModelContext) {
        lastToken = token
        guard enabled else {
            // 经期关了:作废在途的读取,清掉健康那一半(提醒在设置页关开关时已经撤了)。
            generation += 1
            loading?.task.cancel()
            loading = nil
            periods = []
            flows = []
            loadedKey = nil
            ready = false
            return
        }
        let key = "\(healthEnabled)-\(token)"
        guard key != loadedKey, loading?.key != key else { return }
        generation += 1
        let current = generation
        loading?.task.cancel()
        loading = nil
        ready = false
        guard healthEnabled, HealthKitBridge.isAvailable else {
            periods = []
            flows = []
            loadedKey = key
            ready = true
            CycleStore.rescheduleFromRecords(context: context)
            return
        }
        let task = Task { @MainActor [weak self] in
            // 经期的读权限单独问(不在健康分析那张总授权单里),第一次时问一次。
            let askedKey = "cycleAccessRequested"
            if !UserDefaults.standard.bool(forKey: askedKey) {
                UserDefaults.standard.set(true, forKey: askedKey)
                await HealthKitBridge.requestCycleAuthorization()
            }
            let result = await CycleStore.healthData()
            // 期间又发了新的一次(那一次已经接手了 `loading`):这份不要。
            guard let self, current == self.generation else { return }
            // 还是最新的这一次:不管用不用结果,都不再算"正在读",同一配置之后可以重读。
            self.loading = nil
            // 读的时候健康分析被关了:这份不要(关掉的那次 refresh 会按手记重排)。
            guard !Task.isCancelled, AppSettings.healthEnabled else { return }
            self.periods = result.periods
            self.flows = result.flows
            self.loadedKey = key
            self.ready = true
            CycleStore.rescheduleFromRecords(context: context)
        }
        loading = (key, task)
    }

    /// 回前台:健康 App 里可能有了新数据,按当前设置强制重读一次(读完统一重排)。
    func reload(context: ModelContext) {
        loadedKey = nil
        if let loading { loading.task.cancel() }
        loading = nil
        refresh(enabled: AppSettings.cycleTrackingEnabled, healthEnabled: AppSettings.healthEnabled,
                token: lastToken, context: context)
    }

    /// 写入点要重排时健康数据还没就绪:没在读就按当前设置补发一次(读完会统一重排)。
    func ensureLoading(context: ModelContext) {
        guard !ready, loading == nil else { return }
        refresh(enabled: AppSettings.cycleTrackingEnabled, healthEnabled: AppSettings.healthEnabled,
                token: lastToken, context: context)
    }
}

// MARK: - 共用的计算

/// 经期界面共用的一份计算:手记 + 健康 App → 合并后的经期、预测、每天的出血量。
/// 首页精简行和详情页都从这里取,数字和日子逐字一致。
struct CycleModel {
    let periods: [CyclePlan.Period]
    let prediction: CyclePrediction.Result
    let flows: [String: CycleFlow.Day]
    /// 当前这一段(合并后最近那次)是还开着的手记时,就是那条——操作只动这一条,不会去结束
    /// 一条不相干的、很早以前忘了点结束的旧记录。
    let openRecord: PeriodRecord?

    @MainActor
    init(records: [PeriodRecord], flowRecords: [PeriodFlowRecord], now: Date) {
        let shared = CycleHealthPeriods.shared
        periods = CyclePlan.merge(manual: records.map(\.period), health: shared.periods, today: now)
        prediction = CyclePrediction.predict(periods, today: now,
                                             confirmations: CycleConfirmations.shared.value)
        flows = CycleFlow.resolve(manual: flowRecords.map(\.entry), health: shared.flows)
        let today = Calendar.current.startOfDay(for: now)
        if let current = periods.last(where: { $0.start <= today }), current.end == nil,
           case .manual(let id) = current.source {
            openRecord = records.first { $0.uuid == id }
        } else {
            openRecord = nil
        }
    }

    /// 某一天在不在记录的经期里。每段的边界:有结束日按结束日;当前这段开着的按预计结束范围
    /// 上界;更早开着没结束的按典型天数;都不越过下一次开始的前一天。和主卡判「经期中 /
    /// 待确认」用同一套边界。
    func contains(day: Date, now: Date) -> Bool {
        let calendar = Calendar.current
        let target = calendar.startOfDay(for: day)
        let today = calendar.startOfDay(for: now)
        let past = periods.filter { $0.start <= today }
        for (index, period) in past.enumerated() where period.start <= target {
            var end: Date
            if let known = period.end {
                end = known
            } else if index == past.count - 1, let upper = prediction.currentEnd?.upper {
                end = upper
            } else {
                end = calendar.date(byAdding: .day, value: prediction.periodLength - 1, to: period.start) ?? period.start
            }
            if index + 1 < past.count,
               let beforeNext = calendar.date(byAdding: .day, value: -1, to: past[index + 1].start) {
                end = min(end, beforeNext)
            }
            if target <= end { return true }
        }
        return false
    }

    var hasRecords: Bool { !periods.isEmpty }

    /// 当前这一段是健康 App 里的(没有手记盖着)。经期中点「经期结束了」时按它补一条手记。
    var lastHealthPeriod: CyclePlan.Period? {
        guard let last = periods.last(where: { $0.start <= Date() }), last.fromHealth else { return nil }
        return last
    }

    /// 在经期里(含"结束待确认")。
    var inPeriod: Bool {
        switch prediction.phase {
        case .inPeriod, .endUnconfirmed: return true
        default: return false
        }
    }

    /// 最近一次经期每天的 key(进行中的算到今天;记了结束日的算到结束日),给出血量那一排用。
    func recentPeriodDays(now: Date) -> [String] {
        guard let last = periods.last(where: { $0.start <= now }) else { return [] }
        let today = Calendar.current.startOfDay(for: now)
        let end = min(last.end ?? today, today)
        return CycleFlow.dayKeys(from: last.start, through: max(end, last.start))
    }
}

/// 跨 0 点刷新"今天":一直开着的页面也要换到新的一天(倒计时、今天的出血量)。
private struct MidnightRefresh: ViewModifier {
    @Binding var now: Date
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { now = Date() }
            }
            .task(id: Calendar.current.startOfDay(for: now)) {
                let calendar = Calendar.current
                guard let midnight = calendar.date(byAdding: .day, value: 1,
                                                   to: calendar.startOfDay(for: now)) else { return }
                try? await Task.sleep(for: .seconds(max(1, midnight.timeIntervalSinceNow + 1)))
                guard !Task.isCancelled else { return }
                now = Date()
            }
    }
}

/// 经期界面的文案(视图外拼的,按应用内语言取)。
enum CycleText {
    private static var bundle: Bundle { .appLanguage() }

    static func date(_ date: Date, locale: Locale) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    /// 「11月11日—17日」;同一天就只写一天。
    static func range(_ lower: Date, _ upper: Date, locale: Locale) -> String {
        guard upper > lower else { return date(lower, locale: locale) }
        return (lower..<upper).formatted(Date.IntervalFormatStyle().month(.abbreviated).day().locale(locale))
    }

    static func level(_ level: CycleFlowLevel?, locale: Locale) -> String {
        switch level {
        case .none?: return String(localized: "无", bundle: bundle, locale: locale)
        case .light?: return String(localized: "少", bundle: bundle, locale: locale)
        case .medium?: return String(localized: "中", bundle: bundle, locale: locale)
        case .heavy?: return String(localized: "多", bundle: bundle, locale: locale)
        case .unspecified?: return String(localized: "有出血,未分档", bundle: bundle, locale: locale)
        case nil: return String(localized: "未知档位", bundle: bundle, locale: locale)
        }
    }

    static func evidence(_ evidence: CyclePrediction.Evidence?, locale: Locale) -> String? {
        switch evidence {
        case .low?: return String(localized: "预测依据较少", bundle: bundle, locale: locale)
        case .medium?: return String(localized: "预测依据一般", bundle: bundle, locale: locale)
        case .high?: return String(localized: "预测依据较充分", bundle: bundle, locale: locale)
        case nil: return nil
        }
    }

    /// 主卡片 / 首页那一句大字。
    static func headline(_ p: CyclePrediction.Result, locale: Locale) -> String {
        switch p.phase {
        case .noRecords:
            return String(localized: "从这次经期开始记录", bundle: bundle, locale: locale)
        case .endUnconfirmed:
            return String(localized: "结束日期待确认", bundle: bundle, locale: locale)
        case .inPeriod(let day):
            guard let left = p.daysUntilEnd else {
                return String(localized: "经期第 \(day) 天", bundle: bundle, locale: locale)
            }
            if left > 0 { return String(localized: "预计还有 \(left) 天结束", bundle: bundle, locale: locale) }
            if left == 0 { return String(localized: "预计今天结束", bundle: bundle, locale: locale) }
            return String(localized: "可能这几天结束", bundle: bundle, locale: locale)
        case .insufficient:
            return String(localized: "继续记录,了解下次时间", bundle: bundle, locale: locale)
        case .before:
            let days = p.daysUntilStart ?? 0
            return String(localized: "预计还有 \(days) 天到来", bundle: bundle, locale: locale)
        case .inWindow:
            return String(localized: "可能这几天到来", bundle: bundle, locale: locale)
        case .late(let days):
            return String(localized: "已超出预计范围 \(days) 天", bundle: bundle, locale: locale)
        }
    }

    /// 大字下面那一行(首页也用这一行)。
    static func subline(_ p: CyclePrediction.Result, locale: Locale) -> String? {
        switch p.phase {
        case .noRecords:
            return String(localized: "记下开始和结束,lodo 会慢慢了解你的周期", bundle: bundle, locale: locale)
        case .endUnconfirmed(let day):
            return String(localized: "已记录到经期第 \(day) 天", bundle: bundle, locale: locale)
        case .inPeriod(let day):
            guard let start = p.lastStart else { return nil }
            return String(localized: "经期第 \(day) 天 · \(date(start, locale: locale))开始", bundle: bundle, locale: locale)
        case .insufficient:
            if let length = p.lastIntervalLength {
                return String(localized: "上次周期 \(length) 天,再记一次就能预测", bundle: bundle, locale: locale)
            }
            return String(localized: "再记一两次经期,就能预测下次时间", bundle: bundle, locale: locale)
        case .before, .inWindow:
            guard let next = p.nextStart else { return nil }
            return String(localized: "可能为 \(range(next.lower, next.upper, locale: locale))", bundle: bundle, locale: locale)
        case .late:
            if p.startRevised, let next = p.nextStart {
                return String(localized: "可能为 \(range(next.lower, next.upper, locale: locale))", bundle: bundle, locale: locale)
            }
            guard let next = p.nextStart else { return nil }
            return String(localized: "原预计 \(range(next.lower, next.upper, locale: locale))", bundle: bundle, locale: locale)
        }
    }
}

// MARK: - 主卡片

/// 详情页最上面那张:一句大字回答"还有几天来 / 还有几天结束",下面是日子、范围、依据,最后是主操作。
private struct CycleHeroCard: View {
    let model: CycleModel
    let locale: Locale
    let onAddPast: () -> Void
    let onEditOpen: (PeriodRecord) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.lodoAccent) private var lodoAccent
    @Query(sort: [SortDescriptor(\PeriodRecord.start)]) private var records: [PeriodRecord]

    private var p: CyclePrediction.Result { model.prediction }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.inPeriod ? "本次经期" : "下次经期", systemImage: model.inPeriod ? "drop.fill" : "calendar")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: CycleText.headline(p, locale: locale))
                    .font(.largeTitle.bold())
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let sub = CycleText.subline(p, locale: locale) {
                    Text(verbatim: sub)
                        .font(.body)
                }
            }
            details
            actions
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch p.phase {
            case .inPeriod:
                if let end = p.currentEnd {
                    Text("预计 \(CycleText.date(end.center, locale: locale)) 结束")
                    if end.upper > end.lower {
                        Text("可能为 \(CycleText.range(end.lower, end.upper, locale: locale))")
                            .foregroundStyle(.secondary)
                    }
                }
                if p.endRevised {
                    Text("已按「今天还没结束」重新估计").foregroundStyle(.secondary)
                }
                if p.periodLengthIsDefault {
                    Text("还没记过完整的一次,暂按 5 天估算").foregroundStyle(.secondary)
                } else if let evidence = CycleText.evidence(p.endEvidence, locale: locale) {
                    Text("\(evidence) · \(p.endSamples) 次完整经期").foregroundStyle(.secondary)
                }
            case .before, .inWindow, .late:
                if let next = p.nextStart {
                    Text("预计 \(CycleText.date(next.center, locale: locale)) 开始")
                }
                if let end = p.nextEnd {
                    Text("预计结束范围 \(CycleText.range(end.lower, end.upper, locale: locale))")
                        .foregroundStyle(.secondary)
                }
                if p.startRevised, let original = p.originalNextStart {
                    Text("已按「今天还没来」重新估计 · 原预计 \(CycleText.range(original.lower, original.upper, locale: locale))")
                        .foregroundStyle(.secondary)
                }
                if case .late = p.phase {
                    Text("可能推迟了,也可能漏记了上一次").foregroundStyle(.secondary)
                }
                if let evidence = CycleText.evidence(p.startEvidence, locale: locale) {
                    Text("\(evidence) · \(p.validCycles) 个有效周期")
                        .foregroundStyle(.secondary)
                }
                if let next = p.nextStart,
                   (Calendar.current.dateComponents([.day], from: next.lower, to: next.upper).day ?? 0) > 14 {
                    Text("近期周期波动较大,范围比较宽").foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var actions: some View {
        if case .endUnconfirmed = p.phase, let open = model.openRecord {
            // 过了预计范围还没点结束:多半是忘了点,先补结束日;也可能这是新的一次。
            primary("补记结束日", systemImage: "calendar.badge.checkmark") { onEditOpen(open) }
            Button("这是新的一次开始") {
                Haptics.success()
                CycleStore.startToday(records: records, context: context)
            }
            .buttonStyle(.borderless)
            stillGoing
        } else if let open = model.openRecord, model.inPeriod {
            primary("经期结束了", systemImage: "checkmark.circle") {
                CycleStore.endToday(records: [open], context: context)
            }
            stillGoing
        } else if model.inPeriod, let health = model.lastHealthPeriod {
            // 这次经期只在健康 App 里:结束时补一条手记盖住它(健康 App 里的不改)。
            primary("经期结束了", systemImage: "checkmark.circle") {
                CycleStore.endHealthPeriod(start: health.start, context: context)
            }
            stillGoing
        } else if !model.inPeriod {
            primary("经期开始了", systemImage: "drop.fill") {
                CycleStore.startToday(records: records, context: context)
            }
            notYet
            if case .noRecords = p.phase {
                Button("补记以前的经期") { onAddPast() }
                    .buttonStyle(.borderless)
            } else if case .late = p.phase {
                Button("补记上一次经期") { onAddPast() }
                    .buttonStyle(.borderless)
            }
        }
    }

    /// 「今天还没结束」:到了或过了预计结束的日子还在经期里时给(还早的时候点了也没有新信息)。
    /// 今天已经确认过就换成一行说明 + 撤销。
    @ViewBuilder
    private var stillGoing: some View {
        if p.endRevised, let d = CycleConfirmations.shared.ongoingThrough,
           Calendar.current.isDateInToday(d) {
            confirmedNote("已确认今天还没结束")
        } else if let end = p.currentEnd, Calendar.current.startOfDay(for: Date()) >= end.lower {
            Button("今天还没结束") {
                Haptics.success()
                CycleStore.confirmOngoing(context: context)
            }
            .buttonStyle(.borderless)
        }
    }

    /// 「今天还没来」:已经在预计范围里或超出范围时给,下次开始按它往后重新估计。
    @ViewBuilder
    private var notYet: some View {
        if p.startRevised, let d = CycleConfirmations.shared.notStartedThrough,
           Calendar.current.isDateInToday(d) {
            confirmedNote("已确认今天还没来")
        } else if isDueOrLate {
            Button("今天还没来") {
                Haptics.success()
                CycleStore.confirmNotStarted(context: context)
            }
            .buttonStyle(.borderless)
        }
    }

    private var isDueOrLate: Bool {
        switch p.phase {
        case .inWindow, .late: return true
        default: return false
        }
    }

    private func confirmedNote(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "checkmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("撤销") { CycleStore.clearConfirmations(context: context) }
                .buttonStyle(.borderless)
                .font(.subheadline)
        }
    }

    private func primary(_ title: LocalizedStringKey, systemImage: String,
                         action: @escaping () -> Void) -> some View {
        Button {
            Haptics.success()
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .foregroundStyle(lodoAccent.onFill)
    }
}

// MARK: - 首页精简版

/// 健康页首页「健康管理」里的经期:一行进详情(醒目的状态 + 范围),下面一颗当下能做的操作。
struct CycleCompactRows: View {
    let healthEnabled: Bool

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\PeriodRecord.start)]) private var records: [PeriodRecord]
    @Query private var flowRecords: [PeriodFlowRecord]
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @State private var now = Date()

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }

    var body: some View {
        let model = CycleModel(records: records, flowRecords: flowRecords, now: now)
        NavigationLink {
            CycleManagementView(healthEnabled: healthEnabled)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: model.inPeriod ? "drop.fill" : "drop")
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("经期")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(verbatim: CycleText.headline(model.prediction, locale: locale))
                        .font(.title3.bold())
                        .monospacedDigit()
                    if let sub = CycleText.subline(model.prediction, locale: locale) {
                        Text(verbatim: sub)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .modifier(MidnightRefresh(now: $now))
        // 链接和按钮各占一行,不把按钮嵌在链接里。
        if case .endUnconfirmed = model.prediction.phase {
            // 补结束日要选日子,进详情做;这里不放一个会写错日子的「结束了」。
        } else if let open = model.openRecord, model.inPeriod {
            Button {
                Haptics.success()
                CycleStore.endToday(records: [open], context: context)
            } label: {
                Label("经期结束了", systemImage: "checkmark.circle")
            }
        } else if model.inPeriod, let health = model.lastHealthPeriod {
            Button {
                Haptics.success()
                CycleStore.endHealthPeriod(start: health.start, context: context)
            } label: {
                Label("经期结束了", systemImage: "checkmark.circle")
            }
        } else if !model.inPeriod {
            Button {
                Haptics.success()
                CycleStore.startToday(records: records, context: context)
            } label: {
                Label("经期开始了", systemImage: "drop.fill")
            }
        }
    }
}

// MARK: - 出血量

/// 「出血量」一组:今天一键选档、最近这次经期每天一格、补记别的日子。
private struct CycleFlowSection: View {
    let model: CycleModel
    let locale: Locale

    @Environment(\.modelContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: [SortDescriptor(\PeriodRecord.start)]) private var records: [PeriodRecord]
    @State private var editingDay: Date?
    @State private var askStart: CycleFlowLevel?
    @State private var saveFailed = false
    /// 刚清掉今天的手记、露出了健康 App 的那一条:说一声(不然像是没清掉)。
    @State private var revealedHealth = false

    private var today: Date { Calendar.current.startOfDay(for: Date()) }
    private var todayDay: CycleFlow.Day? { model.flows[CycleFlow.dayKey(today)] }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("今天 \(CycleText.date(today, locale: locale))")
                        .font(.body.weight(.medium))
                    Spacer()
                    if let day = todayDay {
                        Text(verbatim: CycleText.level(day.level, locale: locale)
                             + (day.source == .health ? " · " + String(localized: "来自健康 App", bundle: .appLanguage(), locale: locale) : ""))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("未记").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { allLevelButtons }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) { levelButtons(Array(CycleFlowLevel.selectable.prefix(2))) }
                        HStack(spacing: 8) { levelButtons(Array(CycleFlowLevel.selectable.suffix(2))) }
                    }
                }
                if saveFailed {
                    Text("没能保存,请再试一次。")
                        .font(.caption)
                        .foregroundStyle(LodoColor.critical)
                } else if revealedHealth, todayDay?.source == .health {
                    Text("已清除手记,现在显示的是健康 App 里这一天的记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("再点一下已选的那一档就清掉。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            let days = model.recentPeriodDays(now: Date())
            if !days.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.inPeriod ? "本次经期每天" : "上次经期每天")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(days, id: \.self) { key in
                                    dayCell(key).id(key)
                                }
                            }
                        }
                        .onAppear { proxy.scrollTo(days.last, anchor: .trailing) }
                    }
                }
                .padding(.vertical, 2)
            } else if model.flows.isEmpty {
                Text("出血量按天记,没记的日子会留空,不会当成「无」。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !model.flows.isEmpty {
                NavigationLink {
                    CycleFlowListView()
                } label: {
                    HStack {
                        Text("全部出血量记录")
                        Spacer()
                        Text("\(model.flows.count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        } header: {
            HStack {
                Text("出血量")
                Spacer()
                Button("补记") { editingDay = today }
                    .font(.subheadline)
                    .textCase(nil)
                    .accessibilityLabel("补记出血量")
            }
            // sheet/alert 挂在标题行上:挂在 Section 上会分摊到每一行。
            .sheet(item: Binding(get: { editingDay.map(FlowDayTarget.init) },
                                 set: { editingDay = $0?.day })) { target in
                PeriodFlowEditView(day: target.day, model: model)
            }
            .alert("把今天记为经期开始?", isPresented: Binding(
                get: { askStart != nil }, set: { if !$0 { askStart = nil } }
            )) {
                Button("只记出血量", role: .cancel) {
                    if let level = askStart { saveFailed = !CycleStore.setFlow(level, on: today, context: context) }
                    askStart = nil
                }
                Button("记为开始") {
                    if let level = askStart {
                        saveFailed = !(CycleStore.startToday(records: records, context: context)
                                       && CycleStore.setFlow(level, on: today, context: context))
                    }
                    askStart = nil
                }
            } message: {
                Text("今天不在记录的经期里。记为开始会从今天开一次新的经期。")
            }
        }
    }

    private var allLevelButtons: some View { levelButtons(CycleFlowLevel.selectable) }

    private func levelButtons(_ levels: [CycleFlowLevel]) -> some View {
        ForEach(levels, id: \.self) { level in
            let selected = todayDay?.source == .manual && todayDay?.level == level
            Button {
                Haptics.impact(.light)
                if selected {
                    saveFailed = !CycleStore.clearFlow(on: today, context: context)
                    revealedHealth = !saveFailed
                        && CycleHealthPeriods.shared.flows.contains { $0.dayKey == CycleFlow.dayKey(today) }
                } else if level.isBleeding, !model.inPeriod {
                    askStart = level
                } else {
                    saveFailed = !CycleStore.setFlow(level, on: today, context: context)
                }
            } label: {
                Label {
                    Text(verbatim: CycleText.level(level, locale: locale))
                } icon: {
                    if selected { Image(systemName: "checkmark") }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .tint(selected ? Color.accentColor : .secondary)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    private func dayCell(_ key: String) -> some View {
        let date = CycleFlow.date(fromKey: key) ?? today
        let day = model.flows[key]
        return Button {
            editingDay = date
        } label: {
            VStack(spacing: 4) {
                Text(date.formatted(.dateTime.month(.defaultDigits).day().locale(locale)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(verbatim: day.map { CycleText.level($0.level, locale: locale) }
                     ?? String(localized: "未记", bundle: .appLanguage(), locale: locale))
                    .font(.subheadline.weight(day == nil ? .regular : .semibold))
                    .foregroundStyle(day == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
            .frame(minWidth: 48, minHeight: 48)
            .background(RoundedRectangle(cornerRadius: 10).fill(.fill.tertiary))
        }
        .pressable()
    }
}

/// sheet(item:) 要 Identifiable。
private struct FlowDayTarget: Identifiable {
    let day: Date
    var id: Date { day }
}

/// 补记 / 改某一天的出血量。
struct PeriodFlowEditView: View {
    let model: CycleModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @State private var day: Date
    @State private var level: CycleFlowLevel
    @State private var saveFailed = false
    @State private var askStart = false

    init(day: Date, model: CycleModel) {
        self.model = model
        _day = State(initialValue: day)
        let current = model.flows[CycleFlow.dayKey(day)]?.level
        _level = State(initialValue: current ?? .light)
    }

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }
    private var hasManual: Bool { model.flows[CycleFlow.dayKey(day)]?.source == .manual }

    private func save() {
        guard CycleStore.setFlow(level, on: day, context: context) else {
            saveFailed = true
            return
        }
        Haptics.success()
        if level.isBleeding, !model.contains(day: day, now: Date()) {
            askStart = true
        } else {
            dismiss()
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("日期", selection: $day, in: ...Date(), displayedComponents: .date)
                    Picker("出血量", selection: $level) {
                        ForEach(CycleFlowLevel.allCases, id: \.self) { item in
                            Text(verbatim: CycleText.level(item, locale: locale)).tag(item)
                        }
                    }
                } footer: {
                    if saveFailed {
                        Text("没能保存,请再试一次。").foregroundStyle(LodoColor.critical)
                    } else if model.flows[CycleFlow.dayKey(day)]?.conflict == true {
                        Text("健康 App 里这一天的记录不一致(既有「无」又有出血);这里记的会优先显示。")
                    } else if model.flows[CycleFlow.dayKey(day)]?.source == .health {
                        Text("这一天健康 App 里有记录;这里记的会优先显示,健康 App 里的不会被改动。")
                    }
                }
                if hasManual {
                    Section {
                        Button("清除这一天的记录", role: .destructive) {
                            if CycleStore.clearFlow(on: day, context: context) { dismiss() } else { saveFailed = true }
                        }
                    } footer: {
                        Text("清除后,如果健康 App 里这一天有记录,会改为显示健康 App 的。")
                    }
                }
            }
            .formStyle(.grouped)
            .pageTitle("记出血量")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            // 换了日子:那天有记录就显示它的,没有就回到默认档,不沿用上一个日子的。
            .onChange(of: day) { _, newDay in
                level = model.flows[CycleFlow.dayKey(newDay)]?.level ?? .light
            }
            .alert("把这一天记为经期开始?", isPresented: $askStart) {
                Button("只记出血量", role: .cancel) { dismiss() }
                Button("记为开始") {
                    if CycleStore.startPeriod(on: day, context: context) { dismiss() } else { saveFailed = true }
                }
            } message: {
                Text("这一天不在记录的经期里。记为开始会从这一天开一次新的经期。")
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 280)
        #endif
    }
}

// MARK: - 周期变化

/// 「周期变化」:典型周期 / 经期、规律程度,最近 6 个完整周期的横条(整条 = 周期长度,
/// 前面实心的一截 = 那次经期天数)。疑似漏记的照原长度画、标出来,不拆成两个假周期。
private struct CycleChartSection: View {
    let model: CycleModel
    let locale: Locale

    @Environment(\.lodoAccent) private var lodoAccent

    /// 截图参数 --demo-cycle-scroll 滚到这一组。
    static let anchor = "cycleChartAnchor"

    private struct Bar: Identifiable {
        let id: Date
        let label: String
        let length: Int
        let period: Int?
        let excluded: CyclePrediction.ExclusionReason?
    }

    private var bars: [Bar] {
        model.prediction.intervals.prefix(6).reversed().map { interval in
            Bar(id: interval.start, label: CycleText.date(interval.start, locale: locale),
                length: interval.length, period: interval.periodLength, excluded: interval.excluded)
        }
    }

    var body: some View {
        let p = model.prediction
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    stat("典型周期", value: p.cycleLength)
                    stat("典型经期", value: p.periodLengthIsDefault ? nil : p.periodLength)
                }
                if let stable = p.stable {
                    Text(stable ? "近期记录较稳定" : "近期波动较大")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let range = p.cycleRange, range.lowerBound != range.upperBound {
                    Text("近期周期 \(range.lowerBound)–\(range.upperBound) 天")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if p.skippedCount > 0 {
                    Text("有 \(p.skippedCount) 段间隔可能漏记,没有用于预测")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .id(Self.anchor)

            if bars.isEmpty {
                Text("记过两次以上经期,这里会画出每个周期有多长。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Chart(bars) { bar in
                    BarMark(xStart: .value("开始", 0), xEnd: .value("周期", bar.length),
                            y: .value("日期", bar.label))
                        .foregroundStyle(Color.secondary.opacity(bar.excluded == nil ? 0.25 : 0.12))
                        .annotation(position: .trailing) {
                            Text(annotation(bar))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    if let period = bar.period {
                        BarMark(xStart: .value("开始", 0), xEnd: .value("经期", period),
                                y: .value("日期", bar.label))
                            .foregroundStyle(lodoAccent.accent)
                    }
                }
                .chartXAxis(.hidden)
                .chartXScale(domain: 0...(Double(bars.map(\.length).max() ?? 30) * 1.25))
                .frame(height: CGFloat(bars.count) * 30 + 10)
                .padding(.vertical, 4)
                .accessibilityLabel(Text("最近 \(bars.count) 个周期的长度"))
                HStack(spacing: 12) {
                    legend(color: lodoAccent.accent, text: "经期天数(记了结束日的)")
                    legend(color: Color.secondary.opacity(0.25), text: "整个周期")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            NavigationLink {
                CycleHistoryView()
            } label: {
                HStack {
                    Text("全部经期记录")
                    Spacer()
                    Text("\(model.periods.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } header: {
            Text("周期变化")
        }
    }

    private func annotation(_ bar: Bar) -> String {
        let bundle = Bundle.appLanguage()
        switch bar.excluded {
        case .likelySkipped?:
            return String(localized: "\(bar.length) 天 · 可能漏记", bundle: bundle, locale: locale)
        case .outOfRange?:
            return String(localized: "\(bar.length) 天 · 未用于预测", bundle: bundle, locale: locale)
        case nil:
            return String(localized: "\(bar.length) 天", bundle: bundle, locale: locale)
        }
    }

    private func stat(_ title: LocalizedStringKey, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            if let value {
                Text("\(value) 天").font(.title3.weight(.semibold).monospacedDigit())
            } else {
                Text("—").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(color: Color, text: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 8)
            Text(text)
        }
    }
}

// MARK: - 详情页

/// 「经期详情」:主卡片 → 出血量 → 周期变化 → 提醒 → 说明。读健康 App、重排提醒不在这里做
/// (`CycleHealthPeriods` 管,写入点直接调重排),这一页只看共享的那份数据。
struct CycleSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\PeriodRecord.start)]) private var records: [PeriodRecord]
    @Query private var flowRecords: [PeriodFlowRecord]
    @AppStorage(AppSettings.cycleReminderEnabledKey) private var reminderEnabled = true
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue

    @State private var now = Date()
    @State private var addingPast = false
    @State private var editing: PeriodRecord?

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }

    var body: some View {
        let model = CycleModel(records: records, flowRecords: flowRecords, now: now)
        Section {
            CycleHeroCard(model: model, locale: locale,
                          onAddPast: { addingPast = true }, onEditOpen: { editing = $0 })
        } header: {
            HStack {
                Spacer()
                Button("补记") { addingPast = true }
                    .font(.subheadline)
                    .textCase(nil)
                    .accessibilityLabel("补记一次经期")
            }
            // sheet 挂在标题行上:挂在 Section 上会分摊到每一行。
            .sheet(isPresented: $addingPast) { PeriodEditView(record: nil) }
            .sheet(item: $editing) { PeriodEditView(record: $0) }
            .modifier(MidnightRefresh(now: $now))
        }

        CycleFlowSection(model: model, locale: locale)
        CycleChartSection(model: model, locale: locale)

        Section {
            Toggle(isOn: $reminderEnabled) {
                Label("经期提醒", systemImage: "bell")
            }
            .onChange(of: reminderEnabled) { _, _ in
                CycleStore.rescheduleFromRecords(context: context)
            }
        } header: {
            Text("提醒")
        } footer: {
            if model.prediction.canRemind {
                Text("在预计范围开始前 2 天的 \(AppSettings.allDayTime) 提醒一次。")
            } else {
                Text("记录更多周期、预测稳定之后才会提醒。")
            }
        }

        Section {
        } footer: {
            Text("预测按最近几个周期估算出一个经验范围,仅供参考,不能用于避孕。经期和出血量只存在这台设备和你的 iCloud 里,不会发给 AI。")
        }
    }
}

/// 健康页「经期详情」页。
struct CycleManagementView: View {
    let healthEnabled: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List {
                CycleSection()
            }
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--demo-cycle-scroll") else { return }
                try? await Task.sleep(for: .seconds(1.2))
                proxy.scrollTo(CycleChartSection.anchor, anchor: .top)
            }
            #endif
        }
        .pageTitle("经期")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - 历史

struct CycleHistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\PeriodRecord.start, order: .reverse)]) private var records: [PeriodRecord]
    @Query private var flowRecords: [PeriodFlowRecord]
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @State private var editing: PeriodRecord?
    @State private var adding = false
    @State private var pendingDelete: PeriodRecord?

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }

    var body: some View {
        let model = CycleModel(records: records, flowRecords: flowRecords, now: Date())
        let periods = Array(model.periods.reversed())
        List {
            Section {
                LabeledContent("典型周期") {
                    Text(model.prediction.cycleLength.map { "\($0)" } ?? "—").monospacedDigit()
                }
                LabeledContent("典型经期") {
                    Text(model.prediction.periodLengthIsDefault ? "—" : "\(model.prediction.periodLength)")
                        .monospacedDigit()
                }
                if let range = model.prediction.cycleRange {
                    LabeledContent("近期周期") {
                        Text("\(range.lowerBound)–\(range.upperBound)").monospacedDigit()
                    }
                }
            } footer: {
                Text("单位:天。只用最近 6 个有效周期;短于 15 天、长于 90 天或疑似漏记的间隔不计入。")
            }
            Section("记录") {
                ForEach(Array(periods.enumerated()), id: \.element.stableID) { index, period in
                    row(period, index: index, model: model)
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
        .alert("删除这次经期?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let record = pendingDelete {
                    context.delete(record)
                    try? context.save()
                    CycleStore.rescheduleFromRecords(context: context)
                }
                pendingDelete = nil
            }
        } message: {
            Text("只删除这次的起止日期,每天的出血量记录会保留。")
        }
    }

    @ViewBuilder
    private func row(_ period: CyclePlan.Period, index: Int, model: CycleModel) -> some View {
        // 这一段开始的那个周期(到下一次开始);最近一次还没形成完整周期。
        let interval = model.prediction.intervals.first { $0.start == period.start }
        let flowDays = period.end.map { end in
            CycleFlow.dayKeys(from: period.start, through: end).filter { model.flows[$0] != nil }.count
        } ?? 0
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: period.end.map { CycleText.range(period.start, $0, locale: locale) }
                 ?? CycleText.date(period.start, locale: locale))
                .font(.body.weight(.medium))
            HStack(spacing: 6) {
                if let end = period.end {
                    let days = (Calendar.current.dateComponents([.day], from: period.start, to: end).day ?? 0) + 1
                    // 健康 App 的末日只是"最后一天有出血记录",不是确认的结束。
                    if period.fromHealth {
                        // 数健康 App 里真正记了出血的日子(那段允许中间漏一天,首尾跨度会多算;
                        // 也不看手记覆盖后的结果——这一行说的就是健康 App 观察到了什么)。
                        // 直接按日期范围筛(去重后的日子),不经过 dayKeys 那个 60 天的枚举上限。
                        let observed = Set(CycleHealthPeriods.shared.flows
                            .filter { $0.level.isBleeding }.map(\.dayKey))
                            .compactMap { CycleFlow.date(fromKey: $0) }
                            .filter { $0 >= period.start && $0 <= end }.count
                        Text("观察到出血 \(observed) 天")
                    } else {
                        Text("经期 \(days) 天")
                    }
                } else {
                    Text("结束未确认")
                }
                if let interval {
                    Text("·")
                    Text("周期 \(interval.length) 天")
                } else if index == 0 {
                    Text("·")
                    Text("当前周期")
                }
                if period.fromHealth {
                    Text("·")
                    Text("来自健康 App")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if interval?.excluded == .likelySkipped {
                Text("间隔可能漏记了一次,没有用于预测")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if interval?.excluded == .outOfRange {
                Text("间隔太短或太长,没有用于预测")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if flowDays > 0 {
                Text("已记录出血量 \(flowDays) 天")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        if case .manual(let id) = period.source, let record = records.first(where: { $0.uuid == id }) {
            Button { editing = record } label: { content.contentShape(Rectangle()) }
                .pressableCard()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        pendingDelete = record
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    .tint(LodoColor.critical)
                }
        } else {
            content
        }
    }
}

// MARK: - 全部出血量

/// 全部出血量记录(手记 + 健康 App,按天,从近到远)。改了起止日期、落在经期外的那几天也在这里。
struct CycleFlowListView: View {
    @Query(sort: [SortDescriptor(\PeriodRecord.start)]) private var records: [PeriodRecord]
    @Query private var flowRecords: [PeriodFlowRecord]
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @State private var editingDay: Date?

    private var locale: Locale { (AppLanguage(rawValue: languageRaw) ?? .zhHans).locale }

    var body: some View {
        let model = CycleModel(records: records, flowRecords: flowRecords, now: Date())
        let keys = model.flows.keys.sorted(by: >)
        List {
            if keys.isEmpty {
                ContentUnavailableView("还没有出血量记录", systemImage: "drop")
                    .emptyStateFill()
            }
            ForEach(keys, id: \.self) { key in
                let day = model.flows[key]!
                Button {
                    editingDay = CycleFlow.date(fromKey: key)
                } label: {
                    HStack {
                        Text(verbatim: CycleFlow.date(fromKey: key).map {
                            $0.formatted(.dateTime.year().month(.abbreviated).day().weekday(.abbreviated).locale(locale))
                        } ?? key)
                        .foregroundStyle(.primary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(verbatim: CycleText.level(day.level, locale: locale))
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                            if day.source == .health {
                                Text(day.conflict ? "健康 App · 记录不一致" : "来自健康 App")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .pressableCard()
            }
        }
        .pageTitle("出血量记录")
        .sheet(item: Binding(get: { editingDay.map(FlowDayTarget.init) },
                             set: { editingDay = $0?.day })) { target in
            PeriodFlowEditView(day: target.day, model: model)
        }
    }
}

extension CyclePlan.Period {
    /// 列表里的稳定标识:来源 + 开始日(手记用 uuid,同一天的健康 App 那段不会和它撞)。
    var stableID: String {
        switch source {
        case .manual(let id): return id.uuidString
        case .health: return "health-\(start.timeIntervalSince1970)"
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
                            CycleStore.rescheduleFromRecords(context: context)
                            dismiss()
                        }
                    } footer: {
                        Text("只删除这次的起止日期,每天的出血量记录会保留。")
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
        CycleStore.rescheduleFromRecords(context: context)
        dismiss()
    }
}
