import SwiftUI
import SwiftData
import CloudKit
import LodoCore

/// 设置 → iCloud → 同步状态:排查"同一个 Apple ID 的两台设备不同步"用。
/// 两台设备各打开这一页对一下:账号标识、环境、数据库模式要一致,事件里不该有红字,
/// 下面几类数据的条数同步完成后应该相同。
struct CloudSyncStatusView: View {
    @Environment(\.modelContext) private var context
    @State private var monitor = CloudSyncMonitor.shared
    @State private var counts: [(String, Int)] = []

    var body: some View {
        List {
            Section {
                row("账号", accountText)
                if let tag = monitor.accountTag { row("账号标识", "…" + tag) }
                row("环境", CloudSyncMonitor.environment)
                row("数据库", modeText)
                row("设置开关", AppSettings.icloudSyncEnabled ? localized("开") : localized("关"))
            } footer: {
                Text("两台设备的账号标识和环境必须相同才会互相同步。Xcode 直接安装连的是 Development,TestFlight / App Store 连的是 Production,两者数据互不相通。")
            }

            if !AppDatabase.failures.isEmpty {
                Section("数据库启动失败") {
                    ForEach(AppDatabase.failures, id: \.self) { failure in
                        Text(failure)
                            .font(.footnote.monospaced())
                            .foregroundStyle(LodoColor.critical)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                ForEach(counts, id: \.0) { name, count in
                    LabeledContent(localized(String.LocalizationValue(name))) {
                        Text("\(count)").monospacedDigit()
                    }
                }
            } header: {
                Text("本机数据")
            } footer: {
                Text("同步完成后,两台设备上的条数应该相同。")
            }

            Section {
                if monitor.events.isEmpty {
                    Text(eventsEmptyText)
                        .foregroundStyle(.secondary)
                }
                ForEach(monitor.events) { event in
                    eventRow(event)
                }
            } header: {
                Text("同步事件")
            } footer: {
                Text("只记录这次打开 App 之后的事件。setup 是建立同步,import 是从 iCloud 拉取,export 是上传本机改动。")
            }
        }
        .navigationTitle("同步状态")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await monitor.refreshAccount()
            loadCounts()
        }
        .refreshable {
            await monitor.refreshAccount()
            loadCounts()
        }
    }

    /// 视图外拼出来的值按应用内语言取翻译(见 CLAUDE.md 里 `Bundle.appLanguage` 那条)。
    private func localized(_ text: String.LocalizationValue) -> String {
        String(localized: text, bundle: .appLanguage())
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func eventRow(_ event: CloudSyncMonitor.Event) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon(event))
                    .foregroundStyle(color(event))
                Text(event.kind.rawValue)
                    .font(.body.weight(.medium))
                Spacer()
                Text(event.start, format: .dateTime.hour().minute().second())
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let error = event.error {
                Text(error)
                    .font(.footnote.monospaced())
                    .foregroundStyle(LodoColor.critical)
                    .textSelection(.enabled)
            }
        }
    }

    private func icon(_ event: CloudSyncMonitor.Event) -> String {
        if event.end == nil { return "arrow.triangle.2.circlepath" }
        return event.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    private func color(_ event: CloudSyncMonitor.Event) -> Color {
        if event.end == nil { return .secondary }
        return event.succeeded ? LodoColor.positive : LodoColor.critical
    }

    private var accountText: String {
        if let error = monitor.accountError { return error }
        switch monitor.accountStatus {
        case .available: return localized("已登录")
        case .noAccount: return localized("未登录 iCloud")
        case .restricted: return localized("受限制(家长控制/设备管理)")
        case .temporarilyUnavailable: return localized("暂时不可用(需在系统设置里重新验证)")
        case .couldNotDetermine, nil: return localized("无法确定")
        @unknown default: return localized("未知")
        }
    }

    private var modeText: String {
        switch AppDatabase.mode {
        case .appGroupCloudKit: return "App Group + iCloud"
        case .defaultCloudKit: return localized("默认位置 + iCloud")
        case .appGroupLocal: return localized("App Group,仅本机")
        case .defaultLocal: return localized("默认位置,仅本机")
        case .inMemory: return localized("内存(数据不会保存!)")
        }
    }

    private var eventsEmptyText: String {
        switch AppDatabase.mode {
        case .appGroupCloudKit, .defaultCloudKit: return localized("还没有同步事件。")
        default: return localized("这次启动没有接 iCloud,不会有同步事件。")
        }
    }

    private func loadCounts() {
        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? context.fetchCount(FetchDescriptor<T>())) ?? 0
        }
        counts = [
            ("任务", count(TaskItem.self)),
            ("记忆", count(MemoryItem.self)),
            ("记忆分片", count(MemoryChunk.self)),
            ("旅行", count(TravelTrip.self)),
            ("倒数日", count(CountdownEvent.self)),
            ("新闻文章", count(NewsArticle.self)),
            ("AI 对话", count(AgentMessage.self)),
        ]
    }
}
