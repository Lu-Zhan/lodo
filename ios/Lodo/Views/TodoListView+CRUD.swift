import SwiftUI
import LodoCore

/// 新建/编辑/完成的落库逻辑,以及耗时采样轻量条的辅助函数。
extension TodoListView {
    func popAskDuration() {
        withAnimation(.snappy) {
            if !askDurationQueue.isEmpty { askDurationQueue.removeFirst() }
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
            repeatTimes: parsed.repeatTimes, project: parsed.project)
        task.attachment = attachment
        context.insert(task)
        try? context.save()
        NotificationManager.shared.rebuild(for: task)
        DurationMemory.learn(title: parsed.title, durationMinutes: parsed.durationMinutes)
        return task
    }

    func apply(_ parsed: ParsedTask, to task: TaskItem) {
        TaskActions.apply(parsed, to: task, context: context)
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

    /// 截图/测试用(--demo-project-list/--demo-project-timeline,仅在待办为空时
    /// 插入):跨"工作/健康/生活/未分类"几个项目,含零时长(圆点兜底)和全天
    /// (条带兜底)两种边界场景。
    func seedProjectDemoData() {
        let now = Date()

        saveNew(ParsedTask(
            title: "写周报", remindAt: now.addingTimeInterval(3600), allDay: false,
            durationMinutes: 45, repeatType: .none, repeatDays: [], repeatTimes: [],
            project: "工作"))

        saveNew(ParsedTask(
            title: "团队周会", remindAt: now.addingTimeInterval(2.5 * 3600), allDay: false,
            durationMinutes: 60, repeatType: .none, repeatDays: [], repeatTimes: [],
            project: "工作"))

        saveNew(ParsedTask(
            title: "健身", remindAt: now.addingTimeInterval(1.5 * 3600), allDay: false,
            durationMinutes: 50, repeatType: .none, repeatDays: [], repeatTimes: [],
            project: "健康"))

        saveNew(ParsedTask(
            title: "买菜", remindAt: now.addingTimeInterval(0.5 * 3600), allDay: false,
            durationMinutes: 0, repeatType: .none, repeatDays: [], repeatTimes: [],
            project: "生活"))

        saveNew(ParsedTask(
            title: "交房租", remindAt: now.addingTimeInterval(-3600), allDay: false,
            durationMinutes: 0, repeatType: .none, repeatDays: [], repeatTimes: [],
            project: nil))

        saveNew(ParsedTask(
            title: "妈妈生日", remindAt: AppSettings.time(AppSettings.allDayTime, on: now),
            allDay: true, durationMinutes: 0, repeatType: .none, repeatDays: [], repeatTimes: [],
            project: "生活"))
    }
    #endif
}
