import Foundation
import SwiftData
import LodoCore

/// Watch App 的数据库入口:CloudKit 同步(与主 App 共用同一个容器 iCloud.com.lodo.app),
/// 不需要 App Group 迁移那套逻辑——Watch 是独立设备,本来就没有旧的本地数据要迁。
/// 除了任务还同步记忆条目(`MemoryItem`):手表上「记一下 / 问一下」读写的就是手机那张表。
/// 只带这两种实体,其余模型(旅行、菜单…)CloudKit 镜像里有也不往手表上拉。
///
/// CloudKit 那份打不开时先退到本机库(不同步,但改动不会丢);两者都打不开才用内存库,
/// 并置 `isTemporary`,首页上明说这次的改动不会保存——不能悄悄让人以为记下了。
/// 内存库必须显式 `cloudKitDatabase: .none`:默认是 .automatic,「内存 + CloudKit」一保存就抛
/// `No eligible connection available` 直接崩(模拟器实测)。
@MainActor
enum WatchDatabase {
    private(set) static var isTemporary = false

    static let container: ModelContainer = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo-watch-today") { return demoContainer() }
        #endif
        if let container = try? ModelContainer(
            for: TaskItem.self, MemoryItem.self,
            configurations: ModelConfiguration(cloudKitDatabase: .automatic)) {
            return container
        }
        if let local = try? ModelContainer(
            for: TaskItem.self, MemoryItem.self,
            configurations: ModelConfiguration(cloudKitDatabase: .none)) {
            return local
        }
        isTemporary = true
        guard let inMemory = try? ModelContainer(
            for: TaskItem.self, MemoryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)) else {
            fatalError("无法初始化数据库(含内存兜底)")
        }
        return inMemory
    }()

    #if DEBUG
    /// 截图核对首页「只看今天」用:内存库(不碰真实数据),该显示的和不该显示的各塞几条。
    private static func demoContainer() -> ModelContainer {
        let container = try! ModelContainer(
            for: TaskItem.self, MemoryItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let context = container.mainContext
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func at(_ dayOffset: Int, _ hour: Int) -> Date {
            calendar.date(byAdding: .hour, value: hour,
                          to: calendar.date(byAdding: .day, value: dayOffset, to: today)!)!
        }
        let tasks = [
            TaskItem(title: "交周报", remindAt: at(0, 23)),               // 今天到期 → 显示
            TaskItem(title: "回房东邮件", remindAt: at(-1, 20)),          // 昨天到期没做 → 显示
            TaskItem(title: "买菜", remindAt: at(1, 10)),                 // 明天 → 不显示
            TaskItem(title: "看《置身事内》", remindAt: TaskItem.inboxDate), // 今天收集 → 显示
            TaskItem(title: "旧想法", remindAt: TaskItem.inboxDate),        // 昨天收集 → 不显示
        ]
        tasks[4].createdAt = at(-1, 9)
        tasks.forEach(context.insert)
        let memories = [
            MemoryItem(kind: .text, title: "班主任喜欢收贺卡", tags: [MemoryItem.autoTagName],
                       sourceText: "班主任喜欢收贺卡", status: .ready),          // 显示
            MemoryItem(kind: .text, title: "体检结果正常", tags: [MemoryItem.healthTagName],
                       sourceText: "体检结果正常", status: .ready),            // 显示
            MemoryItem(kind: .text, title: "昨天的停车位", sourceText: "B2-031", status: .ready), // 昨天 → 不显示
            MemoryItem(kind: .text, title: "张三", tags: [MemoryItem.contactTagName],
                       sourceText: "张三", status: .ready),                    // 人脉 → 不显示
        ]
        memories[2].createdAt = at(-1, 18)
        memories.forEach(context.insert)
        try? context.save()
        return container
    }
    #endif
}
