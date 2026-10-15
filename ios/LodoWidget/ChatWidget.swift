import WidgetKit
import SwiftUI

/// 桌面 1×1「Chat」小组件(2026-10,用户要求):上下两块,下面再左右分——
/// - 上:胶囊按钮,左边 AI 图标、中间「Chat」,点了进 AI 助手(`lodo://add`,同大号小组件);
/// - 左下:圆形按钮进总览(`lodo://overview`);
/// - 右下:圆形按钮直接开始语音输入(`lodo://voice`,AI 页打开就开始听)。
/// 三块各自是一个 `Link`(小号小组件也支持多个点击区域)。内容静态,时间线不刷新。
/// 配色同天气小组件(2026-10,用户要求):系统背景 + 系统的主/次文字色和填充色,
/// 深浅色自动跟着变,不再用 app 的强调色。语音键是 `waveform`(语音),不是麦克风。
struct ChatWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LodoChat", provider: ChatProvider()) { _ in
            ChatWidgetView()
        }
        .configurationDisplayName("Chat")
        .description("和 lodo 聊天、进总览,或直接开始语音输入。")
        .supportedFamilies([.systemSmall])
    }
}

struct ChatEntry: TimelineEntry {
    let date: Date
}

struct ChatProvider: TimelineProvider {
    func placeholder(in context: Context) -> ChatEntry { ChatEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ChatEntry) -> Void) {
        completion(ChatEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ChatEntry>) -> Void) {
        completion(Timeline(entries: [ChatEntry(date: .now)], policy: .never))
    }
}

struct ChatWidgetView: View {
    private static let spacing: CGFloat = 10

    var body: some View {
        VStack(spacing: Self.spacing) {
            Link(destination: URL(string: "lodo://add")!) {
                chatCapsule
            }
            .accessibilityLabel("打开 AI 助手")

            HStack(spacing: Self.spacing) {
                Link(destination: URL(string: "lodo://overview")!) {
                    CircleButton(symbol: "square.stack.3d.up")
                }
                .accessibilityLabel("打开总览")
                Link(destination: URL(string: "lodo://voice")!) {
                    CircleButton(symbol: "waveform")
                }
                .accessibilityLabel("语音输入")
            }
        }
        .homeWidgetBackground()
    }

    /// 图标贴左、「Chat」在整颗胶囊里居中(不是在图标右边那截里居中)。
    /// 三颗按钮同一种系统填充底 + 主文字色图标,「Chat」是次文字色。
    private var chatCapsule: some View {
        ZStack {
            Capsule().fill(.fill.secondary)
            Text(verbatim: "Chat")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .widgetAccentable()
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 下面那两颗圆:系统填充底 + 主文字色图标。
private struct CircleButton: View {
    let symbol: String

    var body: some View {
        ZStack {
            Circle().fill(.fill.secondary)
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .widgetAccentable()
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Chat", as: .systemSmall) {
    ChatWidget()
} timeline: {
    ChatEntry(date: .now)
}
