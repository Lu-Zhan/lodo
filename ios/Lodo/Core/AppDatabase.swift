import Foundation
import SwiftData

/// App 本体与 App Intents 共用的数据库入口:
/// App Group 存储(小组件/Intent 可读),老库首次自动迁移。
@MainActor
enum AppDatabase {
    static let container: ModelContainer = {
        do {
            if let storeURL = AppGroup.storeURL {
                AppGroup.migrateLegacyStoreIfNeeded(to: storeURL)
                return try ModelContainer(
                    for: TaskItem.self,
                    configurations: ModelConfiguration(url: storeURL))
            }
            return try ModelContainer(for: TaskItem.self)
        } catch {
            fatalError("无法初始化数据库:\(error)")
        }
    }()
}
