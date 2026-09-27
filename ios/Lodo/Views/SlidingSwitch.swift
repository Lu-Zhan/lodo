import SwiftUI

/// 滑块式切换:一整条 Liquid Glass 轨道,选中的那一格是一块强调色滑块,切换时
/// 滑过去(同系统分段控件的手感)。旅行详情面板「总览 / 日程 / 消费 / 文件」和
/// 任务页「今天 / 未来 / 全部 / 已完成」共用。
///
/// 不用系统分段控件——它在玻璃面板上是一块不透明的灰底,和周围的材质对不上。
/// 滑块上的文字用 `lodoAccent.onFill`:暗色下强调色填充是亮色,压白字对比度不够。
struct SlidingSwitch<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var height: CGFloat = 32
    var font: Font = .subheadline.weight(.semibold)
    let title: (Option) -> Text

    @Environment(\.lodoAccent) private var lodoAccent
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                Button {
                    withAnimation(.lodoAware(.snappy)) { selection = option }
                } label: {
                    title(option)
                        .font(font)
                        .foregroundStyle(selected ? lodoAccent.onFill : Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background {
                            if selected {
                                Capsule().fill(lodoAccent.fill)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Capsule())
                }
                .pressable()
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .glassBackground(Capsule())
    }
}
