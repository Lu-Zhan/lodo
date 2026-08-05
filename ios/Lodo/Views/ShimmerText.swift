import SwiftUI

/// "思考中…"这类轻量提示用的光效文字(参考 Claude Code CLI 的 thinking 提示,
/// 一道高亮从左到右反复扫过文字,不用转圈)。`TimelineView(.animation)` 按时间
/// 持续重绘,不用手动管理 @State/withAnimation(repeatForever)。
struct ShimmerText: View {
    let text: String

    var body: some View {
        // 持续来回扫的光效属于"减弱动态效果"该关掉的那类效果(HIG 对重复性
        // 动效的建议),开启时退化成静态文字——"思考中…"这句话本身已经把
        // 状态说清楚了,不靠动效也不影响理解。
        if DesignMetrics.reduceMotionEnabled {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: 1.4)) / 1.4
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .primary, .clear],
                            startPoint: UnitPoint(x: phase * 3 - 1, y: 0.5),
                            endPoint: UnitPoint(x: phase * 3, y: 0.5)
                        )
                        .mask(Text(text).font(.footnote))
                    )
            }
        }
    }
}
