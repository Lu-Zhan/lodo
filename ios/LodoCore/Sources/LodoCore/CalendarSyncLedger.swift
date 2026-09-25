import Foundation

/// 双向同步的账本:上次对平时每对"任务 ↔ 事件"长什么样(见 `CalendarSyncRecord`)。
///
/// 落 Application Support 的 JSON 而不是 SwiftData,理由同 `AgentConversationSummary`:
/// 这是**可重算的本机派生数据**——文件丢了,下次对账靠事件 URL 上写着的任务 uuid
/// 就能把关系认回来(`CalendarSyncPlanner` 的 claimedUUIDs 那支)。而且它本来就
/// **不该跨设备同步**:事件 id 是每台设备各自的,同步过去只会张冠李戴。
public enum CalendarSyncLedger {
    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "calendar-sync-ledger.json")
    }

    public static var records: [CalendarSyncRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode([CalendarSyncRecord].self, from: data)
        else { return [] }
        return value
    }

    public static func save(_ records: [CalendarSyncRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    public static func append(_ record: CalendarSyncRecord) {
        var all = records.filter { $0.taskUUID != record.taskUUID }
        all.append(record)
        save(all)
    }

    /// 关掉同步开关时连账本一起清:留着的话下次开开关,那些"事件已经被我们删了"
    /// 的记录会被当成"用户在日历里删的",把任务一起删掉。
    public static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
