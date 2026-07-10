import SwiftUI
import LodoCore

/// 创建/编辑共用表单;编辑模式下支持 AI 自然语言指令修改。
struct TaskEditView: View {
    let existing: TaskItem?
    var onSave: (ParsedTask) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var form: TaskFormModel

    @State private var aiInstruction = ""
    @State private var aiBusy = false
    @State private var errorText: String?

    init(existing: TaskItem?, parsed: ParsedTask?, onSave: @escaping (ParsedTask) -> Void) {
        self.existing = existing
        self.onSave = onSave
        let source: ParsedTask? = parsed ?? existing.map { ParsedTask(from: $0) }
        _form = State(initialValue: TaskFormModel(from: source))
    }

    var body: some View {
        NavigationStack {
            Form {
                TaskFormSections(form: $form)

                if existing != nil {
                    Section("AI 修改") {
                        TextField("例如:改到明天晚上8点", text: $aiInstruction)
                            .onSubmit { applyAI() }
                        Button {
                            applyAI()
                        } label: {
                            if aiBusy {
                                ProgressView().controlSize(.small)
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    // iOS/macOS 26 起用 confirm 角色表达确认动作语义,样式交给系统
                    if #available(iOS 26.0, macOS 26.0, *) {
                        Button("保存", role: .confirm) { save() }
                            .disabled(!form.isValid)
                    } else {
                        Button("保存") { save() }
                            .disabled(!form.isValid)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
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
                let updated = try await DeepSeekClient.edit(current, instruction: instruction)
                form.apply(updated)
                aiInstruction = ""
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
