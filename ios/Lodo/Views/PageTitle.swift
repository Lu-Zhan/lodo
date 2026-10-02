import SwiftUI

extension View {
    /// 页面标题,代替 `.pageTitle("…")`。
    ///
    /// iOS 上等同原来的 `navigationTitle(LocalizedStringKey)`。macOS 上导航标题就是
    /// **窗口标题**(`NSWindow.title`),它在 SwiftUI 环境之外解析,不认根上下发的
    /// `\.locale`——app 里选中文、系统是英文时窗口标题会冒出 "Task"(实测)。所以那边
    /// 先按应用内语言(`Bundle.appLanguage`)解析成字符串再交出去;读 `\.locale` 是为了
    /// 用户改语言时跟着刷新。
    /// 参数用 `LocalizedStringResource`:字面量照样会被抽进字符串目录。
    func pageTitle(_ title: LocalizedStringResource) -> some View {
        modifier(PageTitle(title: title))
    }
}

private struct PageTitle: ViewModifier {
    let title: LocalizedStringResource
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        #if os(macOS)
        content.navigationTitle(
            Bundle.appLanguage().localizedString(forKey: title.key, value: title.key, table: nil))
        #else
        content.navigationTitle(LocalizedStringKey(title.key))
        #endif
    }
}

extension View {
    /// 有标题才设 navigationTitle。嵌在别的页面里(旅行详情的右栏)时传 nil:
    /// 连空串都不能设,macOS 上那会把窗口标题清空。
    @ViewBuilder
    func navigationTitleIfPresent(_ title: String?) -> some View {
        if let title {
            navigationTitle(title)
        } else {
            self
        }
    }
}
