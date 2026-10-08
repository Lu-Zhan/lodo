import SwiftUI
import SwiftData
import LodoCore

/// AI 回复下面那张"待确认"卡片:规划 / 行程调整 / 任务 / 倒数日,各自一颗写入按钮,
/// 谁点就写进谁的 lodo,写入后可以撤销。
///
/// 写入状态有两层:
/// - **我写过没有**:`ChatProposalApplication`(主库,经私有库同步到自己的其他设备)——
///   iPhone 上写过的,iPad 上同一张卡也显示「已写入」,不会再写一遍;撤销信息也存在这里。
/// - **别人写过没有**(只对规划/行程调整有意义,会影响共享旅行):写入/撤销时往房间发一条
///   带 `ChatProposalRef` 的系统提示,其他成员的卡片据此显示「已由 X 写入」。
struct ChatProposalView: View {
    let message: ChatRoomMessage
    let proposal: ChatProposal
    let state: ChatTimelineState

    @Environment(\.modelContext) private var context
    @Environment(\.itemNavigator) private var navigator
    @Query private var applications: [ChatProposalApplication]
    @State private var note: String?

    init(message: ChatRoomMessage, proposal: ChatProposal, state: ChatTimelineState) {
        self.message = message
        self.proposal = proposal
        self.state = state
        let id = message.uuid
        _applications = Query(filter: #Predicate<ChatProposalApplication> { $0.messageUUID == id })
    }

    private enum Part: String { case plan, edit, tasks, countdowns }

    /// 这个账号对某一部分的写入记录(没撤销的那条)。
    private func mine(_ part: Part) -> ChatProposalApplication? {
        applications.last { $0.part == part.rawValue && !$0.reverted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plan = proposal.tripPlan { planSection(plan) }
            if let edit = proposal.tripEdit { editSection(edit) }
            if !proposal.tasks.isEmpty { tasksSection }
            if !proposal.countdowns.isEmpty { countdownSection }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.fill.tertiary,
                    in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
    }

    // MARK: 规划

    private func planSection(_ plan: TripPlanProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("行程规划「\(plan.tripTitle)」")
            } icon: {
                Image(systemName: "map")
            }
            .font(.subheadline.weight(.semibold))
            Text(plan.startDate.formatted(Self.dayFormat) + " – " + plan.endDate.formatted(Self.dayFormat)
                 + " · " + String(localized: "\(plan.items.count) 项安排", bundle: .appLanguage()))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(plan.items.prefix(4).map(\.title).joined(separator: "、") + (plan.items.count > 4 ? "…" : ""))
                .font(.footnote)
                .lineLimit(2)
            sharedStatus(.plan, tripTitle: plan.tripTitle,
                         applyTitle: "写入行程", applyAgainTitle: "也写入我的行程") { applyPlan(plan) }
        }
    }

    private func applyPlan(_ plan: TripPlanProposal) {
        let applied = TravelStore.applyPlan(plan, context: context)
        context.insert(ChatProposalApplication(messageUUID: message.uuid, part: Part.plan.rawValue,
                                               undo: .plan(applied)))
        try? context.save()
        announce(.plan, .applied) { who in
            String(localized: "\(who)把行程写进了旅行「\(applied.tripTitle)」", bundle: .appLanguage())
        }
    }

    // MARK: 调整

