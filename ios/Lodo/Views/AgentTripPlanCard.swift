import SwiftUI
import SwiftData
import LodoCore

/// AI 自动规划的行程卡片(`AgentMessageKind.tripPlan`)。按天列出安排,底下一颗
/// 「写入行程」;写进去之后换成"已写入行程"+「撤销」,并在卡片下面挂一条
/// `AgentJumpLink` 小条(「旅行已更新:xx ›」)直接进到那次旅行里。
///
/// 写入/撤销由卡片自己做(拿 modelContext 调 `TravelStore`),再把新状态写回
/// `tripPlanSnapshotData`——不像其他卡片那样把回调一路串过 AgentView:这张卡
/// 的动作不依赖对话上下文(不涉及 pendingActions/lastUndo),改写快照本身就是
/// 让气泡刷新的触发点(@Query 盯的是消息)。
struct AgentTripPlanCard: View {
    let message: AgentMessage
    let isLatest: Bool

    @Environment(\.modelContext) private var context
    @State private var expanded = false

    private var plan: TripPlanProposal? {
        guard let data = message.tripPlanSnapshotData else { return nil }
        return try? JSONDecoder().decode(TripPlanProposal.self, from: data)
    }

    /// 收起时只露第一天,规划动辄十几条,整张铺开会把对话顶出好几屏。
    private static let collapsedDayCount = 1

    var body: some View {
        if let plan {
            // 跳转小条在卡片**外面**:它没有卡片底色,层级上比卡片轻一档。
            VStack(alignment: .leading, spacing: 2) {
                card(plan)
                if plan.isApplied, let trip = plan.appliedTripUUID {
                    AgentJumpLink(text: Text("旅行已更新:\(plan.tripTitle)"),
                                  destination: .trip(trip))
                }
            }
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
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !plan.summary.isEmpty {
                    Text(plan.summary)
                        .font(.body)
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
                .font(.subheadline)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(entries) { TripPlanEntryRow(entry: $0) }
        }
    }

    @ViewBuilder
    private func actions(_ plan: TripPlanProposal) -> some View {
        if plan.isApplied {
            HStack(spacing: 8) {
                // 旅行名不在这里重复:卡片标题就是它,下面那条跳转小条也带着它。
                Label("已写入行程", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
                Spacer(minLength: 8)
                Button {
                    TripPlanApplier.revert(plan, on: message, context: context)
                    Haptics.tick()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            }
        } else if plan.appliedTripUUID != nil {
            // 写入过又撤销了:和新建待办结果卡片那颗开关一样,不限最新一条。
            HStack(spacing: 8) {
                Label("已撤销写入", systemImage: "xmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("重新写入") { apply(plan) }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
            }
        } else if isLatest {
            // 还没写入的规划不给跳转小条:库里还没有这次旅行,没有可进的条目
            // (整份规划就在这张卡上,「展开其余 N 项」看得到全部)。
            Button { apply(plan) } label: {
                Label("写入行程", systemImage: "suitcase.rolling")
            }
            .glassProminentButton()
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let start = entry.start, entry.kind != .lodging {
                        Text(start, format: .dateTime.hour().minute())
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.title)
                        .font(.body)
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
