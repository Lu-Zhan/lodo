#if os(iOS)
import SwiftUI
import EventKit
import EventKitUI

/// 日历页点开一条系统事件:桥接系统的 `EKEventViewController`(详情 + 右上角
/// 「编辑」+ 底部「删除日程」),和系统日历 app 里点开一条日程是同一个界面。
///
/// 和 `CameraPicker` 同一类桥接——SwiftUI 没有事件详情/编辑控件,这个控制器
/// 本身就是系统界面,不是自绘 UI,也不是第三方库。**lodo 不替用户改任何字段**:
/// 改动一律由用户在系统编辑界面里自己点「完成」才保存;订阅日历、生日这类
/// 只读日历系统自己不给「编辑」按钮(`allowsContentModifications`)。
struct CalendarEventSheet: UIViewControllerRepresentable {
    let event: EKEvent
    /// 关掉(完成/删除/返回)之后回调,日历页据此重新取一遍事件。
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = EKEventViewController()
        controller.event = event
        controller.allowsEditing = true
        controller.allowsCalendarPreview = true
        controller.delegate = context.coordinator
        // 详情页左上角没有自带的关闭键(系统日历里它是 push 进来的);作为 sheet
        // 呈现时补一个,下拉关也照样可以。
        controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { _ in context.coordinator.finish() })
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, EKEventViewDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func finish() { onFinish() }

        func eventViewController(_ controller: EKEventViewController,
                                 didCompleteWith action: EKEventViewAction) {
            onFinish()
        }
    }
}
#endif
