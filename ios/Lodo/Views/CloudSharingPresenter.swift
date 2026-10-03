#if os(iOS)
import SwiftUI
import UIKit
import CloudKit
import LodoCore

/// 旅行 / 资产台账共享的系统界面。两种:
/// - **还没邀请过人**(owner、share 上只有自己):系统分享面板
///   (`UIActivityViewController` + `NSItemProvider.registerCKShare`)——iOS 17 起苹果
///   推荐的发邀请方式,信息/邮件/拷贝链接都在里面。实测用 `UICloudSharingController`
///   发第一批邀请会弹出界面却发不出去。
/// - **已经有成员 / 我是成员**:`UICloudSharingController` 管理成员、停止共享、退出。
///
/// 都是系统界面桥接(同 `CameraPicker`),不算自绘。不包成 SwiftUI sheet:旅行详情的
/// 底部面板本身就是一张常驻 sheet,再套一层 representable 会出现空白双层模态,这里
/// 直接从当前最上层的控制器 present。
@MainActor
enum CloudSharingPresenter {
    /// 系统界面活着期间要留住 delegate(controller 只弱引用它)。
    private static var delegate: Delegate?

    static func present(share: CKShare, trip: TravelTrip) {
        present(share: share, title: trip.title, isOwner: trip.shareRole == .owner) {
            SharedTripSync.shared.didStopSharing(trip)
        }
    }

    /// 资产台账共享(整本台账,见 `SharedTripSync.prepareAssetShare`)。
    static func presentAssets(share: CKShare) {
        present(share: share, title: String(localized: "资产", bundle: .appLanguage()),
                isOwner: SharedTripSync.shared.assetShare?.role != .participant) {
            SharedTripSync.shared.didStopSharingAssets()
        }
    }

    private static func present(share: CKShare, title: String, isOwner: Bool,
                                onStop: @escaping () -> Void) {
        let container = CKContainer(identifier: SharedTripSync.containerID)
        let invitedAnyone = share.participants.contains { $0.role != .owner }
        guard let top = topController() else {
            SharedTripSync.shared.report(String(localized: "没找到可以弹出共享界面的窗口", bundle: .appLanguage()))
            return
        }
        if isOwner && !invitedAnyone {
            top.present(activityController(share: share, container: container, title: title, anchor: top.view),
                        animated: true)
        } else {
            let controller = UICloudSharingController(share: share, container: container)
            let delegate = Delegate(title: title, onStop: onStop)
            Self.delegate = delegate
            controller.delegate = delegate
            controller.availablePermissions = [.allowPrivate, .allowReadWrite]
            top.present(controller, animated: true)
        }
    }

    private static func activityController(share: CKShare, container: CKContainer,
                                           title: String, anchor: UIView) -> UIViewController {
        let provider = NSItemProvider()
        provider.registerCKShare(share, container: container, allowedSharingOptions:
            CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                    allowedParticipantAccessOptions: .specifiedRecipientsOnly))
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        configuration.metadataProvider = { key in
            key == .title ? title : nil
        }
        let controller = UIActivityViewController(activityItemsConfiguration: configuration)
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error {
                SharedTripSync.shared.report(error.localizedDescription)
            }
        }
        // iPad 上分享面板是 popover,要给个锚点。
        controller.popoverPresentationController?.sourceView = anchor
        controller.popoverPresentationController?.sourceRect =
            CGRect(x: anchor.bounds.maxX - 44, y: anchor.safeAreaInsets.top, width: 1, height: 1)
        return controller
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    private final class Delegate: NSObject, UICloudSharingControllerDelegate {
        let title: String
        let onStop: () -> Void

        init(title: String, onStop: @escaping () -> Void) {
            self.title = title
            self.onStop = onStop
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            title
        }

        func cloudSharingController(_ csc: UICloudSharingController,
                                    failedToSaveShareWithError error: Error) {
            SharedTripSync.shared.report(error.localizedDescription)
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onStop()
        }
    }
}

/// 接受共享邀请:用户点了别人发来的链接后,系统打开 app 并回调 scene delegate 的
/// `windowScene(_:userDidAcceptCloudKitShareWith:)`。SwiftUI 生命周期下要自己挂一个
/// scene delegate 才收得到(窗口仍由 SwiftUI 管)。
final class LodoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // CKSyncEngine 靠静默推送得知服务器有变化。
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = LodoSceneDelegate.self
        return configuration
    }
}

final class LodoSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in await SharedTripSync.shared.accept(cloudKitShareMetadata) }
    }

    /// 冷启动时点链接打开:元数据在连接选项里,不走上面那个回调。
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let metadata = connectionOptions.cloudKitShareMetadata else { return }
        Task { @MainActor in await SharedTripSync.shared.accept(metadata) }
    }
}
#elseif os(macOS)
import SwiftUI
import AppKit
import CloudKit
import LodoCore

