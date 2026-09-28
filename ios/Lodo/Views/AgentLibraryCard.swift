import SwiftUI
import SwiftData
import LodoCore

/// AI 新增/修改资产、订阅新闻源(`AgentMessageKind.libraryEdit`)的结果卡片:每项一行,
/// 右下角「撤销」,卡片下面挂跳到资产页/新闻页的小条。写法同 `AgentCountdownCard`:
/// 改动在 route() 里已经落库,撤销由卡片自己调 `LibraryStore.revert` 并改写
/// `librarySnapshotData`,不限最新一条。
struct AgentLibraryCard: View {
    let message: AgentMessage

    @Environment(\.modelContext) private var context

    private var record: LibraryEditRecord? {
        guard let data = message.librarySnapshotData else { return nil }
        return try? JSONDecoder().decode(LibraryEditRecord.self, from: data)
    }

    var body: some View {
        if let record {
            VStack(alignment: .leading, spacing: 2) {
                card(record)
                if record.reverted != true {
                    if record.lines.contains(where: { $0.domain == .asset }) {
                        AgentJumpLink(text: Text("资产已更新"), destination: .assets)
                    }
                    if record.lines.contains(where: { $0.domain == .feed }) {
                        AgentJumpLink(text: Text("订阅已更新"), destination: .news)
                    }
                }
            }
        } else {
            Text(message.content)
        }
    }

    private func card(_ record: LibraryEditRecord) -> some View {
        let reverted = record.reverted == true
        return AgentResultReply(status: Text(reverted ? "已撤销" : headline(record))) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(record.lines.enumerated()), id: \.offset) { _, line in
                    row(line)
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

            if !reverted, record.hasChanges {
                HStack {
                    Spacer(minLength: 8)
                    Button {
                        let reverted = LibraryStore.revert(record, context: context)
                        message.librarySnapshotData = try? JSONEncoder().encode(reverted)
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

    /// 只有新增时说"已添加",只有修改时说"已修改",混着来统称"已更新"。
    private func headline(_ record: LibraryEditRecord) -> LocalizedStringKey {
        if record.lines.isEmpty { return "没有改动" }
        if record.lines.allSatisfy(\.created) {
            return record.lines.allSatisfy { $0.domain == .feed } ? "已订阅" : "已添加"
        }
        if record.lines.allSatisfy({ !$0.created }) { return "已修改" }
        return "已更新"
    }

    private func row(_ line: LibraryEditRecord.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: line.domain == .asset ? "banknote" : "dot.radiowaves.up.forward")
                .foregroundStyle(.tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if !line.detail.isEmpty {
                    Text(line.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: line.created ? "plus.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(line.created ? LodoColor.positive : .orange)
        }
    }
}
