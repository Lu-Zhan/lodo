import SwiftUI
import SwiftData
import LodoCore

/// "总览" tab:待办/记忆之外新增的第三个 tab,默认打开。聚合到期提醒+今天
/// 待办(可直接滑动完成/改期/稍等/删除、点击编辑,和待办 tab 同一套
/// TaskRowView)、AI 给的今天待办处理建议、AI 给的今天新收藏记忆总结
/// (后两者按天缓存,见 loadSuggestion/loadMemorySummary)。
struct OverviewView: View {
    /// 非 nil 时跳到该事项并自动发起改期请求(通知"改期"按钮交接,见 ContentView)。
    @Binding var rescheduleRequestUUID: String?

    // 以下几个跨 extension 文件(OverviewView+Reschedule)被读写,
    // 不能用 private(Swift 的 private 只对同一文件可见),保持 internal。
    @Environment(\.modelContext) var context
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    var pending: [TaskItem]
    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var memoryItems: [MemoryItem]

    /// 只在进入这个 tab 时刷新一次,不像待办 tab 那样搭一套精确唤醒——总览是
    /// "打开看一眼"的仪表盘,不需要那么实时。
    @State private var now = Date()
    @State private var editingTask: TaskItem?
    @State private var showSettings = false
    @State private var askDurationQueue: [(title: String, planned: Int)] = []
    @State private var suggestion: String?
    @State private var memorySummary: String?
    /// 通知"改期"按钮交接的改期候选(横幅展示,与 TaskRowView 内部滑动触发的
    /// 改期各自独立——见 OverviewView+Reschedule.swift 顶部注释)。
    @State var notificationReschedule: (task: TaskItem, candidates: [(label: String, date: Date)])?
    @State var notificationRescheduleLoading: UUID?
    @State var rescheduleError: String?
    @State var notificationRescheduleTask: Task<Void, Never>?

