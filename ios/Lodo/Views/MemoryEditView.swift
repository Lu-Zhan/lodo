import SwiftUI

/// AI 时长记忆文件的查看/编辑页(设置 → AI 记忆 → 编辑记忆)。
struct MemoryEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = DurationMemory.content ?? ""

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .padding(.horizontal, 8)
            .navigationTitle("AI 记忆")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        DurationMemory.save(text)
                        dismiss()
                    }
                }
            }
            .overlay {
                if text.isEmpty {
                    Text("暂无记忆;AI 会在事项完成后自动归纳,也可以直接在这里手写。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
    }
}
