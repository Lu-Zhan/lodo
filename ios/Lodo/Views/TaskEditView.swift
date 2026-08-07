import SwiftUI
import LodoCore

/// 创建/编辑共用表单;编辑模式下支持 AI 自然语言指令修改。
struct TaskEditView: View {
    let existing: TaskItem?
    /// 非 nil 时来自记忆条目"转为待办"(新建)或该事项本身已带附件(编辑),只读展示。
    let attachment: TaskAttachment?
    var onSave: (ParsedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var form: TaskFormModel

    @State private var aiInstruction = ""
    @State private var aiBusy = false
    @State private var errorText: String?

    init(existing: TaskItem?, parsed: ParsedTask?, attachment: TaskAttachment? = nil,
         onSave: @escaping (ParsedTask) -> Void) {
        self.existing = existing
        self.attachment = attachment
        self.onSave = onSave
        let source: ParsedTask? = parsed ?? existing.map { ParsedTask(from: $0) }
        _form = State(initialValue: TaskFormModel(from: source))
    }

    var body: some View {
        NavigationStack {
            Form {
                TaskFormSections(form: $form, existingProjects: TaskProjects.all(in: context))

                if let attachment {
                    attachmentSection(attachment)
                }

                if existing != nil {
                    Section("AI 修改") {
                        TextField("例如:改到明天晚上8点", text: $aiInstruction)
                            .onSubmit { applyAI() }
                        Button {
                            applyAI()
                        } label: {
                            if aiBusy {
                                ProgressView().controlSize(.small)
                                    .accessibilityLabel("处理中")
                            } else {
                                Label("应用修改", systemImage: "sparkles")
                            }
                        }
                        .disabled(aiBusy ||
                                  aiInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "新建事项" : "编辑事项")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("保存") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!form.isValid)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    /// 记忆条目携带过来的内容快照,只读展示(标题字段仍在上面的表单区块里,
    /// 可正常编辑;这里只展示原记忆的摘要/正文/链接)。
    private func attachmentSection(_ attachment: TaskAttachment) -> some View {
        Section("附件") {
            Label(attachment.kind.label, systemImage: attachment.kind.symbol)
                .foregroundStyle(.secondary)
            if !attachment.summary.isEmpty {
                Text(attachment.summary).font(.footnote)
            } else if !attachment.text.isEmpty {
                Text(attachment.text).font(.footnote).lineLimit(4)
            }
            if let urlString = attachment.urlString, let url = URL(string: urlString) {
                Link(urlString, destination: url).font(.footnote).lineLimit(1)
            }
        }
    }

    private func save() {
        guard let parsed = form.makeParsed() else {
            errorText = "请补全事项内容和时间设置"
            return
        }
        onSave(parsed)
        dismiss()
    }

    private func applyAI() {
        let instruction = aiInstruction.trimmingCharacters(in: .whitespaces)
        guard !instruction.isEmpty, !aiBusy, let current = form.makeParsed() else { return }
        aiBusy = true
        errorText = nil
        Task {
            defer { aiBusy = false }
            do {
                let updated = try await DeepSeekClient.edit(
                    current, instruction: instruction,
                    existingProjects: TaskProjects.all(in: context))
                form.apply(updated)
                aiInstruction = ""
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
