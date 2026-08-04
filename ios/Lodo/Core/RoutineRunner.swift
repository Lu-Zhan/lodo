import Foundation
import SwiftData
import UserNotifications
import LodoCore
#if os(iOS)
import BackgroundTasks
#endif

/// 定时任务(`AIRoutine`)的执行层:到点跑 AI、把结果落库、推通知、排下一次。
///
/// iOS 不允许 app 在后台跑定时器,所以和纠缠提醒一样是**两条腿走路**:
/// 1. **后台刷新**(`BGAppRefreshTask`,SwiftUI 的 `.backgroundTask` 注册):
///    系统在接近计划时间时给一小段执行时间,跑完把结果**当场推成通知**,
///    用户不用打开 app 就能看到内容。什么时候真的给、给不给由系统决定。
/// 2. **到点提醒通知**(预排的本地通知,兜底):后台刷新没被调度到时,
///    到点仍会响一条"打开看看",用户点开时前台补跑,内容在 app 里显示。
///
/// 前台补跑**不推通知**——人已经在看 app 了,再弹横幅是噪音;后台跑完才推。
/// 同一个时间槽只会跑一次(`AIRoutine.lastScheduledSlot`),错过超过 6 小时
/// 就直接跳过等下一次(`RoutineSchedule.catchUpWindow`)。
@MainActor
enum RoutineRunner {
    /// 与 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 一致。
    static let backgroundTaskID = "com.lodo.app.routine"

    private static let duePrefix = "routine-due-"
    private static let resultPrefix = "routine-result-"

    /// 每条任务最多预排 3 次"到点提醒",全局上限 6 条:系统 pending 通知总数上限 64,
    /// 纠缠链已经占了 48(NotificationManager.chainBudget),汇总还要一些,这里不能贪。
    private static let duePerRoutine = 3
    private static let dueBudget = 6

    /// ReAct 循环上限:1 次初始 + 2 次工具调用,与 AI 助手对话入口(route)一致。
    private static let maxRounds = 3

    /// 运行历史保留天数,超期的在每次排程时清掉。
    private static let historyRetentionDays = 30

    // MARK: - 查询

