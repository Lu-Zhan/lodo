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

    /// 我(这个账号)在**别的设备**上写过了,但那台的写入记录还没经私有库同步过来:
    /// 房间里的写入提示 / 标记是走聊天室同步的,比私有库快,先拿它挡住重复写入。
    /// 两台设备几秒内同时点仍可能各写一次——跨设备做不到真正的原子互斥。
    private func appliedElsewhere(_ part: Part) -> Bool {
        guard mine(part) == nil, let latest = state.latestRef(message.uuid, part: part.rawValue) else { return false }
        return latest.fromMe && latest.action == .applied
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
        guard !appliedElsewhere(.plan) else { return }
        // 写进房间里讨论的那趟(按 id,不按名字——本机可能另有同名的私人旅行);
        // 房间里没分享过旅行时才按名字写进已有的同名旅行或新建。
        let applied = TravelStore.applyPlan(plan, into: roomTarget(for: plan.tripTitle)?.uuid, context: context)
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
        guard !appliedElsewhere(.edit) else { return }
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
        let trip = roomTarget(for: tripTitle)?.uuid ?? existingTrip(named: tripTitle)
        if mine(part) != nil || appliedElsewhere(part) {
            let application = mine(part)
            HStack(spacing: 8) {
                appliedLabel(String(localized: "已写入", bundle: .appLanguage()))
                if let trip, let navigator {
                    smallButton("打开") { navigator.open(.trip(trip)) }
                }
                // 撤销要用写入时记下的那份记录;在别的设备上写的,到那台上撤销。
                if let application {
                    smallButton("撤销") { revert(application, part: part) }
                }
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
        if mine(part) != nil || appliedElsewhere(part) {
            HStack(spacing: 8) {
                appliedLabel(String(localized: "已加入", bundle: .appLanguage()))
                if part == .countdowns, let navigator {
                    smallButton("打开") { navigator.open(.countdown) }
                }
                if let application = mine(part) {
                    smallButton("撤销") { revert(application, part: part) }
                }
            }
        } else {
            Button(applyTitle) {
                guard !appliedElsewhere(part) else { return }
                apply()
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    /// 任务、倒数日只进自己的 lodo:记一条写入记录,再往房间里发一个**不显示的**标记,
    /// 自己的其他设备马上就知道写过了(私有库同步要慢得多)。
    private func record(_ part: Part, undo: ChatProposalUndo) {
        context.insert(ChatProposalApplication(messageUUID: message.uuid, part: part.rawValue, undo: undo))
        try? context.save()
        if let room = currentRoom() {
            SharedTripSync.shared.sendMarker(
                ChatProposalRef(messageID: message.uuid, part: part.rawValue, action: .applied), in: room)
        }
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
        if part == .tasks || part == .countdowns, let room = currentRoom() {
            SharedTripSync.shared.sendMarker(
                ChatProposalRef(messageID: message.uuid, part: part.rawValue, action: .reverted), in: room)
        }
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

    private func currentRoom() -> ChatRoom? {
        let id = message.roomUUID
        return try? context.fetch(FetchDescriptor<ChatRoom>(predicate: #Predicate { $0.uuid == id })).first
    }

    /// 这张卡要写进的、房间里分享过的旅行:房间里**全部**旅行卡片(不只是当前加载的那一页)
    /// 指向的、这台设备上也有的那几趟里,名字对得上的那趟;对不上而只有一趟时就是它。
    private func roomTarget(for title: String) -> TravelTrip? {
        let roomUUID = message.roomUUID
        let cards = (try? context.fetch(FetchDescriptor<ChatRoomMessage>(
            predicate: #Predicate { $0.roomUUID == roomUUID && $0.kindRaw == "card" }))) ?? []
        let ids = ChatRoomAI.roomTripIDs(in: cards)
        let trips = TravelStore.trips(in: context).filter { ids.contains($0.uuid) }
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trips.first { $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                                .caseInsensitiveCompare(wanted) == .orderedSame }
            ?? (trips.count == 1 ? trips.first : nil)
    }

    /// 写进/撤销行程这类会影响别人的,在房间里留一句带引用的话。
    private func announce(_ part: Part, _ action: ChatProposalRef.Action, _ sentence: (String) -> String) {
        guard let room = currentRoom() else { return }
        let me = SharedTripSync.myDisplayName
        let who = me.isEmpty ? String(localized: "一位成员", bundle: .appLanguage()) : me
        SharedTripSync.shared.sendSystem(
            sentence(who), ref: ChatProposalRef(messageID: message.uuid, part: part.rawValue, action: action),
            in: room)
    }
}
