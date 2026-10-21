#if os(iOS)
import Foundation
import WatchConnectivity
import LodoCore

/// 把手表要用的几项提醒设置推给 Apple Watch:「反复提醒」开关与稍等间隔。
///
/// 手表经 CloudKit 只同步数据(任务、记忆),UserDefaults 是各设备自己的,
/// 不推的话手机上关了反复提醒,手表还会每 15 分钟敲一次门。用 WatchConnectivity 的
/// `applicationContext`:只保留最新一份、手表不在身边时等连上再送达,不需要额外 entitlement。
/// 手表那头是 `WatchSettingsSync`(键名两边一致)。
final class WatchSettingsBridge: NSObject, WCSessionDelegate {
    static let shared = WatchSettingsBridge()

    private var lastSent: [String: Any] = [:]
    private var observer: NSObjectProtocol?

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        // 设置页用的是 @AppStorage,改了就是 UserDefaults 变了;只在这两项真的变了才推。
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.push()
        }
    }

    private var current: [String: Any] {
        [AppSettings.repeatReminderEnabledKey: AppSettings.repeatReminderEnabled,
         AppSettings.snoozeMinutesKey: AppSettings.snoozeMinutes]
    }

    private func push() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        let context = current
        guard !NSDictionary(dictionary: context).isEqual(to: lastSent) else { return }
        do {
            try session.updateApplicationContext(context)
            lastSent = context
        } catch {
            // 送不出去就等下一次设置变化 / 下次启动再推。
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        DispatchQueue.main.async { self.push() }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.lastSent = [:]
            self.push()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 换了一块手表:重新激活,并给新手表补推一份。
        session.activate()
        DispatchQueue.main.async { self.lastSent = [:] }
    }
}
#endif
