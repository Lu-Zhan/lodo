import SwiftUI
import SwiftData
import QuickLook
import LodoCore

/// 记忆条目详情:标题/标签可编辑,查看摘要与提取的原文,
/// 有原始文件时用 QuickLook 预览(PDF/图片/PPT 都能看)。
struct MemoryDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: MemoryItem

    @State private var tagsText: String
    @State private var previewURL: URL?
    @State private var confirmDelete = false
    /// 已删除后 onDisappear 不再回写(避免访问已删除的模型)。
    @State private var deleted = false

    init(item: MemoryItem) {
        self.item = item
        _tagsText = State(initialValue: item.tags.joined(separator: "、"))
    }

    var body: some View {
        Form {
            Section("条目") {
                TextField("标题", text: $item.title)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                TextField("标签(用、分隔)", text: $tagsText)
                if !existingTags.isEmpty {
                    // 已有标签点选添/摘;新标签直接写在上面的输入框里
                    HorizontalChipRow {
                        ForEach(existingTags, id: \.self) { tag in
                            let selected = currentTags.contains(tag)
                            Button("#\(tag)") { toggle(tag) }
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(selected ? Color.accentColor : Color.secondary)
                        }
                    }
                }
                LabeledContent("类型", value: item.kind.label)
                LabeledContent("收藏于", value: TaskItem.format(item.createdAt))
            }

            if item.status == .failed {
                Section {
                    Button("整理失败,重试") {
                        MemoryPipeline.retry(item, context: context)
                    }
                    .foregroundStyle(.red)
                } footer: {
                    Text("原文已保留,重试只重新进行 AI 整理;未配置 AI 时请先到「设置」里填写。")
                }
            }

            if let urlString = item.urlString, let url = URL(string: urlString) {
                Section("链接") {
                    Link(destination: url) {
                        Label(urlString, systemImage: "safari")
                            .lineLimit(2)
                    }
                }
            }

            if item.relativeFilePath != nil {
                Section("原文件") {
                    if let fileURL = MemoryPipeline.fileURL(of: item) {
                        Button {
                            previewURL = fileURL
                        } label: {
                            Label(item.originalFileName ?? "查看原文件",
                                  systemImage: item.kind.symbol)
                        }
                    } else {
                        Text("原文件仅保存在收藏它的设备上。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !item.sourceText.isEmpty {
                Section("原文") {
                    Text(item.sourceText)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button("删除收藏", role: .destructive) {
                    confirmDelete = true
                }
            }
        }
        .navigationTitle(item.title.isEmpty ? "记忆" : item.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .quickLookPreview($previewURL)
        .confirmationDialog("删除这条收藏?原始文件会一并删除。",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                deleted = true
                MemoryPipeline.delete(item, context: context)
                dismiss()
            }
        }
        .onDisappear { commitEdits() }
    }

    /// 全部可选标签(点选行);toggle 与输入框共用 tagsText 这一份来源。
    private var existingTags: [String] {
        MemoryTags.all(in: context)
    }

    private var currentTags: [String] {
        Self.parseTags(tagsText)
    }

    private func toggle(_ tag: String) {
        var tags = currentTags
        if tags.contains(tag) {
            tags.removeAll { $0 == tag }
        } else {
            tags.append(tag)
        }
        tagsText = tags.joined(separator: "、")
    }

    /// 标题直接双向绑定;标签从"、分隔文本"解析回数组,离开页面时一并保存。
    private func commitEdits() {
        guard !deleted else { return }
        let tags = Self.parseTags(tagsText)
        if tags != item.tags { item.tags = tags }
        try? context.save()
    }

    private static func parseTags(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "、,, "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
