import SwiftUI

/// 小彩蛋:AI 助手输入框里打特定数字触发的全屏动画(见 AgentView 的
/// .onChange(of: text)),纯装饰、不带任何待办/AI 逻辑。气球/爱心分别用
/// Ellipse/Capsule/系统 SF Symbol 拼出来,不是 Canvas 自绘;循环动效沿用仓库里
/// BreathingMicIcon/RecordingWaveform 同一套写法——TimelineView(.animation)
/// 按时间连续重绘。
struct EasterEggView: View {
    /// "0707" 是气球+生日祝福;"0829" 是结婚一周年纪念日,爱心+专属文案。
    enum Occasion {
        case birthday
        case anniversary

        var message: String {
            switch self {
            case .birthday: return "爱lota每一天～"
            case .anniversary: return "结婚一周年快乐\n爱你扬扬～"
            }
        }

        var gradientColors: [Color] {
            switch self {
            case .birthday:
                return [
                    Color(red: 0.98, green: 0.85, blue: 0.90),
                    Color(red: 0.90, green: 0.82, blue: 0.98),
                    Color(red: 0.80, green: 0.88, blue: 0.99),
                ]
            case .anniversary:
                return [
                    Color(red: 0.99, green: 0.86, blue: 0.87),
                    Color(red: 0.97, green: 0.78, blue: 0.83),
                    Color(red: 0.93, green: 0.70, blue: 0.78),
                ]
            }
        }
    }

    let occasion: Occasion
    @Environment(\.dismiss) private var dismiss

    init(occasion: Occasion = .birthday) {
        self.occasion = occasion
    }

    private static let balloons: [BalloonSpec] = [
        BalloonSpec(xFraction: 0.12, size: 74, hue: .pink, duration: 9.5, delay: 0.0),
        BalloonSpec(xFraction: 0.30, size: 56, hue: .yellow, duration: 7.5, delay: 1.6),
        BalloonSpec(xFraction: 0.50, size: 84, hue: .mint, duration: 10.5, delay: 0.8),
        BalloonSpec(xFraction: 0.68, size: 62, hue: .purple, duration: 8.5, delay: 2.4),
        BalloonSpec(xFraction: 0.85, size: 70, hue: .orange, duration: 9.0, delay: 0.4),
        BalloonSpec(xFraction: 0.22, size: 48, hue: .cyan, duration: 6.8, delay: 3.2),
        BalloonSpec(xFraction: 0.78, size: 50, hue: .red, duration: 7.8, delay: 4.0),
    ]

    private static let hearts: [BalloonSpec] = [
        BalloonSpec(xFraction: 0.10, size: 68, hue: .pink, duration: 8.5, delay: 0.0),
        BalloonSpec(xFraction: 0.26, size: 50, hue: .red, duration: 6.5, delay: 1.2),
        BalloonSpec(xFraction: 0.42, size: 82, hue: .pink, duration: 9.5, delay: 0.6),
        BalloonSpec(xFraction: 0.58, size: 46, hue: .red, duration: 7.0, delay: 2.0),
        BalloonSpec(xFraction: 0.74, size: 72, hue: .pink, duration: 8.0, delay: 0.3),
        BalloonSpec(xFraction: 0.88, size: 54, hue: .red, duration: 6.0, delay: 2.8),
        BalloonSpec(xFraction: 0.18, size: 42, hue: .pink, duration: 5.5, delay: 3.4),
        BalloonSpec(xFraction: 0.66, size: 58, hue: .red, duration: 7.5, delay: 1.8),
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: occasion.gradientColors,
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            GeometryReader { proxy in
                particleField(in: proxy.size)
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea()

            Text(occasion.message)
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

    @ViewBuilder
    private func particleField(in size: CGSize) -> some View {
        switch occasion {
        case .birthday:
            floatingField(Self.balloons, in: size) { spec in
                Balloon(hue: spec.hue, size: spec.size)
            }
        case .anniversary:
            floatingField(Self.hearts, in: size) { spec in
                HeartMark(hue: spec.hue, size: spec.size)
            }
        }
    }

    /// 气球/爱心共用的"从底部飘到顶部循环"动效,只是贴的内容(气球/爱心)不同。
    private func floatingField<Content: View>(
        _ specs: [BalloonSpec], in size: CGSize, @ViewBuilder content: @escaping (BalloonSpec) -> Content
    ) -> some View {
        Group {
            if DesignMetrics.reduceMotionEnabled {
                // 减弱动态效果:静止排开,不做持续飘动。
                ForEach(specs) { spec in
                    content(spec)
                        .position(x: spec.xFraction * size.width, y: size.height * 0.4)
                }
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ForEach(specs) { spec in
                        // 从屏幕底部外(y = height + size)飘到顶部外(y = -size),
                        // 到顶后用 truncatingRemainder 立刻从底部循环重来。
                        let travel = size.height + spec.size * 2
                        let elapsed = (t + spec.delay).truncatingRemainder(dividingBy: spec.duration)
                        let progress = elapsed / spec.duration
                        let y = (size.height + spec.size) - progress * travel
                        let sway = sin(t * 1.1 + spec.xFraction * 10) * 14
                        content(spec)
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

    /// 爱心本体:系统 SF Symbol("heart.fill"),不是自绘图形。
    private struct HeartMark: View {
        let hue: Color
        let size: CGFloat

        var body: some View {
            Image(systemName: "heart.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(hue.gradient)
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        }
    }
}

#Preview("生日") {
    EasterEggView(occasion: .birthday)
}

#Preview("结婚一周年") {
    EasterEggView(occasion: .anniversary)
}
