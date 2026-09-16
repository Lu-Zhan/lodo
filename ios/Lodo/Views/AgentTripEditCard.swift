import SwiftUI
import SwiftData
import LodoCore

/// AI 调整已记下行程(`AgentMessageKind.tripEdit`)的结果卡片:列出删了/加了/改了
/// 哪几项,没动的(航班、带附件的)如实写出来;右下角「查看」「撤销」。
///
/// 改动在 route() 里已经落库,这张卡是事后反悔的入口。撤销由卡片自己调
/// `TravelStore.revertEdit` 并改写 `tripEditSnapshotData`(同 AgentTripPlanCard),
/// 不限最新一条——它动的就是记录里那几项,不依赖当前上下文。
struct AgentTripEditCard: View {
    let message: AgentMessage

    @Environment(\.modelContext) private var context
    @Environment(\.sidebarChrome) private var sidebarChrome

    private var record: TripEditRecord? {
        guard let data = message.tripEditSnapshotData else { return nil }
        return try? JSONDecoder().decode(TripEditRecord.self, from: data)
    }

    var body: some View {
        if let record {
            card(record)
        } else {
            Text(message.content)
        }
    }

    private func card(_ record: TripEditRecord) -> some View {
        let reverted = record.reverted == true
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("已调整「\(record.tripTitle)」")
                } icon: {
                    Image(systemName: "calendar.badge.clock")
                }
                .font(.headline)
                if !record.summary.isEmpty {
                    Text(record.summary)
                        .font(.subheadline)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(record.removed, id: \.uuid) { item in
                    row(symbol: "minus.circle.fill", tint: .red, title: item.title,
                        start: item.travelStart, struck: true)
                }
                ForEach(record.added, id: \.id) { line in
                    row(symbol: "plus.circle.fill", tint: .green, title: line.title, start: line.start)
                }
                ForEach(record.updatedAfter, id: \.id) { line in
                    row(symbol: "arrow.triangle.2.circlepath.circle.fill", tint: .orange,
                        title: line.title, start: line.start)
                }
            }
            .opacity(reverted ? 0.5 : 1)

            if !record.skipped.isEmpty {
                Label {
                    Text("没有改动:\(record.skipped.joined(separator: "、"))")
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if reverted {
                    Label("已撤销这次调整", systemImage: "arrow.uturn.backward.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let chrome = sidebarChrome, !reverted {
                    Button("查看") { chrome.go(.travel) }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                }
                if !reverted {
                    Button {
                        let reverted = TravelStore.revertEdit(record, context: context)
                        message.tripEditSnapshotData = try? JSONEncoder().encode(reverted)
                        message.content = reverted.transcript
                        try? context.save()
                        Haptics.tick()
                    } label: {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary,
                    in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
    }

    private func row(symbol: String, tint: Color, title: String, start: Date?,
                     struck: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .strikethrough(struck)
                    .foregroundStyle(struck ? .secondary : .primary)
                if let start {
                    Text(start, format: .dateTime.month().day().weekday().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
