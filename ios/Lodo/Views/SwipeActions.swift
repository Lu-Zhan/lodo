import SwiftUI

extension View {
    /// 已完成/待办行共用的左右滑手势:左滑主操作(带成功触感),右滑删除(带触感)。
    func nagSwipeActions(
        leadingLabel: String,
        leadingSystemImage: String,
        leadingTint: Color,
        onLeading: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        self
            .swipeActions(edge: .leading) {
                Button {
                    Haptics.success()
                    onLeading()
                } label: {
                    Label(leadingLabel, systemImage: leadingSystemImage)
                }
                .tint(leadingTint)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    Haptics.impact()
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
    }
}
