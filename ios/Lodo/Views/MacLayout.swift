import SwiftUI

extension View {
    /// 整页空态(`ContentUnavailableView`)放在 List 里时用。macOS 上 List 的行只有内容那么高,
    /// 空态会贴在页面顶上、底下一大片空白(实测);这里让它占满页面可见的高度,
    /// 提示就落在页面正中,并去掉行底色和分隔线。iOS 上分组列表里那张卡片本来就是
    /// 设计好的样子,不动。
    func emptyStateFill() -> some View {
        modifier(EmptyStateFill())
    }

    /// 单独占一行的切换条(不是表单里「标签 + 选择器」那种行):不显示标签,
    /// macOS 上按内容宽度居中——macOS 的分段/标签式选择器会把标签摆在左边、控件推到右边。
    @ViewBuilder
    func standaloneSwitchLayout() -> some View {
        #if os(macOS)
        labelsHidden()
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .center)
        #else
        labelsHidden()
        #endif
    }

    /// 分段选择器的统一样式:macOS 27 起用系统的标签式选择器(`TabsPickerStyle`,27 新增),
    /// 其余平台/版本仍是分段控件。门控收在这一处,调用处不写版本判断。
    @ViewBuilder
    func segmentedPickerStyle() -> some View {
        #if os(macOS)
        if #available(macOS 27.0, *) {
            pickerStyle(.tabs)
        } else {
            pickerStyle(.segmented)
        }
        #else
        pickerStyle(.segmented)
        #endif
    }
}

/// 页面可见高度(宽屏详情列根上量一次往下发)。macOS 的 List 底层是表格视图,
/// 行里的 `containerRelativeFrame` 量到的是行自己、不是列表(实测空态被压成一条),
/// 所以改成从页面根上拿。0 = 没量到(窄屏、sheet 里),按内容高度。
private struct PageContentHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var pageContentHeight: CGFloat {
        get { self[PageContentHeightKey.self] }
        set { self[PageContentHeightKey.self] = newValue }
    }
}

private struct EmptyStateFill: ViewModifier {
    @Environment(\.pageContentHeight) private var pageHeight

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .frame(maxWidth: .infinity)
            // 扣掉窗口标题栏和底下「问问 AI」那条大约占的高度,剩下的就是列表露出来的那截。
            .frame(minHeight: pageHeight > 0 ? max(280, pageHeight - 200) : nil)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        #else
        content
        #endif
    }
}

#if os(macOS)
import AppKit

/// macOS 两栏、中间分隔线可拖(新闻「文章列表 | 文章详情」、旅行详情「行程面板 | 地图」)。
///
/// 不用系统 `HSplitView`:它按两栏的"理想尺寸"把窗口往外撑,打开这两页窗口就从 1180
/// 被推到 1741 / 满屏宽,还被窗口状态恢复记住、以后每次都从屏幕外打开(实测)。这里左栏宽度
/// 由调用方的 `@AppStorage` 管着,窗口最窄 = 左栏宽 + 右栏最小宽,不会被撑大。
/// 分隔线就是系统 `Divider`,外面套一条 8pt 的透明热区接拖动、悬停换左右调整光标。
struct ResizableSplit<Leading: View, Trailing: View>: View {
    @Binding var leadingWidth: Double
    let range: ClosedRange<Double>
    var trailingMinWidth: CGFloat = 240
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @State private var dragStartWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            // 平时就是拖出来的宽度;窗口缩窄、右栏也到了最小宽时,左栏可以一路让到下限,
            // 不把窗口顶住(固定宽度的话窗口最窄 = 左栏宽 + 右栏最小宽,实测缩不动)。
            leading
                .frame(minWidth: range.lowerBound, maxWidth: clamped(leadingWidth))
                .layoutPriority(1)
            Divider()
                .overlay {
                    Color.clear
                        .frame(width: 8)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    let start = dragStartWidth ?? leadingWidth
                                    dragStartWidth = start
                                    leadingWidth = clamped(start + value.translation.width)
                                }
                                .onEnded { _ in dragStartWidth = nil }
                        )
                }
            trailing
                .frame(minWidth: trailingMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func clamped(_ width: Double) -> Double {
        min(max(width, range.lowerBound), range.upperBound)
    }
}
#endif
