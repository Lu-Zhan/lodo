import WidgetKit
import SwiftUI

/// 表盘上的 Lodo 快捷按钮:轻点直接打开语音助手并开始听(`lodowatch://listen`,
/// 由 `WatchTodoListView.onOpenURL` 接住)。内容是静态的——没有要刷新的数据,
/// 时间线只给一条、永不刷新。也能放进智能叠放。
@main
struct LodoWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        LodoListenWidget()
    }
}

struct LodoListenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LodoListen", provider: ListenProvider()) { _ in
            ListenWidgetView()
        }
        .configurationDisplayName("对 Lodo 说")
        .description("轻点直接开始语音输入:记一下、问一下、加个提醒。")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct ListenEntry: TimelineEntry {
    let date: Date
}

struct ListenProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListenEntry { ListenEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ListenEntry) -> Void) {
        completion(ListenEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListenEntry>) -> Void) {
        completion(Timeline(entries: [ListenEntry(date: .now)], policy: .never))
    }
}

struct ListenWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(URL(string: "lodowatch://listen"))
            .containerBackground(for: .widget) { Color.clear }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCorner:
            Image(systemName: "sparkles")
                .font(.title2)
                .widgetAccentable()
                .widgetLabel("Lodo")
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.title)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Lodo")
                        .font(.headline)
                        .widgetAccentable()
                    Text("轻点说话")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        case .accessoryInline:
            Label("对 Lodo 说", systemImage: "sparkles")
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .widgetAccentable()
            }
            .accessibilityLabel("对 Lodo 说话")
        }
    }
}
