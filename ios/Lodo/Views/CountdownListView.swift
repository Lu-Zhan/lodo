import SwiftUI
import SwiftData
import LodoCore

/// 「倒数日」页:平级页面(侧栏「日历」下面)。每行一件事:标题、起讫时间,
/// 右边是离开始/结束还有多久(或已经过去多久)。点一行进编辑,右上角「+」新建——
/// AI 接不了倒数日这一棒(`command` 协议里没有这个动作),所以和旅行详情的
/// 「手动添加」一样,入口必须留着。
///
/// 还没过去的在前、按下一个节点从近到远;已经过去的收在最底下的折叠栏里。
struct CountdownListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.sidebarChrome) private var sidebarChrome
    @Environment(\.lodoAccent) private var lodoAccent
    @Query private var events: [CountdownEvent]

    @State private var editing: CountdownEvent?
    @State private var creating = false
    @State private var showPast = false
    /// 一分钟刷新一次"还有几小时几分"。
    @State private var now = Date()

    private var sorted: [CountdownEvent] {
        let byID = Dictionary(events.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        return CountdownPlan.sorted(events.map(\.entry), now: now).compactMap { byID[$0.id] }
    }

    private var upcoming: [CountdownEvent] {
        sorted.filter { !CountdownPlan.isPast($0.entry, now: now) }
    }

    private var past: [CountdownEvent] {
        sorted.filter { CountdownPlan.isPast($0.entry, now: now) }
    }

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
                    }
                } else {
                    Section {
                        if upcoming.isEmpty {
                            Text("没有还没到的日子了。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(upcoming) { event in row(event) }
                    } footer: {
                        if events.contains(where: \.showInWidget) {
                            Text("带 \(Image(systemName: "lock.fill")) 的会显示在锁屏「倒数日」小组件上。")
                        }
                    }
                    if !past.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $showPast) {
                                ForEach(past) { event in row(event) }
                            } label: {
                                Text("已经过去 · \(past.count)")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("倒数日")
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
        return Button {
            editing = event
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(event.title.isEmpty
                             ? String(localized: "(未命名)", locale: AppSettings.language.locale)
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
                        .foregroundStyle(isPast ? Color.secondary : lodoAccent.accent)
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
                try? context.save()
                CountdownNotifier.reschedule(context: context)
                WidgetBridge.sync(context: context)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    /// "开始 2026年7月20日 周一 · 结束 7月25日 周六";只有一个日子的就一个日期。
    private func dateLine(_ event: CountdownEvent) -> String {
        let start = CountdownText.dateText(event.startDate, allDay: event.allDay)
        guard let end = event.endDate else { return start }
        let endText = CountdownText.dateText(end, allDay: event.allDay)
        let locale = AppSettings.language.locale
        return String(localized: "开始 \(start)", locale: locale) + " · "
            + String(localized: "结束 \(endText)", locale: locale)
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
        if args.contains("--demo-countdown-past") { showPast = true }
    }
    #endif
}
