import SwiftUI
import LodoCore

/// AI 用户偏好文件的查看/编辑页(设置 → AI 偏好 → 编辑偏好)。
/// 和时长记忆那页(MemoryEditView)同一套写法,只是换了一份文件。
struct AgentPreferencesEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = AgentPreferences.content ?? ""

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .padding(.horizontal, 8)
            .navigationTitle("AI 偏好")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        AgentPreferences.save(text)
                        dismiss()
                    }
                }
            }
            .overlay {
                if text.isEmpty {
                    Text("暂无偏好;说一句「以后开会都留一小时」这样的长期要求,AI 会自动记在这里,也可以直接手写。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
    }
}