    private func editSection(_ edit: TripEdit) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("调整旅行「\(edit.tripTitle)」")
            } icon: {
                Image(systemName: "slider.horizontal.3")
            }
            .font(.subheadline.weight(.semibold))
            Text(String(localized: "删 \(edit.removeIDs.count) 项 · 加 \(edit.additions.count) 项 · 改 \(edit.updates.count) 项",
                        bundle: .appLanguage()))
                .font(.footnote)
                .foregroundStyle(.secondary)
            sharedStatus(.edit, tripTitle: edit.tripTitle,
                         applyTitle: "调整行程", applyAgainTitle: nil) { applyEdit(edit) }
        }
    }

    private func applyEdit(_ edit: TripEdit) {
        guard let record = TravelStore.applyEdit(edit, context: context) else {
            note = String(localized: "这台设备上没有这趟旅行,先加入它的共享再调整。", bundle: .appLanguage())
            return
        }
        guard record.hasChanges else {
            note = String(localized: "没有可以改的行程项(航班和带附件的不改)。", bundle: .appLanguage())
            return
        }
        context.insert(ChatProposalApplication(messageUUID: message.uuid, part: Part.edit.rawValue,
                                               undo: .edit(record)))
        try? context.save()
        announce(.edit, .applied) { who in
            String(localized: "\(who)调整了旅行「\(record.tripTitle)」", bundle: .appLanguage())
        }
    }

    /// 规划 / 调整的状态行。我写过 → 已写入 · 打开 · 撤销;别人写过 → 已由 X 写入
    /// (这台设备上有那趟旅行就给「打开」,没有就给「也写入我的行程」);都没有 → 写入按钮。
    @ViewBuilder
    private func sharedStatus(_ part: Part, tripTitle: String, applyTitle: LocalizedStringKey,
                              applyAgainTitle: LocalizedStringKey?, apply: @escaping () -> Void) -> some View {
        let trip = existingTrip(named: tripTitle)
        if let application = mine(part) {
            HStack(spacing: 8) {
                appliedLabel(String(localized: "已写入", bundle: .appLanguage()))
                if let trip, let navigator {
                    smallButton("打开") { navigator.open(.trip(trip)) }
                }
                smallButton("撤销") { revert(application, part: part) }
            }
        } else if let latest = state.latestRef(message.uuid, part: part.rawValue), latest.action == .applied,
                  !latest.fromMe {
            HStack(spacing: 8) {
                appliedLabel(String(localized: "已由\(latest.by)写入", bundle: .appLanguage()))
                if let trip, let navigator {
                    smallButton("打开") { navigator.open(.trip(trip)) }
                } else if let applyAgainTitle {
                    smallButton(applyAgainTitle, action: apply)
                }
            }
        } else {
            Button(applyTitle, action: apply)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    // MARK: 任务 / 倒数日

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("任务", systemImage: "checklist")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(proposal.tasks.enumerated()), id: \.offset) { _, task in
                Text("· " + task.title + "  " + LocalizedContent.taskCaption(task))
                    .font(.footnote)
                    .lineLimit(1)
            }
            personalStatus(.tasks, applyTitle: "加到我的任务") {
                let created = proposal.tasks.map { TaskActions.create($0, context: context).uuid }
                WidgetBridge.sync(context: context)
                CalendarSync.sync(context: context)
                record(.tasks, undo: .tasks(created))
            }
        }
    }

    private var countdownSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("倒数日", systemImage: "hourglass")
                .font(.subheadline.weight(.semibold))
            ForEach(Array(proposal.countdowns.enumerated()), id: \.offset) { _, draft in
                Text("· " + draft.title + "  " + draft.start.formatted(Self.dayFormat))
                    .font(.footnote)
                    .lineLimit(1)
            }
            personalStatus(.countdowns, applyTitle: "加到我的倒数日") {
                let result = CountdownStore.apply(proposal.countdowns.map { CountdownOp.create($0) },
                                                  context: context)
                record(.countdowns, undo: .countdowns(result))
            }
        }
    }

    /// 任务、倒数日只进自己的 lodo,不在房间里留言。
    @ViewBuilder
    private func personalStatus(_ part: Part, applyTitle: LocalizedStringKey,
                                apply: @escaping () -> Void) -> some View {
        if let application = mine(part) {
            HStack(spacing: 8) {
                appliedLabel(String(localized: "已加入", bundle: .appLanguage()))
                if part == .countdowns, let navigator {
                    smallButton("打开") { navigator.open(.countdown) }
                }
                smallButton("撤销") { revert(application, part: part) }
            }
        } else {
            Button(applyTitle, action: apply)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private func record(_ part: Part, undo: ChatProposalUndo) {
        context.insert(ChatProposalApplication(messageUUID: message.uuid, part: part.rawValue, undo: undo))
        try? context.save()
    }

    // MARK: 撤销

    private func revert(_ application: ChatProposalApplication, part: Part) {
        switch application.undo {
        case .plan(let applied):
            _ = TravelStore.revertPlan(applied, context: context)
            announce(part, .reverted) { who in
                String(localized: "\(who)撤销了写进旅行「\(applied.tripTitle)」的行程", bundle: .appLanguage())
            }
        case .edit(let record):
            _ = TravelStore.revertEdit(record, context: context)
            announce(part, .reverted) { who in
                String(localized: "\(who)撤销了对旅行「\(record.tripTitle)」的调整", bundle: .appLanguage())
            }
        case .tasks(let uuids):
            for uuid in uuids {
                if let task = try? context.fetch(FetchDescriptor<TaskItem>(
                    predicate: #Predicate { $0.uuid == uuid })).first {
                    NotificationManager.shared.cancelChain(for: task.uuid)
                    context.delete(task)
                }
            }
            WidgetBridge.sync(context: context)
            CalendarSync.sync(context: context)
        case .countdowns(let record):
            _ = CountdownStore.revert(record, context: context)
        case nil:
            break
        }
        application.reverted = true
        try? context.save()
    }

    // MARK: 共用

    /// 日期按应用内语言出(`.formatted` 默认跟系统语言)。
    private static var dayFormat: Date.FormatStyle {
        Date.FormatStyle.dateTime.month().day().locale(AppSettings.language.locale)
    }

    private func appliedLabel(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(LodoColor.positive)
    }

    private func smallButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.footnote)
            .controlSize(.small)
            .buttonStyle(.bordered)
    }

    private func existingTrip(named title: String) -> UUID? {
        TravelStore.trips(in: context).first {
            $0.title.trimmingCharacters(in: .whitespaces).lowercased()
                == title.trimmingCharacters(in: .whitespaces).lowercased()
        }?.uuid
    }

    /// 写进/撤销行程这类会影响别人的,在房间里留一句带引用的话。
    private func announce(_ part: Part, _ action: ChatProposalRef.Action, _ sentence: (String) -> String) {
        let id = message.roomUUID
        guard let room = try? context.fetch(FetchDescriptor<ChatRoom>(
            predicate: #Predicate { $0.uuid == id })).first else { return }
        let me = SharedTripSync.myDisplayName
        let who = me.isEmpty ? String(localized: "一位成员", bundle: .appLanguage()) : me
        SharedTripSync.shared.sendSystem(
            sentence(who), ref: ChatProposalRef(messageID: message.uuid, part: part.rawValue, action: action),
            in: room)
    }
}
