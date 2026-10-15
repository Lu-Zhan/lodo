import SwiftUI
import LodoCore

/// 录音中的波形:和 iPhone AI 输入栏的 `RecordingWaveform` 同一套写法(一排 Capsule,
/// 相邻条相位错开成一条流动的波,幅度跟着电平放大,安静时保留一点呼吸感),
/// 只是条数和尺寸按手表屏幕缩了一圈。减弱动态效果时退化成静止的短条。
struct WatchRecordingWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let level: Float

    private static let barCount = 16
    private static let barWidth: CGFloat = 4
    private static let barSpacing: CGFloat = 3
    private static let minBarHeight: CGFloat = 5
    private static let maxBarHeight: CGFloat = 44
    private static let phaseStep: Double = 0.34
    private static let period: Double = 0.9
    private static let idleAmplitude: Double = 0.18

    var body: some View {
        if reduceMotion {
            bars { _ in Self.minBarHeight }
        } else {
            TimelineView(.animation) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let amplitude = Self.idleAmplitude + (1 - Self.idleAmplitude) * Double(level)
                bars { index in
                    let wave = (sin(time * 2 * .pi / Self.period - Double(index) * Self.phaseStep) + 1) / 2
                    return Self.minBarHeight
                        + (Self.maxBarHeight - Self.minBarHeight) * CGFloat(amplitude * wave)
                }
            }
        }
    }

    private func bars(height: @escaping (Int) -> CGFloat) -> some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: Self.barWidth, height: height(index))
            }
        }
        .frame(height: Self.maxBarHeight)
        .accessibilityLabel("正在听")
    }
}

/// 思考中那句轮换的状态词,词表和 iPhone 同一份(`AgentThinkingPhrases`)。
struct WatchThinkingText: View {
    let seed: Int
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 0.5)) { context in
            let text = AgentThinkingPhrases.text(
                elapsed: context.date.timeIntervalSince(start), seed: seed,
                language: AppSettings.language)
            Text(text)
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: text)
        }
    }

}
