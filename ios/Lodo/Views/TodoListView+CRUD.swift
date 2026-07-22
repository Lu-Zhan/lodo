import SwiftUI
import LodoCore

/// 新建/编辑/完成的落库逻辑,以及耗时采样轻量条的辅助函数。
extension TodoListView {
    func popAskDuration() {
        withAnimation(.snappy) {
            if !askDurationQueue.isEmpty { askDurationQueue.removeFirst() }
        }
    }

    func durationChips(planned: Int) -> [Int] {
        let lower = max(5, (planned / 2 + 2) / 5 * 5)
        let upper = (planned * 3 / 2 + 2) / 5 * 5
        var chips: [Int] = []
        for value in [lower, planned, upper] where !chips.contains(value) {
            chips.append(value)
        }
        return chips
    }

    func dueCaption(_ task: TaskItem) -> String {
        if task.phase == .end { return "时间到 — 完成了吗?" }
        if task.durationMinutes > 0 {
            return "\(task.caption) — 该开始了!"
        }
        return task.caption
    }

    /// 完成 + 实际耗时采样:仅真正"完成一次"(非两阶段的"开始了")且命中采样时,
    /// 顶部出轻量条询问实际用时(排队,连续完成不覆盖)。
    func completeWithSampling(_ task: TaskItem) {
        let title = task.title
        let planned = task.durationMinutes
        // phase==start 且有时长的这次点按是"开始了",不算完成
        let isFinishing = !(task.phase == .start && task.durationMinutes > 0)
        withAnimation(.snappy) {
            NotificationManager.shared.complete(task, context: context)
        }
        if isFinishing, planned > 0,
           DurationMemory.shouldAskActual(title: title, planned: planned) {
            withAnimation(.snappy) {
                askDurationQueue.append((title, planned))
            }
        }
    }

    /// 记忆条目"转为待办"交接:弹出新建表单,预填标题+内容附件,时间用默认值待用户
    /// 手动调整(与空白新建同一套默认值,见 TaskFormModel.init);原记忆条目不受影响。
    func consumeConvertToTodo(_ request: ConvertToTodoRequest?) {
        guard let request else { return }
        convertToTodoRequest = nil
        let parsed = ParsedTask(
            title: request.title, remindAt: Date().addingTimeInterval(300), allDay: false,
            durationMinutes: 0, repeatType: .none, repeatDays: [], repeatTimes: [])
        sheet = .create(parsed, request.attachment)
    }

    @discardableResult
    func saveNew(_ parsed: ParsedTask, attachment: TaskAttachment? = nil) -> TaskItem {
        let task = TaskItem(
            title: parsed.title, remindAt: parsed.remindAt,
            durationMinutes: parsed.durationMinutes, allDay: parsed.allDay,
            repeatType: parsed.repeatType, repeatDays: parsed.repeatDays,
            repeatTimes: parsed.repeatTimes)
        task.attachment = attachment
        context.insert(task)
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
        DurationMemory.learn(title: parsed.title, durationMinutes: parsed.durationMinutes)
        return task
    }

    func apply(_ parsed: ParsedTask, to task: TaskItem) {
        task.title = parsed.title
        task.remindAt = parsed.remindAt
        task.durationMinutes = parsed.durationMinutes
        task.allDay = parsed.allDay
        task.repeatTypeRaw = parsed.repeatType.rawValue
        task.repeatDays = parsed.repeatDays
        task.repeatTimes = parsed.repeatTimes
        task.phaseRaw = TaskPhase.start.rawValue
        task.nextRemindAt = parsed.remindAt
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
        DurationMemory.learn(title: parsed.title, durationMinutes: parsed.durationMinutes)
    }

    #if DEBUG
    /// 截图/测试用(--demo-seed-data,仅在待办为空时插入):覆盖到期、时长两阶段、
    /// 每日/每周重复、全天几种典型场景,不含 AI 请求。
    func seedDemoData() {
        let calendar = Calendar.current
        let now = Date()

        saveNew(ParsedTask(
            title: "买菜", remindAt: now.addingTimeInterval(2 * 3600), allDay: false,
            durationMinutes: 0, repeatType: .none, repeatDays: [], repeatTimes: []))

        saveNew(ParsedTask(
            title: "写周报", remindAt: now.addingTimeInterval(4 * 3600), allDay: false,
            durationMinutes: 30, repeatType: .none, repeatDays: [], repeatTimes: []))

        saveNew(ParsedTask(
            title: "交房租", remindAt: now.addingTimeInterval(-3600), allDay: false,
            durationMinutes: 0, repeatType: .none, repeatDays: [], repeatTimes: []))

        let waterTimes = ["09:00", "15:00", "21:00"]
        saveNew(ParsedTask(
            title: "喝水", remindAt: AppSettings.time(waterTimes[0], on: now), allDay: false,
            durationMinutes: 0, repeatType: .daily, repeatDays: [], repeatTimes: waterTimes))

        let weekday = (calendar.component(.weekday, from: now) + 5) % 7
        let meetingTime = AppSettings.hhmm(from: now.addingTimeInterval(3600))
        saveNew(ParsedTask(
            title: "团队周会", remindAt: AppSettings.time(meetingTime, on: now), allDay: false,
            durationMinutes: 60, repeatType: .weekly, repeatDays: [weekday],
            repeatTimes: [meetingTime]))

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            saveNew(ParsedTask(
                title: "妈妈生日", remindAt: AppSettings.time(AppSettings.allDayTime, on: tomorrow),
                allDay: true, durationMinutes: 0, repeatType: .none, repeatDays: [],
                repeatTimes: []))
        }
    }
    #endif
}
