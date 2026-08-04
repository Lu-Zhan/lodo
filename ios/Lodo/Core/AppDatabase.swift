import Foundation
import SwiftData
import LodoCore

/// App 本体与 App Intents 共用的数据库入口:
/// App Group 存储(小组件/Intent 可读)+ CloudKit 同步(供 Watch App、多设备间共用同一份数据),
/// 老库首次自动迁移。
@MainActor
enum AppDatabase {
    /// 依次尝试 App Group 存储 → 默认存储 → 内存态兜底,避免存储损坏/迁移失败时直接崩溃。
    /// 前两级是否开 CloudKit 同步由设置里的开关决定(默认开,entitlements 里声明的容器);
    /// 内存兜底永远不接 CloudKit,纯粹是最后一道"至少能打开"的保险。
    /// 开关只在启动时读取一次(ModelContainer 只能创建一次),关闭/开启后需要重新打开 App 才生效。
    static let container: ModelContainer = {
        let cloudKit: ModelConfiguration.CloudKitDatabase =
            AppSettings.icloudSyncEnabled ? .automatic : .none
        if let storeURL = AppGroup.storeURL {
            AppGroup.migrateLegacyStoreIfNeeded(to: storeURL)
            if let container = try? ModelContainer(
                for: TaskItem.self, MemoryItem.self, MemoryTag.self, MemoryChunk.self,
                    AgentThread.self, AgentMessage.self, AIRoutine.self, AIRoutineRun.self,
                configurations: ModelConfiguration(url: storeURL, cloudKitDatabase: cloudKit)) {
                return container
            }
        }
        if let container = try? ModelContainer(
            for: TaskItem.self, MemoryItem.self, MemoryTag.self, MemoryChunk.self,
                AgentThread.self, AgentMessage.self, AIRoutine.self, AIRoutineRun.self,
            configurations: ModelConfiguration(cloudKitDatabase: cloudKit)) {
            return container
        }
        guard let inMemory = try? ModelContainer(
            for: TaskItem.self, MemoryItem.self, MemoryTag.self, MemoryChunk.self,
                AgentThread.self, AgentMessage.self, AIRoutine.self, AIRoutineRun.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)) else {
            fatalError("无法初始化数据库(含内存兜底)")
        }
        return inMemory
    }()
}
