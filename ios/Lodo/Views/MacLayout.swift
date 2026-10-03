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
