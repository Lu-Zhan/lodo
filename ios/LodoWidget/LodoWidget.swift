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

struct LodoWidgetView: View {
    var entry: UpcomingEntry

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("即将到来")
                    .font(.caption.bold())
                    .foregroundStyle(.tint)
                if entry.items.isEmpty {
                    Spacer(minLength: 0)
                    Text("暂无待办事项")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ForEach(Array(entry.items.prefix(3).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(Self.format(item.at))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 右侧:快速添加,深链到 app 的快速添加页
            Link(destination: URL(string: "lodo://add")!) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
            }
            .accessibilityLabel("添加")
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
        .configurationDisplayName("即将到来")
        .description("查看即将到来的事项,一键快速添加。")
        .supportedFamilies([.systemMedium])
    }
}

@main
struct LodoWidgetBundle: WidgetBundle {
    var body: some Widget {
        LodoWidget()
    }
}
