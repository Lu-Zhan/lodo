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
#elseif os(macOS)
import SwiftUI
import AppKit
import EventKit

/// macOS 版的事件详情。macOS 的 EventKitUI 没有 `EKEventViewController`,这里用系统
/// `Form` 摆出详情;**修改交给系统「日历」app**(工具栏「在「日历」中打开」),删除在这里点、
/// 再确认一次——和 iOS 一样,lodo 不替用户改任何字段,每一次改动都是用户自己点的。
/// 只读日历(订阅、生日)不给删除。
struct CalendarEventSheet: View {
    let event: EKEvent
    /// 关掉(完成/删除)之后回调,日历页据此重新取一遍事件。
    var onFinish: () -> Void

    @State private var confirmDelete = false
    @State private var deleteFailed = false

    private var canModify: Bool { event.calendar?.allowsContentModifications ?? false }
    private var isRecurring: Bool { event.hasRecurrenceRules }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("标题", value: event.title ?? "")
                    LabeledContent("时间", value: timeText)
                    if let location = event.location, !location.isEmpty {
                        LabeledContent("地点", value: location)
                    }
                    if let calendar = event.calendar {
                        LabeledContent("日历", value: calendar.title)
                    }
                    if isRecurring {
                        LabeledContent("重复") { Image(systemName: "repeat") }
                    }
                }
                if let notes = event.notes, !notes.isEmpty {
                    Section("备注") {
                        Text(notes).textSelection(.enabled)
                    }
                }
                if let url = event.url {
                    Section("链接") {
                        Link(url.absoluteString, destination: url)
                    }
                }
                if canModify {
                    Section {
                        Button("删除日程", role: .destructive) { confirmDelete = true }
                    } footer: {
                        if deleteFailed {
                            Text("删除失败,请到「日历」app 里删除。")
                                .foregroundStyle(LodoColor.critical)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(event.title ?? "")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { onFinish() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("在「日历」中打开") { openInCalendarApp() }
                }
            }
            .confirmationDialog("删除日程", isPresented: $confirmDelete) {
                if isRecurring {
                    Button("仅删除这一次", role: .destructive) { delete(.thisEvent) }
                    Button("删除这一次及以后", role: .destructive) { delete(.futureEvents) }
                } else {
                    Button("删除", role: .destructive) { delete(.thisEvent) }
                }
                Button("取消", role: .cancel) {}
            }
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 360, idealHeight: 420)
    }

    private var timeText: String {
        guard let start = event.startDate, let end = event.endDate else { return "" }
        if event.isAllDay {
            // 全天事件的 endDate 是最后一天的 23:59:59 / 次日 0 点,按日子显示。
            let lastDay = end.addingTimeInterval(-1)
            if Calendar.current.isDate(start, inSameDayAs: lastDay) {
                return start.formatted(.dateTime.year().month().day().weekday())
            }
            return (start..<max(lastDay, start)).formatted(.interval.year().month().day())
        }
        return (start..<max(end, start)).formatted(.interval.month().day().weekday().hour().minute())
    }

    private func delete(_ span: EKSpan) {
        do {
            try CalendarBridge.eventStore.remove(event, span: span, commit: true)
            onFinish()
        } catch {
            deleteFailed = true
        }
    }

    /// 系统「日历」app 认 `ical://ekevent/<外部 id>` 直接定位到那条日程;
    /// 认不出(id 为空/没装)时退回只打开「日历」app。
    private func openInCalendarApp() {
        if let id = event.calendarItemExternalIdentifier,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "ical://ekevent/\(encoded)?method=show&options=more"),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
            return
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }
}
#endif
