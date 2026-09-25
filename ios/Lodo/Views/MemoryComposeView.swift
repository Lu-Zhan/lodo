import SwiftUI
import SwiftData

/// 手动输入文字收藏的备用表单。当前没有入口：文字收藏统一说给底部的
/// 「问问 AI」(`memorize`)，或从其他 app 分享进来；`presetTags` 可在将来
/// 恢复独立入口时为健康记录等场景预设标签。
struct MemoryComposeView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// AI 整理之后保底带上的标签(健康页的"记一笔"传「健康」进来;
    /// 记忆页的通用入口不传,行为不变)。
    var presetTags: [String] = []
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
                            .font(.subheadline)
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
                            MemoryPipeline.saveText(text, context: context, extraTags: presetTags)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}
