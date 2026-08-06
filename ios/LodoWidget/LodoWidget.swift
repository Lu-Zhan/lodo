import WidgetKit
import SwiftUI

/// app 侧 WidgetBridge 写入 App Group 的快照条目,字段保持一致。
struct UpcomingItem: Codable {
    let title: String
    let at: Date
}

struct UpcomingEntry: TimelineEntry {
    let date: Date
    let items: [UpcomingItem]
}

struct UpcomingProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpcomingEntry {
        UpcomingEntry(date: .now, items: [
            UpcomingItem(title: "给妈妈回电话", at: .now.addingTimeInterval(3600)),
            UpcomingItem(title: "开周会", at: .now.addingTimeInterval(7200)),
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (UpcomingEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpcomingEntry>) -> Void) {
        // 数据变更时 app 侧会主动 reload;这里兜底每 15 分钟刷新一次时间显示
        completion(Timeline(entries: [load()],
                            policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    private func load() -> UpcomingEntry {
        guard let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.com.lodo.app")?
                .appending(path: "widget-upcoming.json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([UpcomingItem].self, from: data) else {
            return UpcomingEntry(date: .now, items: [])
        }
        return UpcomingEntry(date: .now, items: items)
    }
}

/// 与主 app DesignMetrics 同一视觉尺度,但小组件 target 不 import 主 app 文件,
/// 只照抄必要的最小子集(与 UpcomingItem 的重复策略一致)。
private enum WidgetMetrics {
    static let buttonRadius: CGFloat = 16
}

/// 三种尺寸共用的"大按钮"外观。WidgetKit 的 Link 没有 .buttonStyle,只能靠手绘
/// 背景形状 + 图标/文案让它读起来像一个真正的按钮。
private struct AddAgentButton: View {
    /// .horizontal = 大尺寸的顶部通栏;.vertical = 中/小尺寸的堆叠块。
    var axis: Axis
    var iconSize: CGFloat
    var label: String = "问 lodo"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: WidgetMetrics.buttonRadius, style: .continuous)
                .fill(.tint)
            Group {
                if axis == .horizontal {
                    HStack(spacing: 8) {
                        icon
                        Text(label).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                } else {
                    VStack(spacing: 6) {
                        icon
                        Text(label).font(.caption.weight(.semibold))
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .widgetAccentable()
    }

    private var icon: some View {
        Image(systemName: "sparkles").font(.system(size: iconSize, weight: .semibold))
    }
}

/// 今天待办的一行:标题 + 时间,逾期标红。
private struct TodayRow: View {
    let item: UpcomingItem
    let now: Date

    /// 与 TaskRowView 的 overdue 判定同一口径(<=)。
    private var isOverdue: Bool { item.at <= now }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title)
                .font(.subheadline)
                .lineLimit(1)
            Text(LodoWidgetView.format(item.at))
                .font(.caption2)
                .foregroundStyle(isOverdue ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
    }
}

private struct EmptyTodayView: View {
    var body: some View {
        VStack {
            Spacer(minLength: 0)
            Text("今天没有待办事项 🎉")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

struct LodoWidgetView: View {
    var entry: UpcomingEntry
    @Environment(\.widgetFamily) private var family

    /// 小尺寸只放一个 AI 按钮;中尺寸横向卡片(今天待办 3 条 + 右侧按钮);
    /// 大尺寸竖向(顶部通栏按钮 + 今天待办最多 7 条)。
    var body: some View {
        switch family {
        case .systemSmall:
            smallBody
        case .systemLarge:
            largeBody
        default:
            mediumBody
        }
    }

    private var smallBody: some View {
        Link(destination: URL(string: "lodo://add")!) {
            AddAgentButton(axis: .vertical, iconSize: 30, label: "AI 助手")
        }
        .accessibilityLabel("打开 AI 助手")
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var mediumBody: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("今天")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if entry.items.isEmpty {
                    EmptyTodayView()
                } else {
                    ForEach(Array(entry.items.prefix(3).enumerated()), id: \.offset) { _, item in
                        TodayRow(item: item, now: entry.date)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Link(destination: URL(string: "lodo://add")!) {
                AddAgentButton(axis: .vertical, iconSize: 22, label: "AI 助手")
            }
            .frame(width: 68)
            .accessibilityLabel("打开 AI 助手")
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("今天待办")
                .font(.headline)
                .foregroundStyle(.secondary)

            Link(destination: URL(string: "lodo://add")!) {
                AddAgentButton(axis: .horizontal, iconSize: 18, label: "跟 lodo 说句话…")
                    .frame(height: 44)
            }
            .accessibilityLabel("打开 AI 助手")

            if entry.items.isEmpty {
                EmptyTodayView()
            } else {
                ForEach(Array(entry.items.prefix(7).enumerated()), id: \.offset) { index, item in
                    TodayRow(item: item, now: entry.date)
                    if index < min(entry.items.count, 7) - 1 {
                        Divider()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    /// 与 app 内 TaskItem.format 一致的时间文案。
    static func format(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "今天 \(time)" }
        if calendar.isDateInTomorrow(date) { return "明天 \(time)" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
}

struct LodoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LodoUpcoming", provider: UpcomingProvider()) { entry in
            LodoWidgetView(entry: entry)
        }
        .configurationDisplayName("lodo")
        .description("今天的待办一目了然,轻点即可用 AI 记下新的一件事。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct LodoWidgetBundle: WidgetBundle {
    var body: some Widget {
        LodoWidget()
    }
}

#Preview("Small", as: .systemSmall) {
    LodoWidget()
} timeline: {
    UpcomingEntry(date: .now, items: [])
}

#Preview("Medium", as: .systemMedium) {
    LodoWidget()
} timeline: {
    UpcomingEntry(date: .now, items: [
        UpcomingItem(title: "给妈妈回电话", at: .now.addingTimeInterval(-1800)),
        UpcomingItem(title: "开周会", at: .now.addingTimeInterval(3600)),
        UpcomingItem(title: "取快递", at: .now.addingTimeInterval(7200)),
    ])
}

#Preview("Medium Empty", as: .systemMedium) {
    LodoWidget()
} timeline: {
    UpcomingEntry(date: .now, items: [])
}

#Preview("Large", as: .systemLarge) {
    LodoWidget()
} timeline: {
    UpcomingEntry(date: .now, items: [
        UpcomingItem(title: "给妈妈回电话", at: .now.addingTimeInterval(-1800)),
        UpcomingItem(title: "开周会", at: .now.addingTimeInterval(3600)),
        UpcomingItem(title: "取快递", at: .now.addingTimeInterval(7200)),
        UpcomingItem(title: "健身", at: .now.addingTimeInterval(10800)),
        UpcomingItem(title: "读书 30 分钟", at: .now.addingTimeInterval(14400)),
    ])
}
