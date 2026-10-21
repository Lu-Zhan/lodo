import Foundation
import WatchConnectivity
import LodoCore

/// 收手机推过来的提醒设置(`WatchSettingsBridge`):「反复提醒」开关与稍等间隔,
/// 写进手表本机的 UserDefaults(`AppSettings` 照常读),变了就重排通知链。
final class WatchSettingsSync: NSObject, WCSessionDelegate {
    static let shared = WatchSettingsSync()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // WCSession 的回调在后台串行队列上来,而这个 target 默认 MainActor 隔离:
    // 回调本身 nonisolated,只把两个值取出来,再到主线程写设置、重排通知。
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // 上次送达的那份在这里(手表 app 没运行时手机推的)。
        receive(session.receivedApplicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        receive(applicationContext)
    }

    private nonisolated func receive(_ context: [String: Any]) {
        let repeats = context[AppSettings.repeatReminderEnabledKey] as? Bool
        let minutes = context[AppSettings.snoozeMinutesKey] as? Int
        Task { @MainActor in self.apply(repeats: repeats, minutes: minutes) }
    }

    private func apply(repeats: Bool?, minutes: Int?) {
        let defaults = UserDefaults.standard
        var changed = false
        if let repeats, defaults.object(forKey: AppSettings.repeatReminderEnabledKey) as? Bool != repeats {
            defaults.set(repeats, forKey: AppSettings.repeatReminderEnabledKey)
            changed = true
        }
        if let minutes, minutes > 0, defaults.integer(forKey: AppSettings.snoozeMinutesKey) != minutes {
            defaults.set(minutes, forKey: AppSettings.snoozeMinutesKey)
            changed = true
        }
        if changed { WatchNotificationManager.shared.refreshAll() }
    }
}
