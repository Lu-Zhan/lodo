import Foundation
import SwiftData
import LodoCore

/// Watch App 的数据库入口:CloudKit 同步(与主 App 共用同一个容器 iCloud.com.lodo.app),
/// 不需要 App Group 迁移那套逻辑——Watch 是独立设备,本来就没有旧的本地数据要迁。
/// 除了任务还同步记忆条目(`MemoryItem`):手表上「记一下 / 问一下」读写的就是手机那张表。
/// 只带这两种实体,其余模型(旅行、菜单…)CloudKit 镜像里有也不往手表上拉。
@MainActor
enum WatchDatabase {
    static let container: ModelContainer = {
        if let container = try? ModelContainer(
            for: TaskItem.self, MemoryItem.self,
            configurations: ModelConfiguration(cloudKitDatabase: .automatic)) {
            return container
        }
        guard let inMemory = try? ModelContainer(
            for: TaskItem.self, MemoryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)) else {
            fatalError("无法初始化数据库(含内存兜底)")
        }
        return inMemory
    }()
}
