import SwiftUI
import Contacts
import ContactsUI

/// 单个导出:包一层系统的"新建联系人"确认页(CNContactViewController),用户
/// 在真正存进通讯录前还能看一眼、改字段——比静默写入更符合"导出"该有的
/// 确认感,也不用自己画一个人脉编辑表单。仅 iOS,理由同 ContactPickerView。
#if os(iOS)
struct ContactExportView: UIViewControllerRepresentable {
    let contact: CNMutableContact
    /// 用户点了"完成"(真的存进通讯录)还是取消。
    var onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let contactVC = CNContactViewController(forNewContact: contact)
        contactVC.delegate = context.coordinator
        contactVC.contactStore = CNContactStore()
        return UINavigationController(rootViewController: contactVC)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, CNContactViewControllerDelegate {
        let parent: ContactExportView
        init(_ parent: ContactExportView) { self.parent = parent }

        func contactViewController(
            _ viewController: CNContactViewController, didCompleteWith contact: CNContact?
        ) {
            parent.onFinish(contact != nil)
        }
    }
}
#endif