/// macOS 版的共享界面,分法同 iOS:
/// - **还没邀请过人**(owner、share 上只有自己):系统分享选择器
///   (`NSSharingServicePicker` + `NSItemProvider.registerCKShare`),信息/邮件/拷贝链接都在里面;
/// - **已经有成员 / 我是成员**:系统的 CloudKit 共享管理界面(`NSSharingService(.cloudSharing)`),
///   管理成员、停止共享、退出。
/// 都是系统界面,不算自绘。锚点是当前主窗口右上角(工具栏菜单在那儿)。
@MainActor
enum CloudSharingPresenter {
    /// 系统界面活着期间要留住 delegate(picker / service 只弱引用它)。
    private static var delegate: Delegate?

    static func present(share: CKShare, trip: TravelTrip) {
        present(share: share, title: trip.title, isOwner: trip.shareRole == .owner) {
            SharedTripSync.shared.didStopSharing(trip)
        }
    }

    /// 资产台账共享(整本台账,见 `SharedTripSync.prepareAssetShare`)。
    static func presentAssets(share: CKShare) {
        present(share: share, title: String(localized: "资产", bundle: .appLanguage()),
                isOwner: SharedTripSync.shared.assetShare?.role != .participant) {
            SharedTripSync.shared.didStopSharingAssets()
        }
    }

    private static func present(share: CKShare, title: String, isOwner: Bool,
                                onStop: @escaping () -> Void) {
        let container = CKContainer(identifier: SharedTripSync.containerID)
        let invitedAnyone = share.participants.contains { $0.role != .owner }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible),
              let anchor = window.contentView else {
            SharedTripSync.shared.report(String(localized: "没找到可以弹出共享界面的窗口", bundle: .appLanguage()))
            return
        }
        let provider = NSItemProvider()
        provider.registerCKShare(share, container: container, allowedSharingOptions:
            CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                    allowedParticipantAccessOptions: .specifiedRecipientsOnly))
        let delegate = Delegate(title: title, onStop: onStop)
        Self.delegate = delegate

        if isOwner && !invitedAnyone {
            let picker = NSSharingServicePicker(items: [provider])
            picker.delegate = delegate
            let top = anchor.isFlipped ? anchor.bounds.minY : anchor.bounds.maxY - 1
            let rect = NSRect(x: anchor.bounds.maxX - 44, y: top, width: 1, height: 1)
            picker.show(relativeTo: rect, of: anchor, preferredEdge: .minY)
        } else {
            guard let service = NSSharingService(named: .cloudSharing),
                  service.canPerform(withItems: [provider]) else {
                SharedTripSync.shared.report(String(localized: "没找到可以弹出共享界面的窗口", bundle: .appLanguage()))
                return
            }
            service.delegate = delegate
            service.perform(withItems: [provider])
        }
    }

    private final class Delegate: NSObject, NSSharingServicePickerDelegate, NSCloudSharingServiceDelegate {
        let title: String
        let onStop: () -> Void

        init(title: String, onStop: @escaping () -> Void) {
            self.title = title
            self.onStop = onStop
        }

        // 选择器里选中的那个服务(信息/邮件/协作…)的回调也交给自己,失败才报得出来。
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                  delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
            self
        }

        func sharingService(_ sharingService: NSSharingService,
                            didFailToShareItems items: [Any], error: Error) {
            // 用户自己点取消不算错误。
            if (error as NSError).code == NSUserCancelledError { return }
            SharedTripSync.shared.report(error.localizedDescription)
        }

        func options(for cloudKitSharingService: NSSharingService,
                     share provider: NSItemProvider) -> NSSharingService.CloudKitOptions {
            [.allowPrivate, .allowReadWrite]
        }

        func sharingService(_ sharingService: NSSharingService, didStopSharing share: CKShare) {
            onStop()
        }
    }
}

/// 接受共享邀请 + 注册远程推送(CKSyncEngine 靠静默推送得知服务器有变化)。
/// macOS 上没有 scene delegate,邀请直接回调到 application delegate,冷启动也走这一个。
final class LodoAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
        #if DEBUG
        // 截图验证用:只让这个进程走深色/浅色外观,不动系统设置。
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo-dark") {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        } else if args.contains("--demo-light") {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }
        // 排查窗口最小尺寸:几秒后把主窗口的 min size 写到临时文件。
        if let index = args.firstIndex(of: "--demo-log-window-min"), index + 1 < args.count {
            let path = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                let lines = NSApplication.shared.windows.filter(\.isVisible).map { window in
                    "\(window.title) frame=\(window.frame.size) minSize=\(window.minSize) "
                        + "contentMinSize=\(window.contentMinSize) "
                        + "toolbarItems=\(window.toolbar?.items.count ?? -1)"
                }
                try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        #endif
    }

    func application(_ application: NSApplication,
                     userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in await SharedTripSync.shared.accept(metadata) }
    }
}
#endif
