import SwiftUI
import SwiftData
import LodoCore

/// AI 页的宿主:持有 agent 路由要用的数据与暂存态(待确认的批量操作、撤销快照),
/// 把它们接到 `AgentView` 上。这些东西原先长在 `TodoListView` 里——那时 AI 是从
/// 待办页弹出的模态;改成抽屉导航后 AI 是和待办平级的页面,不该再寄生在待办页
/// 的生命周期上。路由逻辑本身见 `AgentHostView+Routing.swift`(整段照搬,未改语义)。
struct AgentHostView: View {
    // 路由扩展在另一个文件里读写这些,不能用 private(Swift 的 private 只对同一
    // 文件可见),保持 internal。
    @Environment(\.modelContext) var context
    /// 喂给 AI 的当前待办上下文;uuid 校验、撤销时按 uuid 反查也用它。
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "pending" },
           sort: \TaskItem.nextRemindAt)
    var pending: [TaskItem]
    /// 撤销要按 uuid 查已完成事项(如撤销"完成"本身)。
    @Query(filter: #Predicate<TaskItem> { $0.statusRaw == "done" },
           sort: [SortDescriptor(\TaskItem.doneAt, order: .reverse)])
    var doneTasks: [TaskItem]

    /// agent 解析出、等待用户确认的批量操作。
    @State var pendingActions: [AIAction] = []
    /// 上一批 AI 执行完的操作,供"撤销"用;见 AgentHostView+Routing.swift。
    /// 单槽、用完即清,不做多级撤销栈。原来还配了一个 lastUndoThreadUUID 核对
    /// 归属(防止在 thread A 里撤销了 thread B 后来执行的那批),单一持续对话
    /// 之后那个状态构造不出来了:撤销按钮只在最新一条可点,而执行新一批必然
    /// 追加一条"已完成执行",把旧那颗按钮挤成非最新。
    @State var lastUndo: [UndoOp]?
    /// 批量 agent 操作里有目标事项在确认期间被别处改动/删除时的提示。
    @State var actionsWarning: String?

    /// 非 nil 时把文本预填进输入框(深链/Siri 交接/小组件"+"),消费后置 nil。
    @Binding var agentRequest: String?
    /// 从展示页以 sheet 弹出时显示关闭按钮；侧栏里的常驻 AI 页面不显示。
    let showsCloseButton: Bool

    init(agentRequest: Binding<String?>, showsCloseButton: Bool = false) {
        self._agentRequest = agentRequest
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        AgentView(
            pendingPrefill: $agentRequest,
            showsCloseButton: showsCloseButton,
            submit: { text, history, onThought, onStream, onReasoning in
                try await route(text, history: history, onThought: onThought,
                                onStream: onStream, onReasoning: onReasoning)
            },
            onConfirm: { performPendingActions() },
            onUndo: { performUndo() },
            saveTask: { existing, parsed in
                if let existing {
                    TaskActions.apply(parsed, to: existing, context: context)
                } else {
                    TaskActions.create(parsed, context: context)
                }
            },
            toggleCreatedTask: { uuid, parsed in
                if let uuid, let task = pending.first(where: { $0.uuid == uuid })
                    ?? doneTasks.first(where: { $0.uuid == uuid }) {
                    // 删的步骤和 performUndo 里 .created 那支一致:先撤掉已排的
                    // 通知链,再删事项。
                    NotificationManager.shared.cancelChain(for: task.uuid)
                    context.delete(task)
                    try? context.save()
                    WidgetBridge.sync(context: context)
                    CalendarSync.sync(context: context)
                    // 这条正是 lastUndo 记着的那次新建的话,顺手清掉——不然之后
                    // 打字"撤销"会去删一个已经不在的事项,只换来一句"无法撤销"。
                    if case .created(let recorded)? = lastUndo?.first, recorded == uuid,
                       lastUndo?.count == 1 {
                        lastUndo = nil
                    }
                    return nil
                }
                let created = TaskActions.create(parsed, context: context)
                WidgetBridge.sync(context: context)
                CalendarSync.sync(context: context)
                return created.uuid
            })
        .alert("提示", isPresented: Binding(
            get: { actionsWarning != nil },
            set: { if !$0 { actionsWarning = nil } }
        )) {
            Button("好", role: .cancel) { actionsWarning = nil }
        } message: {
            Text(actionsWarning ?? "")
        }
    }
}
