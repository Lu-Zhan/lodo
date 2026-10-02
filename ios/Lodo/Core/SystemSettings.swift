import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 「前往系统设置」的统一入口。iOS 只有一个"本 app 的设置页"(权限开关都在里面),
/// macOS 的权限分散在「系统设置」各个面板里,按要去的那一项直接打开对应面板。
/// 调用方不写平台判断。
@MainActor
enum SystemSettings {
    enum Pane {
        case notifications, calendars, contacts, microphone, speechRecognition
    }

    static func open(_ pane: Pane) {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #elseif os(macOS)
        let security = "x-apple.systempreferences:com.apple.preference.security?"
        let target: String
        switch pane {
        case .notifications:
            target = "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="
                + (Bundle.main.bundleIdentifier ?? "")
        case .calendars: target = security + "Privacy_Calendars"
        case .contacts: target = security + "Privacy_Contacts"
        case .microphone: target = security + "Privacy_Microphone"
        case .speechRecognition: target = security + "Privacy_SpeechRecognition"
        }
        if let url = URL(string: target) { NSWorkspace.shared.open(url) }
        #endif
    }
}