    static func allRoutines(_ context: ModelContext) -> [AIRoutine] {
        let descriptor = FetchDescriptor<AIRoutine>(
            sortBy: [SortDescriptor(\AIRoutine.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 某条任务的运行历史(新的在前)。
    static func runs(of routine: AIRoutine, context: ModelContext, limit: Int = 20) -> [AIRoutineRun] {
        let uuid = routine.uuid
        var descriptor = FetchDescriptor<AIRoutineRun>(
            predicate: #Predicate { $0.routineUUID == uuid },
            sortBy: [SortDescriptor(\AIRoutineRun.createdAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 删除任务时连它的运行历史一起删(历史记录只对这条任务有意义)。
    static func delete(_ routine: AIRoutine, context: ModelContext) {
        for run in runs(of: routine, context: context, limit: 1000) {
            context.delete(run)
        }
        context.delete(routine)
        try? context.save()
        refreshSchedule(context: context)
    }

    // MARK: - 执行

    /// 跑完所有到点未跑的任务。
    /// notifyResults:后台刷新传 true(结果直接推给用户),前台补跑传 false。
    static func runDueRoutines(context: ModelContext, notifyResults: Bool) async {
        // 没配 AI 服务就整个跳过:定时任务本来就是 AI 跑的,每天攒一条失败记录
        // 只是噪音(用户在编辑页点"试运行"时会看到真正的报错)。
        guard DeepSeekClient.isConfigured else { return }
        let now = Date()
        let due = allRoutines(context).filter { $0.enabled }.compactMap { routine in
            RoutineSchedule.dueSlot(now: now, lastSlot: routine.lastScheduledSlot,
                                    times: routine.times, repeatType: routine.repeatType,
                                    days: routine.days).map { (routine, $0) }
        }
        for (routine, slot) in due {
            if Task.isCancelled { break }
            // 先占住槽位再跑:AI 请求可能要十几秒,期间 app 又被唤醒一次的话
            // 不能让同一个槽位跑第二遍(重复扣 token、重复推通知)。
            let previousSlot = routine.lastScheduledSlot
            routine.lastScheduledSlot = slot
            try? context.save()
            let result = await run(routine, context: context, manual: false, notify: notifyResults)
            // 后台执行时间用完会被取消:这次根本没跑出结果,把槽位还回去,
            // 留给下次唤醒/回前台补跑(补跑窗口内还算数),否则这一天就静默没了。
            if case .failure(let error) = result, error is CancellationError {
                routine.lastScheduledSlot = previousSlot
                try? context.save()
                break
            }
        }
        refreshSchedule(context: context)
    }

    /// 跑一次(计划触发或用户手动"立即运行"),结果落成一条 `AIRoutineRun`。
    /// manual:手动运行不占计划槽位,历史里也标出来。
    /// notify:成功后推一条带正文的通知(失败不推——定时任务失败不值得打扰用户,
    /// 详情页里能看到失败原因)。
    @discardableResult
    static func run(_ routine: AIRoutine, context: ModelContext,
                    manual: Bool, notify: Bool) async -> Result<String, Error> {
        let name = routine.name
        let uuid = routine.uuid
        let wantsNotification = notify && routine.notify
        do {
            let text = try await generate(
                name: routine.name, prompt: routine.prompt, includeTasks: routine.includeTasks,
                useWebSearch: routine.useWebSearch, context: context)
            context.insert(AIRoutineRun(routineUUID: uuid, routineName: name,
                                        text: text, manual: manual))
            try? context.save()
            if wantsNotification { deliverResult(name: name, text: text, routineUUID: uuid) }
            return .success(text)
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            context.insert(AIRoutineRun(routineUUID: uuid, routineName: name,
                                        text: error.localizedDescription,
                                        failed: true, manual: manual))
            try? context.save()
            return .failure(error)
        }
    }

    /// 编辑页的"试运行":跑一次拿结果给用户看效果,不落库、不推通知、不占槽位。
    /// 任务还没保存(新建中)也能用——所以按字段传参而不是传模型。
    static func preview(name: String, prompt: String, includeTasks: Bool,
                        useWebSearch: Bool, context: ModelContext) async throws -> String {
        try await generate(name: name, prompt: prompt, includeTasks: includeTasks,
                           useWebSearch: useWebSearch, context: context)
    }

    /// 一次完整的 ReAct 循环:模型要联网就先执行工具,把结果喂回去再问一轮。
    /// 工具只有联网搜索/抓链接两个只读操作——定时任务只产出文字,不碰待办数据。
    private static func generate(name: String, prompt: String, includeTasks: Bool,
                                 useWebSearch: Bool, context: ModelContext) async throws -> String {
        let webSearchEnabled = useWebSearch && WebSearchClient.isConfigured
        let taskContext = includeTasks ? todayTaskSummary(context: context) : nil
        let instruction = prompt
        var history: [(role: String, content: String)] = []
        var currentText = instruction

        for _ in 0..<maxRounds {
            switch try await DeepSeekClient.runRoutine(
                name: name, instruction: currentText, taskContext: taskContext,
                webSearchEnabled: webSearchEnabled, history: history) {
            case .text(let text):
                return text
            case .toolCall(let thought, .webSearch(let query)):
                let observation: String
                do {
                    let results = try await WebSearchClient.search(query)
                    observation = results.isEmpty ? "没有搜到相关结果" :
                        results.map { "「\($0.title)」\($0.snippet)\n来源:\($0.url)" }
                            .joined(separator: "\n\n")
                } catch {
                    observation = "联网搜索失败:\(error.localizedDescription)"
                }
                history.append((role: "assistant", content: "思考:\(thought);联网搜索:\(query)"))
                history.append((role: "user", content: "搜索结果:\n\(observation)"))
                currentText = "(请基于以上搜索结果完成最初的任务:\(instruction))"
            case .toolCall(let thought, .webFetch(let urlString)):
                let observation: String
                if let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true {
                    let extraction = await ContentExtractor.extract(url: url)
                    observation = extraction.text.isEmpty ? "抓取失败或页面无正文内容" : extraction.text
                } else {
                    observation = "无效链接:\(urlString)"
                }
                history.append((role: "assistant", content: "思考:\(thought);抓取链接:\(urlString)"))
                history.append((role: "user", content: "链接内容:\n\(observation)"))
                currentText = "(请基于以上链接内容完成最初的任务:\(instruction))"
            case .toolCall(_, .searchMemory):
                // 定时任务的 prompt 里没给过查记忆这个工具,模型幻觉出来直接当没有
                throw DeepSeekError.parse("返回格式异常:定时任务不支持这个工具")
            }
        }
        throw DeepSeekError.parse("联网查了几轮仍然没给出结果,请稍后重试。")
    }

    /// 今天的待办上下文(未完成 + 今天已完成),给"总结/复盘"类任务当素材。
    private static func todayTaskSummary(context: ModelContext) -> String {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? startOfDay.addingTimeInterval(86400)
        var descriptor = FetchDescriptor<TaskItem>()
        descriptor.sortBy = [SortDescriptor(\TaskItem.nextRemindAt)]
        let all = (try? context.fetch(descriptor)) ?? []

        let pending = all.filter { $0.status == .pending && $0.nextRemindAt < endOfToday }
            .prefix(30)
        let done = all.filter { $0.status == .done && ($0.doneAt ?? .distantPast) >= startOfDay }
            .prefix(30)
        var lines: [String] = []
        if pending.isEmpty {
            lines.append("待办:今天没有要做的事。")
        } else {
            lines.append("待办:")
            lines.append(contentsOf: pending.map { "- 「\($0.title)」\($0.caption)" })
        }
        if !done.isEmpty {
            lines.append("今天已完成:")
            lines.append(contentsOf: done.map { "- 「\($0.title)」" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 通知与排程

    /// 后台跑完当场推给用户的结果通知(正文就是 AI 生成的内容,点开进 app)。
    private static func deliverResult(name: String, text: String, routineUUID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = text
        content.sound = .default
        content.userInfo = ["routineUUID": routineUUID.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "\(resultPrefix)\(routineUUID.uuidString)-\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil))
    }

    /// 重排"到点提醒"兜底通知 + 后台刷新请求 + 清理过期历史。
    /// 每次跑完任务、改完设置、app 回前台时调用;整体先按前缀清空再重排
    /// (和汇总通知同一个套路,任务数量/时间点会变,逐条对齐不划算)。
    static func refreshSchedule(context: ModelContext) {
        pruneHistory(context: context)
        // 时间点在主线程上先算成纯数据再进通知中心的回调:SwiftData 模型不是
        // Sendable,不能带进后台队列的闭包里。
        // 每条任务最多 3 次,全局按时间先后取前 6 个,保证多条任务都能排上最近的
        // 一次,而不是被某一条排满。
        var slots: [(title: String, uuid: String, date: Date)] = []
        for routine in allRoutines(context) where routine.enabled && routine.notify {
            var cursor = Date()
            for _ in 0..<duePerRoutine {
                guard let next = routine.nextRun(after: cursor) else { break }
                slots.append((routine.name.isEmpty ? "定时任务" : routine.name,
                              routine.uuid.uuidString, next))
                cursor = next
            }
        }
        let planned = Array(slots.sorted { $0.date < $1.date }.prefix(dueBudget))

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let old = requests.map(\.identifier).filter { $0.hasPrefix(duePrefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for (index, slot) in planned.enumerated() {
                let content = UNMutableNotificationContent()
                content.title = slot.title
                content.body = "到时间了,打开看看今天的内容。"
                content.sound = .default
                content.userInfo = ["routineUUID": slot.uuid]
                center.add(UNNotificationRequest(
                    identifier: "\(duePrefix)\(index)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(
                        timeInterval: max(1, slot.date.timeIntervalSinceNow), repeats: false)))
            }
        }
        scheduleBackgroundRefresh(context: context)
    }

    private static func pruneHistory(context: ModelContext) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -historyRetentionDays,
                                           to: Date()) ?? .distantPast
        let descriptor = FetchDescriptor<AIRoutineRun>(
            predicate: #Predicate { $0.createdAt < cutoff })
        for run in (try? context.fetch(descriptor)) ?? [] {
            context.delete(run)
        }
        try? context.save()
    }

    /// 把后台刷新请求挂到最近一次计划触发时间。系统只把它当"不早于"的建议,
    /// 实际什么时候唤醒(甚至给不给)由系统按使用习惯/电量决定——所以才需要
    /// 上面那条到点提醒兜底。
    private static func scheduleBackgroundRefresh(context: ModelContext) {
        #if os(iOS)
        let next = allRoutines(context).filter(\.enabled)
            .compactMap { $0.nextRun() }.min()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskID)
        guard let next else { return }
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskID)
        request.earliestBeginDate = next
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    /// 后台刷新被系统唤醒时的入口(LodoApp 的 .backgroundTask 调用)。
    static func handleBackgroundRefresh(container: ModelContainer) async {
        await runDueRoutines(context: container.mainContext, notifyResults: true)
    }
}
