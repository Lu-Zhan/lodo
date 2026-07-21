import SwiftUI
import LodoCore

/// 设置 → 管理 AI Agent:agent.md 总则 + 各 skill 的列表页。
struct AgentSkillListView: View {
    var body: some View {
        List(AgentSkillID.allCases) { id in
            NavigationLink {
                AgentSkillEditView(id: id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(id.title)
                        if AgentSkillStore.isCustomized(id) {
                            Text("已自定义")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(id.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("管理 AI Agent")
    }
}

/// 单个 skill/agent.md 的查看与编辑;保存直接改变发给 AI 的实际 prompt。
struct AgentSkillEditView: View {
    let id: AgentSkillID

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var confirmReset = false

    init(id: AgentSkillID) {
        self.id = id
        _text = State(initialValue: AgentSkillStore.content(for: id))
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .padding(.horizontal, 8)
            .navigationTitle(id.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        AgentSkillStore.save(text, for: id)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("重置", role: .destructive) {
                        confirmReset = true
                    }
                    .disabled(!AgentSkillStore.isCustomized(id))
                }
            }
            .confirmationDialog("确定恢复默认内容吗?", isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("重置", role: .destructive) {
                    AgentSkillStore.reset(id)
                    text = AgentSkillStore.defaultContent(for: id)
                }
            }
    }
}
