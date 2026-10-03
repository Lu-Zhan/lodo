import SwiftUI
import SwiftData
import LodoCore

/// 「倒数日」页:平级页面(侧栏「日历」下面)。每行一件事:标题、起讫时间,
/// 右边是离开始/结束还有多久(或已经过去多久)。点一行进编辑,右上角「+」新建——
/// AI 接不了倒数日这一棒(`command` 协议里没有这个动作),所以和旅行详情的
/// 「手动添加」一样,入口必须留着。
///
/// 三组:「倒数日」(还没到/进行中,按下一个节点从近到远)、「正数日」(已经过去的
/// 日子往上数:在一起、入职、宝宝出生……)、最底下折叠的「已归档」(不想再看到的,
/// 不上小组件、不提醒,可以取消归档)。最上面是 AI 每天一句的建议(「马上两周年啦」)。
struct CountdownListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.sidebarChrome) private var sidebarChrome
    @Environment(\.lodoAccent) private var lodoAccent
    @Query private var events: [CountdownEvent]

    @State private var editing: CountdownEvent?
    @State private var creating = false
    @State private var showArchived = false
    /// 顶部那一句 AI 建议(按天缓存,见 loadInsight)。
    @State private var insight: String?
    private static let insightKeyKey = "countdownInsightKey"
    private static let insightTextKey = "countdownInsightText"
    /// 一分钟刷新一次"还有几小时几分"。
    @State private var now = Date()

    private var sorted: [CountdownEvent] {
        let byID = Dictionary(events.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return CountdownPlan.sorted(events.map(\.entry), now: now).compactMap { byID[$0.id] }
    }

    private var active: [CountdownEvent] { sorted.filter { !$0.archived } }

    private var upcoming: [CountdownEvent] {
        active.filter { !CountdownPlan.isPast($0.entry, now: now) }
    }

    /// 正数日:已经过去的日子。
    private var past: [CountdownEvent] {
        active.filter { CountdownPlan.isPast($0.entry, now: now) }
    }

    private var archivedEvents: [CountdownEvent] { sorted.filter(\.archived) }

    var body: some View {
        NavigationStack {
            List {
                if events.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("还没有倒数日", systemImage: "hourglass")
                        } description: {
                            Text("考试、搬家、演唱会、放假……点右上角的「+」记下日子,这里会一直告诉你还有几天。")
                        } actions: {
                            Button("添加倒数日") { creating = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .emptyStateFill()
                    }
                } else {
                    if let insight {
                        Section {
                            Label {
                                Text(insight)
                                    .font(.body)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.tint)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    if !upcoming.isEmpty || past.isEmpty {
                        Section {
                            if upcoming.isEmpty {
                                Text("没有还没到的日子了。")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(upcoming) { event in row(event) }
                        } header: {
                            Text("倒数日")
                        } footer: {
                            if active.contains(where: \.showInWidget) {
                                Text("带 \(Image(systemName: "lock.fill")) 的会显示在锁屏「倒数日」小组件上。")
                            }
                        }
                    }
                    if !past.isEmpty {
                        Section {
                            ForEach(past) { event in row(event) }
                        } header: {
                            Text("正数日")
                        }
                    }
                    if !archivedEvents.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showArchived) {
                                ForEach(archivedEvents) { event in row(event) }
                            } label: {
                                Text("已归档 · \(archivedEvents.count)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .pageTitle("倒数")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !(sidebarChrome?.hidesChrome ?? false) {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            creating = true
                        } label: {
                            Label("添加倒数日", systemImage: "plus")
                        }
                    }
                }
            }
            .sidebarToolbarButton()
            .askBar(focus: .countdown)
            .sheet(isPresented: $creating) {
                CountdownEditView(event: nil)
            }
            .sheet(item: $editing) { event in
                CountdownEditView(event: event)
            }
            // 顶部那句 AI 建议:日子有变化或到了新的一天才重新要一句。
            .task(id: insightInput) { await loadInsight() }
            .task {
                // 对齐到下一个整分钟再开始每分钟跳一次。
                while !Task.isCancelled {
                    let seconds = 60 - Calendar.current.component(.second, from: Date())
                    try? await Task.sleep(for: .seconds(seconds))
                    now = Date()
                }
            }
            #if DEBUG
            .onAppear(perform: applyDemoArguments)
            #endif
        }
    }

    private func row(_ event: CountdownEvent) -> some View {
        let entry = event.entry
        let spans = CountdownPlan.spans(entry, now: now)
        let isPast = CountdownPlan.isPast(entry, now: now)
        // 倒数日用强调色,正数日用另一种颜色,归档的一律灰。
        let accent: Color = event.archived ? .secondary
            : isPast ? LodoColor.positive : lodoAccent.accent
        return Button {
            editing = event
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(event.title.isEmpty
                             ? String(localized: "(未命名)", bundle: .appLanguage(), locale: AppSettings.language.locale)
                             : event.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if event.showInWidget {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("显示在锁屏小组件")
                        }
                        if !event.startReminders.isEmpty || !event.endReminders.isEmpty {
                            Image(systemName: "bell.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("有提醒")
                        }
                    }
                    Text(dateLine(event))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(CountdownText.text(spans[0], hasEnd: entry.end != nil))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.trailing)
                    if spans.count > 1 {
                        Text(CountdownText.text(spans[1], hasEnd: true))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .pressableCard()
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                context.delete(event)
                save()
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                withAnimation(.lodoAware(.snappy)) {
                    event.archived.toggle()
                    save()
                }
            } label: {
                Label(event.archived ? "取消归档" : "归档",
                      systemImage: event.archived ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(LodoColor.neutralAction)
        }
        .contextMenu {
            Button {
                withAnimation(.lodoAware(.snappy)) {
                    event.archived.toggle()
                    save()
                }
            } label: {
                Label(event.archived ? "取消归档" : "归档",
                      systemImage: event.archived ? "tray.and.arrow.up" : "archivebox")
            }
        }
    }

    private func save() {
        try? context.save()
        CountdownNotifier.reschedule(context: context)
        WidgetBridge.sync(context: context)
    }

    // MARK: - AI 建议

    /// 喂给 AI 的素材;每天的"已经/还有几天"都不同,所以它本身就带着日期。
    private var insightInput: String {
        CountdownPlan.promptSummary(events.map(\.entry), now: Calendar.current.startOfDay(for: now))
    }

    /// 顶部那一句:按"当天 + 素材"缓存在 UserDefaults(纯展示的派生数据,不进库不备份),
    /// 同一天、日子没变就不再请求;失败什么都不显示,不占位置。
    private func loadInsight() async {
        let input = insightInput
        guard !input.isEmpty, DeepSeekClient.isConfigured else {
            insight = nil
            return
        }
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let key = "\(Int(day))|\(AppSettings.language.rawValue)|\(input)"
        let defaults = UserDefaults.standard
        #if DEBUG
        // 截图验证用:跳过缓存,真发一次请求。
        let bypassCache = ProcessInfo.processInfo.arguments.contains("--demo-countdown-insight-live")
        #else
        let bypassCache = false
        #endif
        if !bypassCache, defaults.string(forKey: Self.insightKeyKey) == key,
           let cached = defaults.string(forKey: Self.insightTextKey) {
            insight = cached
            return
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-countdown-insight") {
            insight = "再过 3 天就是在一起两周年啦,想想怎么庆祝"
            return
        }
        #endif
        guard let text = try? await DeepSeekClient.countdownInsight(
            summary: input, language: MenuStore.targetLanguageName(AppSettings.language)) else { return }
        defaults.set(key, forKey: Self.insightKeyKey)
        defaults.set(text, forKey: Self.insightTextKey)
        insight = text
    }

    /// "开始 2026年7月20日 周一 · 结束 7月25日 周六";只有一个日子的就一个日期。
    private func dateLine(_ event: CountdownEvent) -> String {
        let start = CountdownText.dateText(event.startDate, allDay: event.allDay)
        guard let end = event.endDate else { return start }
        let endText = CountdownText.dateText(end, allDay: event.allDay)
        let locale = AppSettings.language.locale
        return String(localized: "开始 \(start)", bundle: .appLanguage(), locale: locale) + " · "
            + String(localized: "结束 \(endText)", bundle: .appLanguage(), locale: locale)
    }

    #if DEBUG
    /// 截图验证用:塞几件样板倒数日(只在库里一件都没有时),`--demo-countdown-edit`
    /// 直接打开第一件的编辑页,`--demo-countdown-new` 打开新建页。
    private func applyDemoArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo-countdown") else { return }
        if events.isEmpty {
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: .now)
            func day(_ offset: Int) -> Date {
                calendar.date(byAdding: .day, value: offset, to: today)!
            }
            let samples = [
                CountdownEvent(title: "东京旅行", startDate: day(3), endDate: day(6),
                               startReminders: [1440], showInWidget: true),
                CountdownEvent(title: "驾照科目二", startDate: day(12).addingTimeInterval(9 * 3600),
                               allDay: false, startReminders: [60, 1440], showInWidget: true),
                CountdownEvent(title: "妈妈生日", startDate: day(40), showInWidget: true),
                CountdownEvent(title: "国庆假期", startDate: day(-2), endDate: day(4)),
                CountdownEvent(title: "搬家", startDate: day(-20)),
                CountdownEvent(title: "在一起", startDate: calendar.date(
                    byAdding: .year, value: -2, to: day(3))!),
                CountdownEvent(title: "旧公司入职", startDate: day(-900), archived: true),
            ]
            samples.forEach(context.insert)
            try? context.save()
            WidgetBridge.sync(context: context)
        }
        if args.contains("--demo-countdown-new") { creating = true }
        if args.contains("--demo-countdown-edit") {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                editing = sorted.first
            }
        }
        if args.contains("--demo-countdown-archived") { showArchived = true }
    }
    #endif
}
