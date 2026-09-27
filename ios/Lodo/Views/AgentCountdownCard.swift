import SwiftUI
import SwiftData
import LodoCore

/// AI 新建/修改/删除倒数日(`AgentMessageKind.countdownEdit`)的结果卡片:每件一行,
/// 写明日子和"还有几天";右下角「撤销」,卡片下面挂一条跳到倒数日页的小条。
///
/// 改动在 route() 里已经落库,这张卡是事后反悔的入口。撤销由卡片自己调
/// `CountdownStore.revert` 并改写 `countdownSnapshotData`,不限最新一条
/// (同 AgentTripEditCard)。
struct AgentCountdownCard: View {
    let message: AgentMessage

    @Environment(\.modelContext) private var context

    private var record: CountdownEditRecord? {
        guard let data = message.countdownSnapshotData else { return nil }
        return try? JSONDecoder().decode(CountdownEditRecord.self, from: data)
    }

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 4) {
                card(record)
                if record.reverted != true, !record.created.isEmpty || !record.updatedAfter.isEmpty {
                    AgentJumpLink(text: Text("倒数日已更新"), destination: .countdown)
                        .padding(.horizontal, 10)
                }
            }
        } else {
            Text(message.content)
        }
    }

    private func card(_ record: CountdownEditRecord) -> some View {
        let reverted = record.reverted == true
        return AgentResultReply(status: Text(reverted ? "已撤销" : headline(record))) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(record.created, id: \.uuid) { event in
                    row(event, symbol: "plus.circle.fill", tint: LodoColor.positive)
                }
                ForEach(record.updatedAfter, id: \.uuid) { event in
                    row(event, symbol: "arrow.triangle.2.circlepath.circle.fill", tint: .orange)
                }
                ForEach(record.deleted, id: \.uuid) { event in
                    row(event, symbol: "minus.circle.fill", tint: LodoColor.critical, struck: true)
                }
            }
            .opacity(reverted ? 0.5 : 1)

            if !record.skipped.isEmpty {
                Label {
                    Text(record.skipped.joined(separator: ";"))
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            if !reverted {
                HStack {
                    Spacer(minLength: 8)
                    Button {
                        let reverted = CountdownStore.revert(record, context: context)
                        message.countdownSnapshotData = try? JSONEncoder().encode(reverted)
                        message.content = reverted.transcript
                        try? context.save()
                        Haptics.tick()
                    } label: {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .font(.subheadline)
                }
            }
        }
    }

    /// 只有一种改动时说具体的("已新建"),混着来时统称"已更新"。
    private func headline(_ record: CountdownEditRecord) -> LocalizedStringKey {
        let kinds = [!record.created.isEmpty, !record.updatedAfter.isEmpty, !record.deleted.isEmpty]
            .filter { $0 }.count
        if kinds > 1 { return "已更新" }
        if !record.created.isEmpty { return "已新建" }
        if !record.updatedAfter.isEmpty { return "已修改" }
        return "已删除"
    }

    private func row(_ snapshot: BackupCountdownEvent, symbol: String, tint: Color,
                     struck: Bool = false) -> some View {
        let entry = CountdownEntry(id: snapshot.uuid, title: snapshot.title,
                                   start: snapshot.startDate, end: snapshot.endDate,
                                   allDay: snapshot.allDay)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title)
                    .font(.body.weight(.medium))
                    .strikethrough(struck)
                    .foregroundStyle(struck ? .secondary : .primary)
                Text(dateLine(snapshot))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !snapshot.startReminders.isEmpty || !snapshot.endReminders.isEmpty {
                    Label(CountdownText.offsetsSummary(snapshot.startReminders
                                                       + snapshot.endReminders),
                          systemImage: "bell")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !struck {
                Text(CountdownText.text(CountdownPlan.primary(entry, now: .now),
                                        hasEnd: snapshot.endDate != nil))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.tint)
            }
        }
    }

    private func dateLine(_ snapshot: BackupCountdownEvent) -> String {
        let start = CountdownText.dateText(snapshot.startDate, allDay: snapshot.allDay)
        guard let end = snapshot.endDate else { return start }
        return start + " – " + CountdownText.dateText(end, allDay: snapshot.allDay)
    }
}
