import Foundation
import SwiftData
import LodoCore

/// 待办"项目"名称全集:直接取当前所有事项已经用过的 project 值去重,不像
/// MemoryTags 那样另建一个独立的管理模型——project 就是一个纯字符串字段,
/// 用过的名字本身就是"已有项目列表"。
@MainActor
enum TaskProjects {
    /// 按使用次数降序、同次数按名称升序,供 AI prompt(优先复用已有项目名)与
    /// 表单里的已有项目 chip 行共用。
    static func all(in context: ModelContext) -> [String] {
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        var counts: [String: Int] = [:]
        for task in tasks {
            guard let name = task.project?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            counts[name, default: 0] += 1
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map(\.key)
    }
}
