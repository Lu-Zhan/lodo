import Foundation
import CoreData
import CloudKit
import Observation
import OSLog

/// SwiftData 私有库同步的诊断:SwiftData 的 CloudKit 同步底下就是
/// `NSPersistentCloudKitContainer`,它每次 setup / import / export 都会发
/// `eventChangedNotification`——成功与否、失败的 CKError 全在里面,只是 SwiftData
/// 不转述。这里把它们收起来,连同账号状态、数据库实际模式(`AppDatabase.mode`)
/// 摆到 设置 → iCloud → 同步状态。
///
/// 要在建 `ModelContainer` **之前**开始监听,不然第一次 setup 事件就错过了。
@MainActor
@Observable
final class CloudSyncMonitor {
    static let shared = CloudSyncMonitor()

    struct Event: Identifiable, Equatable {
        enum Kind: String { case setup, `import`, export, unknown }
        let id: UUID
        let kind: Kind
        let start: Date
        var end: Date?
        var succeeded: Bool
        var error: String?
    }

    /// 最近的事件,新的在前(同一个 identifier 的开始/结束合并成一条)。
    private(set) var events: [Event] = []
    private(set) var accountStatus: CKAccountStatus?
    /// iCloud 用户记录名的末 8 位:两台设备对一下是不是同一个 Apple ID。
    private(set) var accountTag: String?
    private(set) var accountError: String?

    @ObservationIgnored private var observer: NSObjectProtocol?
    private static let log = Logger(subsystem: "com.lodo.app", category: "CloudSync")
    private static let maxEvents = 40

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let kind: Event.Kind
            switch event.type {
            case .setup: kind = .setup
            case .import: kind = .import
            case .export: kind = .export
            @unknown default: kind = .unknown
            }
            let item = Event(id: event.identifier, kind: kind, start: event.startDate,
                             end: event.endDate, succeeded: event.succeeded,
                             error: event.error.map(Self.describe))
            MainActor.assumeIsolated { CloudSyncMonitor.shared.record(item) }
        }
    }

    private func record(_ event: Event) {
        if let error = event.error {
            Self.log.error("\(event.kind.rawValue, privacy: .public) failed: \(error, privacy: .public)")
        }
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.insert(event, at: 0)
            if events.count > Self.maxEvents { events.removeLast() }
        }
    }

    func refreshAccount() async {
        let container = CKContainer(identifier: SharedTripSync.containerID)
        do {
            accountStatus = try await container.accountStatus()
            accountError = nil
        } catch {
            accountStatus = nil
            accountError = Self.describe(error)
        }
        if accountStatus == .available, let id = try? await container.userRecordID() {
            accountTag = String(id.recordName.suffix(8))
        }
    }

    /// CKError 带上错误码名字和 retryAfter,partialFailure 展开里面第一条——
    /// 光看 localizedDescription 经常只有一句"部分失败"。
    nonisolated static func describe(_ error: Error) -> String {
        guard let ck = error as? CKError else { return error.localizedDescription }
        var text = "CKError \(ck.code.rawValue): \(ck.localizedDescription)"
        if let seconds = ck.retryAfterSeconds { text += "(\(Int(seconds)) 秒后重试)" }
        if ck.code == .partialFailure, let first = ck.partialErrorsByItemID?.values.first {
            text += " → " + describe(first)
        }
        return text
    }

    /// 这个安装包连的是 CloudKit 的哪个环境。Xcode 调试安装(描述文件带
    /// get-task-allow)连 Development;TestFlight / App Store(没有 embedded
    /// 描述文件)和 Ad Hoc 连 Production。**两台设备环境不同,数据永远互相看不见**。
    static var environment: String {
        #if targetEnvironment(simulator)
        return String(localized: "Development(模拟器)", bundle: .appLanguage())
        #elseif os(iOS)
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else {
            return String(localized: "Production(TestFlight / App Store)", bundle: .appLanguage())
        }
        if let range = text.range(of: "<key>get-task-allow</key>"),
           text[range.upperBound...].prefix(40).contains("<true/>") {
            return String(localized: "Development(Xcode 调试安装)", bundle: .appLanguage())
        }
        return String(localized: "Production(Ad Hoc)", bundle: .appLanguage())
        #else
        return String(localized: "macOS:取决于签名方式", bundle: .appLanguage())
        #endif
    }
}
