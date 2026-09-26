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
        Color(nsColor: .controlBackgroundColor)
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
                        Text(OverviewTime.relativeLabel(to: first.date, from: now))
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(first.title)
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                        Label(first.date.formatted(date: .omitted, time: .shortened),
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
                                Text(OverviewTime.relativeLabel(to: item.date, from: now))
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
            .accessibilityLabel("完成")
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(task.caption)
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
                        Text(remaining.isEmpty ? "全部完成" : "还剩 \(remaining.count) 件")
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let next = remaining.first {
                            Text(next.title)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            } else if remaining.isEmpty {
                OverviewEmptyText(text: total == 0 ? "今天暂无任务" : "今天的任务都完成了")
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
    let now: Date
    var onOpen: () -> Void

    @Environment(\.lodoAccent) private var accent

    var body: some View {
        OverviewWidgetCard(kind: .agenda, trailing: events.map { "\($0.count)" }, action: onOpen) {
            if let events {
                if events.isEmpty {
                    OverviewEmptyText(text: "今天没有日程")
                } else if size == .small {
                    let next = events.first { !$0.isAllDay && $0.end > now } ?? events[0]
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
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(events.prefix(4), id: \.occurrenceKey) { event in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(event.displayColor(accent))
                                    .frame(width: 3, height: 18)
                                Text(event.title)
                                    .font(.body)
                                    .foregroundStyle(event.end <= now && !event.isAllDay ? .secondary : .primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(timeLabel(event))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if events.count > 4 {
                            Text("还有 \(events.count - 4) 项")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                OverviewEmptyText(text: "连接系统日历后显示今天的日程")
            }
        }
    }

    private func timeLabel(_ event: CalendarEvent) -> String {
        event.isAllDay ? String(localized: "全天") : event.start.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - 倒数日

struct OverviewCountdownWidget: View {
    let size: OverviewWidgetSize
    let entries: [OverviewCountdownEntry]
    let now: Date

    var body: some View {
        OverviewWidgetCard(kind: .countdown) {
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
                OverviewEmptyText(text: "两个月内没有旅行或生日")
            }
        }
    }

    private func icon(_ entry: OverviewCountdownEntry) -> String {
        entry.kind == .trip ? "suitcase.rolling" : "gift"
    }

    /// 旅行已经出发了的写「进行中」,当天的写「今天」,其余「N 天」。
    private func dayCount(_ entry: OverviewCountdownEntry) -> Text {
        let days = OverviewTime.daysUntil(entry.date, from: now)
        if days < 0 { return Text("进行中") }
        if days == 0 { return Text("今天") }
        return Text("\(days) 天")
    }
}

// MARK: - 文字类(例行 / AI)

struct OverviewTextWidget: View {
    let kind: OverviewWidgetKind
    let text: String?
    let placeholder: LocalizedStringKey
    var action: (() -> Void)? = nil

    var body: some View {
        OverviewWidgetCard(kind: kind, action: action) {
            if let text {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            } else {
                OverviewEmptyText(text: placeholder)
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
                            Text(run.text)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
