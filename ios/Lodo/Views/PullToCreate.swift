import SwiftUI

extension View {
    /// 下拉 = 手动新建(任务页同款,和右上角「+」打开同一个表单):拉到触发点时震一下,
    /// 不等任何异步工作,刷新圈马上收起。只挂在**没有真正刷新语义**的列表上——新闻、
    /// 总览、健康的下拉在拉数据,别换成这个。macOS 没有下拉手势(挂上 refreshable 只会
    /// 多出一个刷新命令),只靠「+」。
    @ViewBuilder
    func pullToCreate(_ action: @escaping @MainActor () -> Void) -> some View {
        #if os(iOS)
        refreshable {
            await MainActor.run {
                Haptics.impact(.medium)
                action()
            }
        }
        #else
        self
        #endif
    }
}
