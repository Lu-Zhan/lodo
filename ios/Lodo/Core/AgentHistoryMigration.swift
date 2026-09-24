import Foundation
import SwiftData
import LodoCore

/// 「多对话」改成「单一持续对话」那次改造的一次性清空。
///
/// 老库里的 `AgentMessage` 每条都带着 thread 语义(按 thread 分段、各有标题、
/// 撤销按 thread 隔离),混进一条时间线只会得到一串互相打断的上下文,所以直接
/// 清空重来——这是产品决定,不是技术妥协。
///
/// 判据是 `formatVersion == 0`:新代码插入的消息恒为 1,而轻量迁移给老库存量行
/// 填的是属性声明处的默认值 0。**不用 UserDefaults 打标记**——那是单设备的,而
/// CloudKit 默认开着:iPhone 先升级清空、用户又聊了十条同步上云,iPad 几天后
/// 才升级的话会按自己那份标记再清一次,把这十条新的一起删掉。按行判据没有这个
/// 窗口,对晚到的 CloudKit 老记录也照样有效,而且永远幂等。
@MainActor
enum AgentHistoryMigration {
    static func run(container: ModelContainer) {
        let context = container.mainContext
        let legacy = (try? context.fetch(FetchDescriptor<AgentMessage>(
            predicate: #Predicate { $0.formatVersion == 0 }))) ?? []
        guard !legacy.isEmpty else { return }
        for message in legacy { context.delete(message) }
        try? context.save()
        // 摘要是从这些消息压出来的派生数据,一起清掉,免得留下一段指着已经
        // 不存在的对话的上下文。
        AgentConversationSummary.reset()
    }
}
