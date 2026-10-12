import SwiftUI

/// AI 对话里"这一条动了哪个条目"的跳转小条:挂在结果卡片**下面**、卡片背景之外,
/// 小字号、透明底,一行「旅行已更新:北海道 ›」,点一下直接进到那个条目里。
///
/// 它替掉了原来卡片上那颗「查看」和右侧栏(`AgentInspector`,已删):右栏在 iPhone
/// 上是另一套自绘抽屉、在宽屏上把对话挤成两半,而用户点「查看」想要的就是那个
/// 条目本身——app 里已经有那一页,不必在对话旁边再搭一份。
///
/// 位置在气泡外面是有意的:它不是卡片上的一颗按钮(那些是要做决定的——撤销、
/// 重新写入),而是这条消息的落脚点,和 Finder 里那行路径同一个性质,所以不带
/// 卡片底色、字号也压小一档。
struct AgentJumpLink: View {
    /// 整行文字,如「旅行已更新:北海道」。名字带在里面,免得和卡片标题重复一遍
    /// 前缀(「已调整「北海道」」)之后还要再说一次「北海道」。
    let text: Text
    let destination: AppDestination

    @Environment(\.itemNavigator) private var navigator
    @Environment(\.agentFloatsOverPage) private var floatsOverPage

    var body: some View {
        if let navigator {
            Button {
                navigator.open(destination)
            } label: {
                let label = HStack(spacing: 3) {
                    text
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                // 「问问 AI」悬浮在别的页面上时背后直接是页面内容,垫一颗玻璃胶囊
                // 才看得清(同气泡上方的「已完成 ›」;玻璃挂在文字本身上)。
                if floatsOverPage {
                    label
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .glassBackground(Capsule())
                        .contentShape(Capsule())
                } else {
                    // 文字之外那截空白也要能点(整行才是一个链接),但**不铺底色**:
                    // 卡片有底、这条没有,层级差别就靠这个。
                    label
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                }
            }
            .pressable()
            .accessibilityHint("打开这个条目")
        }
    }
}
