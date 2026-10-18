import SwiftUI
import LodoCore

// 总览页的各个 widget。每个都是"标题行 + 内容"的一张卡,尺寸(半宽/整宽)由
// OverviewLayout 决定、这里通过 `size` 拿到后自己决定显示多少。数据都由
// OverviewView 取好传进来——widget 本身不发请求、不查库,方便以后挪进桌面小组件。
//
// 卡片是**内容**,不是 chrome:底色用不透明的分组卡片色,不上 Liquid Glass
// (玻璃不上内容,见 CLAUDE.md 的新系统 API 那条)。

/// 一张 widget 卡的外壳。`action` 非 nil 时整张卡可点(跳去对应页面)。
struct OverviewWidgetCard<Content: View>: View {
    let kind: OverviewWidgetKind
    var trailing: String? = nil
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    @Environment(\.lodoAccent) private var accent

    var body: some View {
        if let action {
            Button(action: action) { card }
                .pressableCard()
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label(LocalizedStringKey(kind.title), systemImage: kind.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent.accent)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Self.cardFill, in: RoundedRectangle(cornerRadius: DesignMetrics.widgetRadius,
                                                         style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: DesignMetrics.widgetRadius, style: .continuous))
    }

    static var cardFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
        // macOS 26 起窗口底色和 controlBackgroundColor 都近乎纯白,卡片会和页面融成一片、
        // 看不出边界(实测);按 iOS 分组列表那一对取值:白卡片 / 深色下高一档的灰。
        Color.lodoDynamic(light: 0xFFFFFF, dark: 0x2C2C2E)
        #else
        Color.secondary.opacity(0.1)
        #endif
    }
}

/// widget 里的一句灰色空态。
struct OverviewEmptyText: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 今天

struct OverviewClockWidget: View {
    var body: some View {
        OverviewWidgetCard(kind: .clock) {
            TimelineView(.everyMinute) { context in
                let now = context.date
                let progress = OverviewTime.dayProgress(at: now)
                VStack(alignment: .leading, spacing: 6) {
                    Text(now, format: .dateTime.hour().minute())
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(now, format: .dateTime.month().day().weekday(.wide))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .accessibilityLabel("今天已过")
                    Text("今天已过 \(Int(progress * 100))% · 第 \(Calendar.current.component(.weekOfYear, from: now)) 周")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }
}

// MARK: - 接下来

/// 接下来要发生的一件事:任务或日程,统一成这一个值。
struct OverviewUpcoming: Identifiable {
    let id: String
    let title: String
    let date: Date
    let isEvent: Bool
}

struct OverviewNextUpWidget: View {
    let size: OverviewWidgetSize
    let items: [OverviewUpcoming]
    let now: Date
    var onOpen: () -> Void

    var body: some View {
        OverviewWidgetCard(kind: .nextUp, action: onOpen) {
            if let first = items.first {
                if size == .small {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedContent.relativeTimeLabel(to: first.date, from: now))
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(first.title)
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                        Label(LocalizedContent.time(first.date),
                              systemImage: first.isEvent ? "calendar" : "checklist")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items.prefix(3)) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.isEvent ? "calendar" : "checklist")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(item.title)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(LocalizedContent.relativeTimeLabel(to: item.date, from: now))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                OverviewEmptyText(text: "接下来没有安排")
            }
        }
    }
}

// MARK: - 任务类

/// widget 里的一行任务:左边完成圆圈,点行编辑;长按稍等/删除。
/// 卡片里没有 List,系统的 swipeActions 用不上,所以主操作做成那颗圆圈。
struct OverviewTaskLine: View {
    let task: TaskItem
    let now: Date
    let onComplete: () -> Void
    let onEdit: () -> Void
    let onSnooze: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .hitTarget(visualSize: 24)
            }
            .pressable()
            .accessibilityLabel(Text("完成「\(task.title)」"))
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(LocalizedContent.taskCaption(task))
                        .font(.footnote)
                        .foregroundStyle(task.nextRemindAt <= now ? LodoColor.critical : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .pressableCard()
        }
        .contextMenu {
            Button(action: onSnooze) { Label("稍等", systemImage: "clock.arrow.circlepath") }
            Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
        }
    }
}

struct OverviewDueWidget: View {
    let tasks: [TaskItem]
    let now: Date
    let line: (TaskItem) -> OverviewTaskLine
    var onMore: () -> Void

    private let limit = 5

