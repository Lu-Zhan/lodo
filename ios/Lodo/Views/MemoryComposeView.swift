import SwiftUI
import SwiftData

/// 手动输入文字收藏的弹窗(记忆 tab → "+" → 输入文字)。
struct MemoryComposeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .padding(.horizontal, 8)
                .navigationTitle("输入文字")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .overlay {
                    if text.isEmpty {
                        Text("写点想收藏的内容,AI 会整理成记忆条目。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding()
                            .allowsHitTesting(false)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("收藏") {
                            MemoryPipeline.saveText(text, context: context)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
