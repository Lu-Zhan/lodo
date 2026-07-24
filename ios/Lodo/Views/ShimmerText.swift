import SwiftUI

/// "思考中…"这类轻量提示用的光效文字(参考 Claude Code CLI 的 thinking 提示,
/// 一道高亮从左到右反复扫过文字,不用转圈)。`TimelineView(.animation)` 按时间
/// 持续重绘,不用手动管理 @State/withAnimation(repeatForever)。
struct ShimmerText: View {
    let text: String

    var body: some View {
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