    var body: some View {
        OverviewWidgetCard(kind: .due, trailing: tasks.isEmpty ? nil : "\(tasks.count)") {
            if tasks.isEmpty {
                OverviewEmptyText(text: "没有到期未处理的提醒")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(tasks.prefix(limit)) { task in line(task) }
                    if tasks.count > limit {
                        Button("还有 \(tasks.count - limit) 项", action: onMore)
                            .font(.subheadline)
                    }
                }
            }
        }
    }
}

struct OverviewTodayWidget: View {
    let size: OverviewWidgetSize
    let remaining: [TaskItem]
    let doneCount: Int
    let now: Date
    let line: (TaskItem) -> OverviewTaskLine
    var onOpen: () -> Void

    private let limit = 4
    private var total: Int { remaining.count + doneCount }

    var body: some View {
        OverviewWidgetCard(kind: .today, trailing: "\(doneCount)/\(total)",
                           action: size == .small ? onOpen : nil) {
            if size == .small {
                HStack(spacing: 12) {
                    Gauge(value: Double(doneCount), in: 0...Double(max(total, 1))) {
                        EmptyView()
                    } currentValueLabel: {
                        Text("\(doneCount)")
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .tint(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        if total == 0 {
                            Text("今天暂无任务")
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } else if remaining.isEmpty {
                            Text("全部完成")
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } else {
                            Text("还剩 \(remaining.count) 件")
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        if let next = remaining.first {
                            Text(next.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } else if remaining.isEmpty {
                OverviewEmptyText(text: LocalizedStringKey(total == 0
                                                            ? "今天暂无任务"
                                                            : "今天的任务都完成了"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: Double(doneCount), total: Double(max(total, 1)))
                    ForEach(remaining.prefix(limit)) { task in line(task) }
                    if remaining.count > limit {
                        Button("还有 \(remaining.count - limit) 项", action: onOpen)
                            .font(.subheadline)
                    }
                }
            }
        }
    }
}

// MARK: - 今日日程

struct OverviewAgendaWidget: View {
    let size: OverviewWidgetSize
    /// nil = 没连接系统日历。
    let events: [CalendarEvent]?
    /// 今天还没完成、有具体时刻的任务(画在时间轴上的点)。
    let taskTimes: [Date]
    let now: Date
    var onOpen: () -> Void

    @Environment(\.lodoAccent) private var accent

    private let limit = 4

    var body: some View {
        OverviewWidgetCard(kind: .agenda, trailing: events.map { "\($0.count)" }, action: onOpen) {
            if let events {
                if events.isEmpty && size == .small {
                    OverviewEmptyText(text: "今天没有日程")
                } else if size == .small {
                    let next = events.first { !$0.isAllDay && $0.end > now } ?? events[0]
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(next.title)
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                            Text(timeLabel(next))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(next.displayColor(accent)).frame(width: 3)
                        }
                        freeSlotLine(events)
                    }
                } else {
                    largeBody(events)
                }
            } else {
                OverviewEmptyText(text: "连接系统日历后显示今天的日程")
            }
        }
    }

    // MARK: 大卡

    @ViewBuilder
    private func largeBody(_ events: [CalendarEvent]) -> some View {
        let timed = events.filter { !$0.isAllDay }
        let timeline = OverviewTimeline.make(day: now, busy: timed.map(interval), points: taskTimes + [now])
        // 列表先放进行中/还没开始的,已经结束的只报个数——到了下午,前四条往往全是上午的会。
        let current = events.filter { $0.isAllDay || $0.end > now }
        let ended = events.count - current.count
        VStack(alignment: .leading, spacing: 10) {
            OverviewTimelineBar(timeline: timeline, events: timed, taskTimes: taskTimes, now: now)
            freeSlotLine(events, timeline: timeline)
            if events.isEmpty {
                OverviewEmptyText(text: "今天没有日程")
            } else if current.isEmpty {
                OverviewEmptyText(text: "今天的日程都结束了")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(current.prefix(limit), id: \.occurrenceKey) { event in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(event.displayColor(accent))
                                .frame(width: 3, height: 18)
                            Text(event.title)
                                .font(.body)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(timeLabel(event))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if current.count > limit || ended > 0 {
                Text(moreText(more: max(0, current.count - limit), ended: ended))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func moreText(more: Int, ended: Int) -> String {
        let locale = AppSettings.language.locale
        var parts: [String] = []
        if more > 0 { parts.append(String(localized: "还有 \(more) 项", bundle: .appLanguage(), locale: locale)) }
        if ended > 0 { parts.append(String(localized: "已结束 \(ended) 项", bundle: .appLanguage(), locale: locale)) }
        return parts.joined(separator: " · ")
    }

    /// 「下一段空档 14:00–16:30」:从此刻到时间轴末尾(默认 22:00)之间,
    /// 日程之间至少半小时的空。任务没有时长,不占时间。
    @ViewBuilder
    private func freeSlotLine(_ events: [CalendarEvent], timeline: OverviewTimeline? = nil) -> some View {
        let timed = events.filter { !$0.isAllDay }
        let axis = timeline ?? OverviewTimeline.make(day: now, busy: timed.map(interval), points: [now])
        let slots = OverviewTimeline.freeSlots(busy: timed.map(interval), from: max(now, axis.start), to: axis.end)
        if let slot = slots.first {
            Label {
                Text("空档 \(LocalizedContent.time(slot.start))–\(LocalizedContent.time(slot.end))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: "cup.and.saucer")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if !timed.isEmpty, now < axis.end {
            Label("今天剩下的时间都排满了", systemImage: "calendar.badge.exclamationmark")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func interval(_ event: CalendarEvent) -> DateInterval {
        DateInterval(start: event.start, end: max(event.start, event.end))
    }

    private func timeLabel(_ event: CalendarEvent) -> String {
        event.isAllDay
            ? String(localized: "全天", bundle: .appLanguage(), locale: AppSettings.language.locale)
            : LocalizedContent.time(event.start)
    }
}

/// 今日时间轴:一条横向的轨道,日程是彩色块、任务是圆点、此刻是一条竖线,下面
/// 每 4 小时一个刻度。全是 Rectangle/Circle + offset 摆出来的(同日历页时间轴),没有 Canvas。
struct OverviewTimelineBar: View {
    let timeline: OverviewTimeline
    let events: [CalendarEvent]
    let taskTimes: [Date]
    let now: Date

    @Environment(\.lodoAccent) private var accent

    private let barHeight: CGFloat = 22

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    ForEach(events, id: \.occurrenceKey) { event in
                        let x = timeline.fraction(event.start) * width
                        let w = max(4, (timeline.fraction(event.end) - timeline.fraction(event.start)) * width)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(event.displayColor(accent).opacity(event.end <= now ? 0.35 : 0.85))
                            .frame(width: w, height: barHeight - 6)
                            .offset(x: x)
                    }
                    ForEach(Array(taskTimes.enumerated()), id: \.offset) { _, time in
                        Circle()
                            .fill(accent.accent)
                            .overlay(Circle().strokeBorder(OverviewWidgetCard<EmptyView>.cardFill, lineWidth: 1.5))
                            .frame(width: 9, height: 9)
                            .offset(x: timeline.fraction(time) * width - 4.5)
                    }
                    if now >= timeline.start && now <= timeline.end {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2, height: barHeight + 4)
                            .offset(x: timeline.fraction(now) * width - 1)
                    }
                }
                .frame(height: barHeight)
            }
            .frame(height: barHeight)
            GeometryReader { geo in
                ForEach(timeline.hourMarks(), id: \.self) { mark in
                    Text(mark, format: .dateTime.hour())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(timeline.fraction(mark) * geo.size.width, 10), geo.size.width - 10),
                                  y: 6)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("今日时间轴:\(events.count) 个日程,\(taskTimes.count) 件任务"))
    }
}

// MARK: - 倒数日

struct OverviewCountdownWidget: View {
    let size: OverviewWidgetSize
    let entries: [OverviewCountdownEntry]
    let now: Date
    /// 点卡片:进「倒数日」页。
    var action: (() -> Void)? = nil

    var body: some View {
        OverviewWidgetCard(kind: .countdown, action: action) {
            if let first = entries.first {
                if size == .small {
                    VStack(alignment: .leading, spacing: 2) {
                        dayCount(first)
                            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Label(first.title, systemImage: icon(first))
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries.prefix(4)) { entry in
                            HStack(spacing: 8) {
                                Image(systemName: icon(entry))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(entry.title).font(.body).lineLimit(1)
                                Spacer(minLength: 8)
                                dayCount(entry)
                                    .font(.subheadline.monospacedDigit().weight(.medium))
                            }
                        }
                    }
                }
            } else {
                OverviewEmptyText(text: "没有快到的日子")
            }
        }
    }

    private func icon(_ entry: OverviewCountdownEntry) -> String {
        switch entry.kind {
        case .trip: return "suitcase.rolling"
        case .birthday: return "gift"
        case .countdown: return "hourglass"
        }
    }

    /// 旅行已经出发了的写「进行中」,当天的写「今天」,其余「N 天」。
    private func dayCount(_ entry: OverviewCountdownEntry) -> Text {
        let days = OverviewTime.daysUntil(entry.date, from: now)
        if days < 0 { return Text("进行中") }
        if days == 0 { return Text("今天") }
        return Text("\(days) 天")
    }
}

// MARK: - 正数日

/// 「倒数日」页里已经过去的日子(在一起、入职、宝宝出生)往上数。快到周年/整百天的
/// 排前面(`CountdownPlan.countUps`),下面一行写"3 天后满 2 周年"。颜色同页面里的
/// 正数日组:`LodoColor.positive`,和倒数日的强调色分开。
struct OverviewCountUpWidget: View {
    let size: OverviewWidgetSize
    let items: [CountdownPlan.CountUp]
    let now: Date
    /// 点卡片:进「倒数日」页(正数日就在那一页的第二组)。
    var action: (() -> Void)? = nil

    var body: some View {
        OverviewWidgetCard(kind: .countUp, action: action) {
            if let first = items.first {
                if size == .small {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(days(first)) 天")
                            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            .foregroundStyle(LodoColor.positive)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text(first.entry.title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(subtitle(first))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items.prefix(4)) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.entry.title).font(.body).lineLimit(1)
                                    if let next = item.next {
                                        Text(milestoneText(next))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(CountdownText.text(span(item), hasEnd: item.entry.end != nil,
                                                        precise: false))
                                    .font(.subheadline.monospacedDigit().weight(.medium))
                                    .foregroundStyle(LodoColor.positive)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } else {
                OverviewEmptyText(text: "过去的纪念日会在这里往上数")
            }
        }
    }

    private func span(_ item: CountdownPlan.CountUp) -> CountdownSpan {
        CountdownPlan.primary(item.entry, now: now)
    }

    private func days(_ item: CountdownPlan.CountUp) -> Int { span(item).days }

    /// 小卡第三行:有节点写节点,没有(有结束日的事)写"已结束 N 天"。
    private func subtitle(_ item: CountdownPlan.CountUp) -> String {
        item.next.map(milestoneText)
            ?? CountdownText.text(span(item), hasEnd: item.entry.end != nil, precise: false)
    }

    private func milestoneText(_ milestone: CountdownPlan.Milestone) -> String {
        let locale = AppSettings.language.locale
        switch milestone.kind {
        case .anniversary(let years):
            return milestone.daysAway == 0
                ? String(localized: "今天满 \(years) 周年", bundle: .appLanguage(), locale: locale)
                : String(localized: "\(milestone.daysAway) 天后满 \(years) 周年",
                         bundle: .appLanguage(), locale: locale)
        case .dayCount(let count):
            return milestone.daysAway == 0
                ? String(localized: "今天满 \(count) 天", bundle: .appLanguage(), locale: locale)
                : String(localized: "\(milestone.daysAway) 天后满 \(count) 天",
                         bundle: .appLanguage(), locale: locale)
        case .start:
            return ""
        }
    }
}

// MARK: - 文字类(例行 / AI)

/// AI 那几段的状态。`String?` 分不清"没配 AI""正在要""今天没东西可说""请求失败",
/// 原来失败时会显示成「今天没有需要处理的任务」——任务明明还在。
enum OverviewAIText: Equatable {
    /// 没法要(没配 AI、开关关着):显示对应引导。
    case unavailable(String)
    case loading
    /// 没有可总结的输入(今天没任务/没收藏/没健康数据)。
    case empty(String)
    case failed
    case text(String)
}

struct OverviewTextWidget: View {
    let kind: OverviewWidgetKind
    let state: OverviewAIText
    var action: (() -> Void)? = nil

    var body: some View {
        OverviewWidgetCard(kind: kind, action: action) {
            switch state {
            case .text(let text):
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    OverviewEmptyText(text: "正在整理…")
                }
            case .failed:
                OverviewEmptyText(text: "这次没生成出来,下拉刷新重试")
            case .unavailable(let text), .empty(let text):
                OverviewEmptyText(text: LocalizedStringKey(text))
            }
        }
    }
}

struct OverviewRoutinesWidget: View {
    let runs: [AIRoutineRun]

    var body: some View {
        OverviewWidgetCard(kind: .routines) {
            if runs.isEmpty {
                OverviewEmptyText(text: "今天还没有定时任务的结果")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(run.routineName).font(.body.weight(.medium))
                            // 一条结果可能是一整篇简报,全文铺开会把总览拉得很长;看全文去设置里的任务详情。
                            Text(run.text)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
