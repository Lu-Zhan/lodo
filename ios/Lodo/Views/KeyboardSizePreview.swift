#if os(iOS)
import SwiftUI

/// 设置 →「lodo 键盘」→「按键高度」上面的示意图:按竖屏尺寸(`KeyboardMetrics.phonePortrait`,402pt 宽)
/// 等比缩小画一副键盘,键帽高度跟着滑块变;不是默认高度时用虚线框标出默认的键盘有多高。
/// 键帽、背板是 RoundedRectangle/Rectangle 摆出来的,不是 Canvas;色值同键盘的 `KeyboardAppearance`。
struct KeyboardSizePreview: View {
    /// 按键高度倍数。
    let scale: Double

    // 竖屏键盘的尺寸(pt),同 LodoKeyboardModel 的 phonePortrait——主 app 不链接 LodoIME,这里抄一份。
    private static let width: CGFloat = 402
    private static let keyHeight: CGFloat = 42
    private static let rowSpacing: CGFloat = 10
    private static let keySpacing: CGFloat = 6
    private static let sideInset: CGFloat = 7
    private static let candidateBar: CGFloat = 38
    private static let keyAreaTop: CGFloat = 0
    private static let edgeKey: CGFloat = 45
    private static let bottomGap: CGFloat = 8

    /// 示意图宽度。
    private let previewWidth: CGFloat = 260
    private var f: CGFloat { previewWidth / Self.width }
    private var keyHeight: CGFloat { (Self.keyHeight * scale).rounded() }

    private func boardHeight(keyHeight: CGFloat) -> CGFloat {
        Self.candidateBar + Self.keyAreaTop + 4 * keyHeight + 3 * Self.rowSpacing + Self.bottomGap
    }

    private var isDefault: Bool { abs(scale - 1) < 0.001 }

    var body: some View {
        let height = boardHeight(keyHeight: keyHeight) * f
        let defaultHeight = boardHeight(keyHeight: Self.keyHeight) * f
        ZStack(alignment: .bottom) {
            board
                .frame(width: previewWidth, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10 * f * 2, style: .continuous))
            if !isDefault {
                RoundedRectangle(cornerRadius: 10 * f * 2, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .frame(width: previewWidth + 8, height: defaultHeight + 4)
                    .overlay(alignment: .topTrailing) {
                        Text("默认")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(Color(.secondarySystemGroupedBackground))
                            .offset(x: -8, y: -8)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: boardHeight(keyHeight: (Self.keyHeight * 1.25).rounded()) * f + 8, alignment: .bottom)
        .animation(.lodoAware(.snappy), value: scale)
        .accessibilityHidden(true)
    }

    private var board: some View {
        let s = Self.self
        let kh = keyHeight * f
        let gap = s.keySpacing * f
        let unit = (s.width - 2 * s.sideInset - 9 * s.keySpacing) / 10 * f
        return VStack(spacing: 0) {
            // 候选栏:首选垫一块圆角底,后面几个灰条代表候选字。
            HStack(spacing: 10 * f) {
                RoundedRectangle(cornerRadius: 6 * f).fill(Self.characterKey).frame(width: 60 * f, height: 36 * f)
                ForEach(0..<4, id: \.self) { _ in
                    Capsule().fill(.secondary.opacity(0.35)).frame(width: 44 * f, height: 8 * f)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, s.sideInset * f)
            .frame(height: s.candidateBar * f)
            .padding(.bottom, s.keyAreaTop * f)

            VStack(spacing: s.rowSpacing * f) {
                HStack(spacing: gap) { ForEach(0..<10, id: \.self) { _ in key(width: unit, height: kh) } }
                HStack(spacing: gap) { ForEach(0..<9, id: \.self) { _ in key(width: unit, height: kh) } }
                HStack(spacing: gap) {
                    key(width: s.edgeKey * f, height: kh, function: true)
                    Spacer(minLength: 0)
                    HStack(spacing: gap) { ForEach(0..<7, id: \.self) { _ in key(width: unit, height: kh) } }
                    Spacer(minLength: 0)
                    key(width: s.edgeKey * f, height: kh, function: true)
                }
                HStack(spacing: gap) {
                    key(width: unit * 1.25, height: kh, function: true)
                    key(width: unit * 1.25, height: kh, function: true)
                    key(width: nil, height: kh)
                    key(width: unit * 2.5, height: kh, function: true)
                }
            }
            .padding(.horizontal, s.sideInset * f)
            Spacer(minLength: 0)
        }
        .background(Self.backdrop)
    }

    private func key(width: CGFloat?, height: CGFloat, function: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 8.5 * f, style: .continuous)
            .fill(function ? Self.functionKey : Self.characterKey)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil)
    }

    private static let backdrop = Color.lodoDynamic(light: 0xD1D5DB, dark: 0x0E0E0F)
    private static let characterKey = Color.lodoDynamic(light: 0xFFFFFF, dark: 0x5C5C5C)
    private static let functionKey = Color.lodoDynamic(light: 0xABB0BA, dark: 0x363636)
}
#endif
