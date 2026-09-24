import SwiftUI
import SwiftData
import LodoCore

/// AI 自动规划的行程卡片(`AgentMessageKind.tripPlan`)。按天列出安排,底下一颗
/// 「写入行程」;写进去之后换成"已写入「xx」"+「查看」「撤销」。
///
/// 写入/撤销由卡片自己做(拿 modelContext 调 `TravelStore`),再把新状态写回
/// `tripPlanSnapshotData`——不像其他卡片那样把回调一路串过 AgentView:这张卡
/// 的动作不依赖对话上下文(不涉及 pendingActions/lastUndo),改写快照本身就是
/// 让气泡刷新的触发点(@Query 盯的是消息)。
struct AgentTripPlanCard: View {
    let message: AgentMessage
    let isLatest: Bool

    @Environment(\.modelContext) private var context
    @Environment(\.sidebarChrome) private var sidebarChrome
    @Environment(\.agentInspector) private var inspector
    @State private var expanded = false

    private var plan: TripPlanProposal? {
        guard let data = message.tripPlanSnapshotData else { return nil }
        return try? JSONDecoder().decode(TripPlanProposal.self, from: data)
    }

    /// 收起时只露第一天,规划动辄十几条,整张铺开会把对话顶出好几屏。
    private static let collapsedDayCount = 1

    var body: some View {
        if let plan {
            card(plan)
        } else {
            Text(message.content)
        }
    }

    private func card(_ plan: TripPlanProposal) -> some View {
        let days = TravelPlan.group(plan.entries, into: plan.days()).filter { !$0.entries.isEmpty }
        let extras = TravelPlan.outOfRange(plan.entries, days: plan.days())
            + TravelPlan.unscheduled(plan.entries)
        let visibleDays = expanded ? days : Array(days.prefix(Self.collapsedDayCount))
        let hiddenCount = days.dropFirst(Self.collapsedDayCount).reduce(0) { $0 + $1.entries.count }
            + extras.count

        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(plan.tripTitle, systemImage: "map")
                    .font(.headline)
                Text("\(TripPlanFormat.dateRange(plan)) · \(plan.days().count) 天 · \(plan.items.count) 项安排")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !plan.summary.isEmpty {
                    Text(plan.summary)
                        .font(.subheadline)
                        .padding(.top, 2)
                }
            }

            ForEach(Array(visibleDays.enumerated()), id: \.element.id) { _, day in
                dayBlock(title: TripPlanFormat.dayTitle(day.date, in: plan), entries: day.entries)
            }
            if expanded, !extras.isEmpty {
                dayBlock(title: Text("其他安排"), entries: extras)
            }
            if hiddenCount > 0 || expanded {
                Button {
                    withAnimation(.lodoAware(.snappy)) { expanded.toggle() }
                } label: {
                    if expanded {
                        Label("收起", systemImage: "chevron.up")
                    } else {
                        Label("展开其余 \(hiddenCount) 项", systemImage: "chevron.down")
                    }
                }
                .font(.footnote)
                .buttonStyle(.borderless)
            }

            actions(plan)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary,
                    in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
    }

    private func dayBlock(title: Text, entries: [TravelEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entries) { TripPlanEntryRow(entry: $0) }
        }
    }

    @ViewBuilder
    private func actions(_ plan: TripPlanProposal) -> some View {
        if plan.isApplied {
            HStack(spacing: 8) {
                Label("已写入「\(plan.tripTitle)」", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 8)
                viewButton
                Button {
                    TripPlanApplier.revert(plan, on: message, context: context)
                    Haptics.tick()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .font(.footnote)
            }
        } else if plan.appliedTripUUID != nil {
            // 写入过又撤销了:和新建待办结果卡片那颗开关一样,不限最新一条。
            HStack(spacing: 8) {
                Label("已撤销写入", systemImage: "xmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("重新写入") { apply(plan) }
                    .buttonStyle(.bordered)
                    .font(.footnote)
            }
        } else if isLatest {
            HStack(spacing: 8) {
                Button { apply(plan) } label: {
                    Label("写入行程", systemImage: "suitcase.rolling")
                }
                .glassProminentButton()
                Spacer(minLength: 8)
                // 还没写入时「查看」打开的是右栏里的完整预览(卡片只展开第一天);
                // 不在 AI 页(没有右栏)时没有可去的地方,不给这颗。
                if inspector != nil { viewButton }
            }
        }
    }

    /// 在 AI 页打开右栏并定位到这张卡;没有右栏时回退成切到旅行页。
    @ViewBuilder
    private var viewButton: some View {
        if let inspector, let target = AgentInspectorTarget.from(message) {
            Button("查看") { inspector.show(target) }
                .buttonStyle(.bordered)
                .font(.footnote)
        } else if let chrome = sidebarChrome {
            Button("查看") { chrome.go(.travel) }
                .buttonStyle(.bordered)
                .font(.footnote)
        }
    }

    private func apply(_ plan: TripPlanProposal) {
        TripPlanApplier.apply(plan, to: message, context: context)
    }
}

/// 规划写入/撤销。卡片和右栏预览共用这一份:写回 `tripPlanSnapshotData` 是让气泡
/// (和右栏)刷新的唯一触发点,两处各写一遍迟早会写岔。
@MainActor
enum TripPlanApplier {
    @discardableResult
    static func apply(_ plan: TripPlanProposal, to message: AgentMessage,
                      context: ModelContext) -> TripPlanProposal {
        let applied = TravelStore.applyPlan(plan, context: context)
        save(applied, to: message, context: context)
        Haptics.success()
        return applied
    }

    static func revert(_ plan: TripPlanProposal, on message: AgentMessage, context: ModelContext) {
        save(TravelStore.revertPlan(plan, context: context), to: message, context: context)
    }

    private static func save(_ plan: TripPlanProposal, to message: AgentMessage,
                             context: ModelContext) {
        message.tripPlanSnapshotData = try? JSONEncoder().encode(plan)
        try? context.save()
    }
}

enum TripPlanFormat {
    static func dateRange(_ plan: TripPlanProposal) -> String {
        let start = plan.startDate.formatted(.dateTime.month().day())
        let end = plan.endDate.formatted(.dateTime.month().day())
        return start == end ? start : "\(start) – \(end)"
    }

    static func dayTitle(_ date: Date, in plan: TripPlanProposal) -> Text {
        let index = (plan.days().firstIndex(of: date) ?? 0) + 1
        return Text("第 \(index) 天 · \(date.formatted(.dateTime.month().day().weekday()))")
    }
}

/// 规划里的一行安排(卡片和右栏预览共用)。
struct TripPlanEntryRow: View {
    let entry: TravelEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.kind.systemImage)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let start = entry.start, entry.kind != .lodging {
                        Text(start, format: .dateTime.hour().minute())
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.title)
                        .font(.subheadline)
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
