import SwiftUI

/// 菜单栏命令要调到"当前这个窗口"的导航外壳:`AppShellView` 用 `focusedSceneValue`
/// 把动作交出来,命令那边按前台窗口取,开了多个窗口也不会串台。
struct ShellCommandActions {
    let go: (AppSection) -> Void
    let askAI: () -> Void
}

private struct ShellCommandActionsKey: FocusedValueKey {
    typealias Value = ShellCommandActions
}

extension FocusedValues {
    var shellCommands: ShellCommandActions? {
        get { self[ShellCommandActionsKey.self] }
        set { self[ShellCommandActionsKey.self] = newValue }
    }
}

#if os(macOS)
/// macOS 菜单栏:Mac 用户找功能先看菜单栏、靠快捷键切换,这些都是系统 `Commands`。
/// - 「文件 → 问问 AI」⌘N:平级页面上没有「+」,新建一律走 AI(见 CLAUDE.md),
///   所以 ⌘N 这个"新建"的肌肉记忆落在 AI 助手上;顺手替掉了默认的「新建窗口」——
///   导航状态都在一个窗口的外壳里,多开窗口只会多出几份互不同步的页面栈。
/// - 「前往」菜单(同访达的「前往」):十二个页面,前九个 ⌘1–⌘9。
/// - 系统的侧边栏命令(显示/隐藏侧边栏 ⌃⌘S)。
/// 菜单栏在 SwiftUI 环境之外,标题跟系统语言走——和菜单栏其余的系统菜单一致。
struct LodoCommands: Commands {
    @FocusedValue(\.shellCommands) private var shell

    var body: some Commands {
        SidebarCommands()
        CommandGroup(replacing: .newItem) {
            Button("问问 AI") { shell?.askAI() }
                .keyboardShortcut("n")
                .disabled(shell == nil)
        }
        CommandMenu("前往") {
            ForEach(Array(AppSection.pages.enumerated()), id: \.element) { index, page in
                Button(page.title) { shell?.go(page) }
                    .keyboardShortcut(index < 9
                        ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                        : nil)
                    .disabled(shell == nil)
            }
        }
    }
}
#endif