    private static let suggestionDayKey = "overviewSuggestionDay"
    private static let suggestionTextKey = "overviewSuggestionText"
    private static let memorySummaryDayKey = "overviewMemorySummaryDay"
    private static let memorySummaryTextKey = "overviewMemorySummaryText"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var due: [TaskItem] { pending.filter { $0.nextRemindAt <= now } }
    private var todayUpcoming: [TaskItem] {
        pending.filter { $0.nextRemindAt > now && Calendar.current.isDateInToday($0.nextRemindAt) }
    }
    private var todayMemories: [MemoryItem] {
        memoryItems.filter { Calendar.current.isDateInToday($0.createdAt) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let notificationReschedule {
                    notificationRescheduleSection(notificationReschedule)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if notificationRescheduleLoading != nil {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在获取改期建议…").foregroundStyle(.secondary)
                        }
                    }
                }
                if let ask = askDurationQueue.first {
                    Section {
                        AskDurationBanner(
                            title: ask.title, planned: ask.planned,
                            onPick: { _ in popAskDuration() },
                            onSkip: { popAskDuration() })
                    }
                }
                if due.isEmpty && todayUpcoming.isEmpty {
                    Section {
                        ContentUnavailableView("今天暂无待办", systemImage: "checkmark.circle")
                    }
                } else {
                    if !due.isEmpty {
                        Section("已到期提醒") {
                            ForEach(due) { task in
                                taskRow(task)
                            }
                        }
                    }
                    if !todayUpcoming.isEmpty {
                        Section("今天待办") {
                            ForEach(todayUpcoming) { task in
                                taskRow(task)
                            }
                        }
                    }
                }
                if let suggestion {
                    Section("处理建议") {
                        Label(suggestion, systemImage: "sparkles")
                            .font(.subheadline)
                    }
                }
                if let memorySummary {
                    Section("今天的记忆") {
                        Label(memorySummary, systemImage: "sparkles.rectangle.stack")
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("总览")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                }
            }
            .sheet(item: $editingTask) { task in
                TaskEditView(existing: task, parsed: nil, attachment: task.attachment) {
                    TaskActions.apply($0, to: task, context: context)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("改期失败", isPresented: Binding(
                get: { rescheduleError != nil },
                set: { if !$0 { rescheduleError = nil } }
            )) {
                Button("好", role: .cancel) { rescheduleError = nil }
            } message: {
                Text(rescheduleError ?? "")
            }
            .onChange(of: rescheduleRequestUUID) { _, uuid in
                consumeReschedule(uuid)
            }
            .onAppear {
                consumeReschedule(rescheduleRequestUUID)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-reschedule"),
                   let first = due.first {
                    notificationReschedule = (first, [
                        (label: "今晚 20:00", date: Date().addingTimeInterval(6 * 3600)),
                        (label: "明早 9:00", date: Date().addingTimeInterval(19 * 3600)),
                        (label: "周六上午", date: Date().addingTimeInterval(48 * 3600)),
                    ])
                }
                // 截图验证用:设置按钮挪到总览后,--demo-settings 也跟着挪过来。
                if ProcessInfo.processInfo.arguments.contains("--demo-settings") {
                    showSettings = true
                }
                #endif
            }
            .task {
                now = Date()
                await loadSuggestion()
                await loadMemorySummary()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-overview-ai") {
                    suggestion = "先处理到期的「团队周会」,再按时间顺序做剩下几件,写周报可以留到最后。"
                    memorySummary = "今天收藏的都是效率类内容,建议这周找时间整理一下笔记。"
                }
                #endif
            }
            .refreshable {
                await loadSuggestion(force: true)
                await loadMemorySummary(force: true)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func taskRow(_ task: TaskItem) -> some View {
        TaskRowView(task: task, now: now,
                    onEdit: { editingTask = task },
                    onAskDuration: { title, planned in
                        askDurationQueue.append((title, planned))
                    })
    }

    /// 通知"改期"按钮交接的改期候选横幅(见 OverviewView+Reschedule.swift)。
    private func notificationRescheduleSection(
        _ reschedule: (task: TaskItem, candidates: [(label: String, date: Date)])
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("「\(reschedule.task.title)」改期建议").font(.subheadline)
                HorizontalChipRow {
                    ForEach(reschedule.candidates, id: \.label) { candidate in
                        Button(candidate.label) {
                            applyNotificationReschedule(candidate.date)
                        }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                        .tint(.accentColor)
                    }
                    Button {
                        withAnimation(.snappy) { notificationReschedule = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    #if os(iOS)
                    .hoverEffect(.highlight)
                    #endif
                    .accessibilityLabel("收起改期候选")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func popAskDuration() {
        withAnimation(.snappy) {
            if !askDurationQueue.isEmpty { askDurationQueue.removeFirst() }
        }
    }

    /// 按天缓存(参考 TodoListView.loadInsight 按 ISO 周缓存的做法),只在成功
    /// 时写缓存——离线/请求失败不会把当天"钉死"成空。没有待办时不请求,清空展示。
    private func loadSuggestion(force: Bool = false) async {
        guard DeepSeekClient.isConfigured else { return }
        let items = due + todayUpcoming
        guard !items.isEmpty else {
            suggestion = nil
            return
        }
        let stamp = Self.dayFormatter.string(from: Date())
        let defaults = UserDefaults.standard
        if !force, defaults.string(forKey: Self.suggestionDayKey) == stamp,
           let cached = defaults.string(forKey: Self.suggestionTextKey) {
            suggestion = cached
            return
        }
        let summary = items.map { "「\($0.title)」\($0.caption)" }.joined(separator: "、")
        guard let text = try? await DeepSeekClient.suggestTodayHandling(summary: summary) else { return }
        defaults.set(stamp, forKey: Self.suggestionDayKey)
        defaults.set(text, forKey: Self.suggestionTextKey)
        suggestion = text
    }

    private func loadMemorySummary(force: Bool = false) async {
        guard DeepSeekClient.isConfigured else { return }
        guard !todayMemories.isEmpty else {
            memorySummary = nil
            return
        }
        let stamp = Self.dayFormatter.string(from: Date())
        let defaults = UserDefaults.standard
        if !force, defaults.string(forKey: Self.memorySummaryDayKey) == stamp,
           let cached = defaults.string(forKey: Self.memorySummaryTextKey) {
            memorySummary = cached
            return
        }
        let summary = todayMemories.map { "「\($0.title)」\($0.summary)" }.joined(separator: "、")
        guard let text = try? await DeepSeekClient.summarizeTodayMemories(summary: summary) else { return }
        defaults.set(stamp, forKey: Self.memorySummaryDayKey)
        defaults.set(text, forKey: Self.memorySummaryTextKey)
        memorySummary = text
    }
}
