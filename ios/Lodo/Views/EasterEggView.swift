import SwiftUI

/// 小彩蛋:AI 助手输入框里打 "0707" 触发的全屏气球动画(见 AgentView 的
/// .onChange(of: text)),纯装饰、不带任何待办/AI 逻辑。气球用 Ellipse/Capsule
/// 这些系统 Shape 拼出来,不是 Canvas 自绘;循环动效沿用仓库里 BreathingMicIcon/
/// RecordingWaveform 同一套写法——TimelineView(.animation) 按时间连续重绘。
struct EasterEggView: View {
    @Environment(\.dismiss) private var dismiss

    private static let balloons: [BalloonSpec] = [
        BalloonSpec(xFraction: 0.12, size: 74, hue: .pink, duration: 9.5, delay: 0.0),
        BalloonSpec(xFraction: 0.30, size: 56, hue: .yellow, duration: 7.5, delay: 1.6),
        BalloonSpec(xFraction: 0.50, size: 84, hue: .mint, duration: 10.5, delay: 0.8),
        BalloonSpec(xFraction: 0.68, size: 62, hue: .purple, duration: 8.5, delay: 2.4),
        BalloonSpec(xFraction: 0.85, size: 70, hue: .orange, duration: 9.0, delay: 0.4),
        BalloonSpec(xFraction: 0.22, size: 48, hue: .cyan, duration: 6.8, delay: 3.2),
        BalloonSpec(xFraction: 0.78, size: 50, hue: .red, duration: 7.8, delay: 4.0),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.85, blue: 0.90),
                    Color(red: 0.90, green: 0.82, blue: 0.98),
                    Color(red: 0.80, green: 0.88, blue: 0.99),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                balloonField(in: proxy.size)
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea()

            Text("爱lota每一天～")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.18), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭")
                }
                Spacer()
            }
            .padding()
        }
    }

    private func balloonField(in size: CGSize) -> some View {
        Group {
            if DesignMetrics.reduceMotionEnabled {
                // 减弱动态效果:气球静止排开,不做持续飘动。
                ForEach(Self.balloons) { spec in
                    Balloon(hue: spec.hue, size: spec.size)
                        .position(x: spec.xFraction * size.width, y: size.height * 0.4)
                }
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ForEach(Self.balloons) { spec in
                        // 从屏幕底部外(y = height + size)飘到顶部外(y = -size),
                        // 到顶后用 truncatingRemainder 立刻从底部循环重来。
                        let travel = size.height + spec.size * 2
                        let elapsed = (t + spec.delay).truncatingRemainder(dividingBy: spec.duration)
                        let progress = elapsed / spec.duration
                        let y = (size.height + spec.size) - progress * travel
                        let sway = sin(t * 1.1 + spec.xFraction * 10) * 14
                        Balloon(hue: spec.hue, size: spec.size)
                            .position(x: spec.xFraction * size.width + sway, y: y)
                    }
                }
            }
        }
    }

    private struct BalloonSpec: Identifiable {
        let id = UUID()
        /// 水平位置,相对屏幕宽度的比例(0...1)。
        let xFraction: CGFloat
        let size: CGFloat
        let hue: Color
        /// 从屏幕底部飘到顶部再循环一轮的时长(秒),故意各不相同,飘动不会同步。
        let duration: Double
        /// 起始时间偏移,进一步错开每颗气球的节奏。
        let delay: Double
    }

    /// 气球本体:椭圆气囊 + 一条细线,全是系统 Shape(Ellipse/Capsule),不是自绘。
    private struct Balloon: View {
        let hue: Color
        let size: CGFloat

        var body: some View {
            VStack(spacing: 0) {
                Ellipse()
                    .fill(hue.gradient)
                    .frame(width: size, height: size * 1.18)
                    .overlay(
                        Ellipse()
                            .fill(.white.opacity(0.35))
                            .frame(width: size * 0.32, height: size * 0.5)
                            .offset(x: -size * 0.18, y: -size * 0.22)
                    )
                Capsule()
                    .fill(hue.opacity(0.55))
                    .frame(width: 1.5, height: size * 0.7)
            }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 3)
        }
    }
}

#Preview {
    EasterEggView()
}
