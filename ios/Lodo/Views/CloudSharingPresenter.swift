#if os(iOS)
import SwiftUI
import UIKit
import CloudKit
import LodoCore

/// 旅行共享的系统界面。两种:
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
        let container = CKContainer(identifier: SharedTripSync.containerID)
        let invitedAnyone = share.participants.contains { $0.role != .owner }
        guard let top = topController() else {
            SharedTripSync.shared.report(String(localized: "没找到可以弹出共享界面的窗口", bundle: .appLanguage()))
            return
        }
        if trip.shareRole == .owner && !invitedAnyone {
            top.present(activityController(share: share, container: container, trip: trip, anchor: top.view),
                        animated: true)
        } else {
            let controller = UICloudSharingController(share: share, container: container)
            let delegate = Delegate(trip: trip)
            Self.delegate = delegate
            controller.delegate = delegate
            controller.availablePermissions = [.allowPrivate, .allowReadWrite]
            top.present(controller, animated: true)
        }
    }

    private static func activityController(share: CKShare, container: CKContainer,
                                           trip: TravelTrip, anchor: UIView) -> UIViewController {
        let provider = NSItemProvider()
        provider.registerCKShare(share, container: container, allowedSharingOptions:
            CKAllowedSharingOptions(allowedParticipantPermissionOptions: .readWrite,
                                    allowedParticipantAccessOptions: .specifiedRecipientsOnly))
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        let title = trip.title
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
        let trip: TravelTrip

        init(trip: TravelTrip) { self.trip = trip }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            trip.title
        }

        func cloudSharingController(_ csc: UICloudSharingController,
                                    failedToSaveShareWithError error: Error) {
            SharedTripSync.shared.report(error.localizedDescription)
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            SharedTripSync.shared.didStopSharing(trip)
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
#endif
