import Foundation
import SwiftData
import OSLog
import LodoCore

/// App 本体与 App Intents 共用的数据库入口:
/// App Group 存储(小组件/Intent 可读)+ CloudKit 同步(供 Watch App、多设备间共用同一份数据),
/// 老库首次自动迁移。
@MainActor
enum AppDatabase {
    /// 最后实际用上的是哪一种配置。原来是 `try?` 一路静默退回,iCloud 容器建不起来
    /// 时用户只看到"不同步",没人知道其实早退到了本地库甚至内存库——设置 → iCloud
    /// → 同步状态 把它和失败原因摆出来(见 `CloudSyncMonitor`)。
    enum Mode: String {
        case appGroupCloudKit, appGroupLocal, defaultCloudKit, defaultLocal, inMemory
    }

    // 只在 container 的一次性初始化里写、之后只读,不会并发。
    nonisolated(unsafe) private(set) static var mode: Mode = .inMemory
    /// 在用上最终配置之前,前面每一级失败的原因(按尝试顺序)。
    nonisolated(unsafe) private(set) static var failures: [String] = []

    static let log = Logger(subsystem: "com.lodo.app", category: "CloudSync")

    private static let models: [any PersistentModel.Type] = [
        TaskItem.self, MemoryItem.self, MemoryTag.self, MemoryChunk.self,
        AgentMessage.self, AIRoutine.self, AIRoutineRun.self,
        ContactRelationship.self, TravelTrip.self, MenuDish.self,
        NewsFeed.self, NewsArticle.self, CountdownEvent.self, PackingItem.self, FinanceEntry.self,
    ]

    /// 依次尝试 App Group 存储 → 默认存储 → 内存态兜底,避免存储损坏/迁移失败时直接崩溃。
    /// 前两级是否开 CloudKit 同步由设置里的开关决定(默认开,entitlements 里声明的容器);
    /// 内存兜底永远不接 CloudKit,纯粹是最后一道"至少能打开"的保险。
    /// 开关只在启动时读取一次(ModelContainer 只能创建一次),关闭/开启后需要重新打开 App 才生效。
    static let container: ModelContainer = {
        let cloudKitOn = AppSettings.icloudSyncEnabled
        let cloudKit: ModelConfiguration.CloudKitDatabase = cloudKitOn ? .automatic : .none
        let schema = Schema(models)

        func attempt(_ name: String, _ configuration: ModelConfiguration) -> ModelContainer? {
            do {
                return try ModelContainer(for: schema, configurations: configuration)
            } catch {
                let message = "\(name): \(error)"
                log.error("\(message, privacy: .public)")
                failures.append(message)
                return nil
            }
        }

        if let storeURL = AppGroup.storeURL {
            AppGroup.migrateLegacyStoreIfNeeded(to: storeURL)
            if let container = attempt("App Group", ModelConfiguration(
                schema: schema, url: storeURL, cloudKitDatabase: cloudKit)) {
                mode = cloudKitOn ? .appGroupCloudKit : .appGroupLocal
                return container
            }
        } else {
            failures.append("App Group: containerURL 为 nil(entitlements 里没有 group.com.lodo.app?)")
        }
        if let container = attempt("默认位置", ModelConfiguration(
            schema: schema, cloudKitDatabase: cloudKit)) {
            mode = cloudKitOn ? .defaultCloudKit : .defaultLocal
            return container
        }
        guard let inMemory = attempt("内存", ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true)) else {
            fatalError("无法初始化数据库(含内存兜底)")
        }
        mode = .inMemory
        return inMemory
    }()
}
