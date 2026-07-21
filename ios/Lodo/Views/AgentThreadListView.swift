import SwiftUI
import SwiftData
import LodoCore

/// 左上角按钮弹出的 thread 选择器;"新建对话"永远置顶。
struct AgentThreadListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\AgentThread.updatedAt, order: .reverse)])
    private var threads: [AgentThread]

    @Binding var currentThreadUUID: UUID?
    /// 选中/新建一个 thread 后调用,外层用来关掉 popover。
    let onSelect: () -> Void

    var body: some View {
        List {
            Button {
                let thread = AgentThread()
                context.insert(thread)
                try? context.save()
                currentThreadUUID = thread.uuid
                onSelect()
            } label: {
                Label("新建对话", systemImage: "plus.bubble")
            }
            ForEach(threads) { thread in
                Button {
                    currentThreadUUID = thread.uuid
                    onSelect()
                } label: {
                    HStack {
                        Text(thread.title.isEmpty ? "新对话" : thread.title)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(thread.updatedAt, format: .relative(presentation: .named))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(thread)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .frame(width: 280, height: 360)
    }

    /// 连带删掉这个 thread 下的全部消息,避免孤儿数据。
    private func delete(_ thread: AgentThread) {
        let uuid = thread.uuid
        let messages = (try? context.fetch(FetchDescriptor<AgentMessage>(
            predicate: #Predicate { $0.threadUUID == uuid }))) ?? []
        for message in messages { context.delete(message) }
        if currentThreadUUID == uuid { currentThreadUUID = nil }
        context.delete(thread)
        try? context.save()
    }
}
