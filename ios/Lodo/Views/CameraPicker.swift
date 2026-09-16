#if os(iOS)
import SwiftUI
import UIKit

/// 系统相机拍照。SwiftUI 至今没有相机控件,`PhotosPicker` 只能选已有照片,
/// 所以这里桥接 UIKit 的 `UIImagePickerController`——它本身就是系统相机界面,
/// 不是自绘 UI,也不是第三方库。只在 iOS 编译(macOS 没有这个控制器)。
struct CameraPicker: UIViewControllerRepresentable {
    /// 拍好的照片(已转 JPEG);取消时不回调。
    var onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    /// 模拟器/没有相机的设备上是 false,调用方据此不显示「拍照」入口。
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
                             UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.8) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
