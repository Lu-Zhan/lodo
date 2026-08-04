import SwiftUI
import Contacts
import ContactsUI

/// "选择导入":包一层系统自带的通讯录多选器(CNContactPickerViewController),
/// 不自己做搜索/分组/勾选 UI——原生控件已经是最熟悉的通讯录选人体验。
/// 仅 iOS——ContactsUI 的多选器在 macOS 上是弹出式(NSPopover 挂在按钮上)而非
/// 全屏页面,交互形态完全不同,这个 app 的通讯录导入/导出入口暂只做 iOS。
#if os(iOS)
struct ContactPickerView: UIViewControllerRepresentable {
    var onPicked: ([CNContact]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [
            CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ]
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPickerView
        init(_ parent: ContactPickerView) { self.parent = parent }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) {
            parent.onPicked(contacts)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.onCancel()
        }
    }
}
#endif
