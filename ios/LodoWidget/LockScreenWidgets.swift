import WidgetKit
import SwiftUI

// MARK: - 快照(与 app 侧 WidgetBridge.LockScreenSnapshot 字段一致)

/// app 侧 `WidgetBridge.LockScreenSnapshot` 写进 App Group 的内容。小组件 target 不链接
/// LodoCore,也读不到应用内语言设置,所以文案(标题、倒数日那句"还有 12 天")
/// 都是 app 按应用内语言算好的,这里只渲染。
struct LockScreenSnapshot: Codable {
    struct Line: Codable {
        let title: String
        let at: Date?
        let end: Date?
        let allDay: Bool
        let isEvent: Bool
    }
    struct CountdownLine: Codable {
        let title: String
        let text: String
    }
    struct CountdownDay: Codable {
        let from: Date
        let lines: [CountdownLine]
    }
    struct Labels: Codable {
        let today: String
        let pinned: String
        let countdown: String
        let allDay: String
        let emptyToday: String
        let emptyPinned: String
        let emptyCountdown: String
        let agent: String
    }
    let today: [Line]
    let pinned: [Line]
    let countdown: [CountdownDay]
    let labels: Labels

    /// 还没打开过 app(没有快照)时的兜底:中文标签、没有内容。
    static let empty = LockScreenSnapshot(
        today: [], pinned: [], countdown: [],
        labels: Labels(today: "今日", pinned: "重要的事", countdown: "倒数日", allDay: "全天",
                       emptyToday: "今天没有安排", emptyPinned: "长按任务即可置顶",
                       emptyCountdown: "在倒数日里选要显示的", agent: "AI 助手"))

    static func load() -> LockScreenSnapshot {
        guard let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.com.lodo.app")?
                .appending(path: "widget-lockscreen.json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(LockScreenSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    /// 某一刻该显示的倒数日:取 from 不晚于这一刻的最后一份。
    func countdownLines(at date: Date) -> [CountdownLine] {
        countdown.last { $0.from <= date }?.lines ?? countdown.first?.lines ?? []
    }

    /// 某一刻还该显示的"今日":结束了的日程拿掉,任务(含逾期)一直留着。
    func todayLines(at date: Date) -> [Line] {
        today.filter { !$0.isEvent || $0.allDay || ($0.end ?? .distantFuture) > date }
    }
}

struct LockScreenEntry: TimelineEntry {
    let date: Date
    let snapshot: LockScreenSnapshot
}

/// 三个锁屏小组件共用的时间线:现在一份,再在每个日程结束时、以及接下来几天的
/// 0 点各放一份(倒数日按天换文案)。数据变更时 app 侧会主动 reload。
struct LockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (LockScreenEntry) -> Void) {
        let snapshot = LockScreenSnapshot.load()
        let isEmpty = snapshot.today.isEmpty && snapshot.pinned.isEmpty
            && snapshot.countdown.allSatisfy(\.lines.isEmpty)
        completion(LockScreenEntry(date: .now,
                                   snapshot: context.isPreview && isEmpty ? .sample : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> Void) {
        let snapshot = LockScreenSnapshot.load()
        let now = Date()
        let changes = snapshot.today.compactMap { $0.isEvent && !$0.allDay ? $0.end : nil }
            + snapshot.countdown.map(\.from)
        let dates = ([now] + changes.filter { $0 > now }).sorted()
        let entries = dates.prefix(20).map { LockScreenEntry(date: $0, snapshot: snapshot) }
        // 兜底:明天 0 点之后没有新快照也要重新读一次(今日要翻篇)。
        let tomorrow = Calendar.current.date(
            byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        completion(Timeline(entries: Array(entries), policy: .after(tomorrow)))
    }
}

extension LockScreenSnapshot {
    /// 小组件库预览用的样例。
    static let sample = LockScreenSnapshot(
        today: [
            Line(title: "开周会", at: .now.addingTimeInterval(3600), end: nil, allDay: false,
                 isEvent: false),
            Line(title: "牙医复诊", at: .now.addingTimeInterval(7200),
                 end: .now.addingTimeInterval(9000), allDay: false, isEvent: true),
            Line(title: "给妈妈回电话", at: .now.addingTimeInterval(10800), end: nil,
                 allDay: false, isEvent: false),
        ],
        pinned: [
            Line(title: "交季度报告", at: nil, end: nil, allDay: false, isEvent: false),
            Line(title: "续签护照", at: nil, end: nil, allDay: false, isEvent: false),
        ],
        countdown: [CountdownDay(from: .distantPast, lines: [
            CountdownLine(title: "东京旅行", text: "还有 3 天开始"),
            CountdownLine(title: "驾照科目二", text: "还有 12 天"),
            CountdownLine(title: "妈妈生日", text: "还有 40 天"),
        ])],
        labels: LockScreenSnapshot.empty.labels)
}

// MARK: - 1×1:AI 助手

/// 锁屏圆形小组件:一颗 AI 图标,点一下直接进 AI 助手页(和桌面小组件那颗按钮
/// 同一个深链 `lodo://add`)。
struct AgentLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LodoAgentLock", provider: LockScreenProvider()) { entry in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .semibold))
                    .widgetAccentable()
            }
            .accessibilityLabel(entry.snapshot.labels.agent)
            .widgetURL(URL(string: "lodo://add"))
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("AI 助手")
        .description("轻点直接打开 lodo 的 AI 助手。")
        .supportedFamilies([.accessoryCircular])
    }
}

