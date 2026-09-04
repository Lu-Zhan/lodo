import SwiftUI

extension View {
    /// 已完成/待办行共用的滑动操作:统一挂在 trailing(向左滑)这一侧——向右拖是
    /// 抽屉的方向,留任何 leading action 都会和它抢同一个手势(见
    /// AppShellView.sidebarDrag)。主操作(带成功触感)排在最靠外,是 full swipe
    /// 触发的那一个;删除(带触感)排在里面,用力一滑不会误删。
    func nagSwipeActions(
        primaryLabel: String,
        primarySystemImage: String,
        primaryTint: Color,
        onPrimary: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        self
            .swipeActions(edge: .trailing) {
                Button {
                    Haptics.success()
                    onPrimary()
                } label: {
                    Label(primaryLabel, systemImage: primarySystemImage)
                }
                .tint(primaryTint)
                Button(role: .destructive) {
                    Haptics.impact()
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
    }
}