// MARK: - 1×2:今日 / 重要的事 / 倒数日

/// 锁屏长条小组件的共用外观:一行标题 + 最多三行内容。锁屏上是单色渲染,
/// 标题行用 `widgetAccentable()` 在着色模式下带颜色。
private struct AccessoryList<Row: View>: View {
    let icon: String
    let title: String
    let empty: String
    let count: Int
    @ViewBuilder let rows: () -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .widgetAccentable()
                .lineLimit(1)
            if count == 0 {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                rows()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TodayLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LodoTodayLock", provider: LockScreenProvider()) { entry in
            let lines = Array(entry.snapshot.todayLines(at: entry.date).prefix(3))
            AccessoryList(icon: "checklist", title: entry.snapshot.labels.today,
                          empty: entry.snapshot.labels.emptyToday, count: lines.count) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 4) {
                        Group {
                            if line.allDay {
                                Text(entry.snapshot.labels.allDay)
                            } else if let at = line.at {
                                Text(at, style: .time)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Text(line.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }
            .widgetURL(URL(string: "lodo://todo"))
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("今日")
        .description("今天要做的三件事:任务和日程。")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct PinnedLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LodoPinnedLock", provider: LockScreenProvider()) { entry in
            let lines = Array(entry.snapshot.pinned.prefix(3))
            AccessoryList(icon: "pin.fill", title: entry.snapshot.labels.pinned,
                          empty: entry.snapshot.labels.emptyPinned, count: lines.count) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text("· \(line.title)")
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .widgetURL(URL(string: "lodo://todo"))
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("重要的事")
        .description("在 lodo 里置顶的任务。")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct CountdownLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LodoCountdownLock", provider: LockScreenProvider()) { entry in
            let lines = Array(entry.snapshot.countdownLines(at: entry.date).prefix(3))
            AccessoryList(icon: "hourglass", title: entry.snapshot.labels.countdown,
                          empty: entry.snapshot.labels.emptyCountdown, count: lines.count) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 4) {
                        Text(line.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(line.text)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }
            .widgetURL(URL(string: "lodo://countdown"))
            .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("倒数日")
        .description("在 lodo 倒数日里选中的最多 3 件事,离开始或结束还有几天。")
        .supportedFamilies([.accessoryRectangular])
    }
}

#Preview("AI", as: .accessoryCircular) {
    AgentLockWidget()
} timeline: {
    LockScreenEntry(date: .now, snapshot: .sample)
}

#Preview("今日", as: .accessoryRectangular) {
    TodayLockWidget()
} timeline: {
    LockScreenEntry(date: .now, snapshot: .sample)
}

#Preview("倒数日", as: .accessoryRectangular) {
    CountdownLockWidget()
} timeline: {
    LockScreenEntry(date: .now, snapshot: .sample)
}
