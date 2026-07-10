#if os(iOS)
import SwiftUI
import LodoCore

/// tab 栏"添加"按钮弹出的添加页,纵向两个模块:
/// 上方 AI 输入(自然语言 + 语音,走总入口路由),下方手动输入完整表单。
struct AddTaskView: View {
    /// AI 路径:解析并路由输入文本;抛错时在本页显示错误。
    let submit: (String) async throws -> Void
    /// 手动路径:直接保存新事项。
    let onSaveManual: (ParsedTask) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var speech = SpeechInput()
    /// 开始录音时已输入的文字,听写结果追加在其后。
    @State private var typedPrefix = ""

    @State private var form = TaskFormModel()

    var body: some View {
        NavigationStack {
            Form {
                aiSection
                TaskFormSections(form: $form, header: "手动输入")
                Section {
                    Button {
                        saveManual()
                    } label: {
                        Label("保存", systemImage: "checkmark")
                    }
                    .disabled(!form.isValid)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", role: .cancel) {
                        speech.stop()
                        dismiss()
                    }
                }
            }
            .onChange(of: speech.transcript) { _, transcript in
                if !transcript.isEmpty { text = typedPrefix + transcript }
            }
            .onDisappear { speech.stop() }
        }
    }

    private var aiSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                TextField("例如:明天3点开会一小时", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .onSubmit { parse() }
                Button {
                    typedPrefix = text
                    speech.toggle()
                } label: {
                    Image(systemName: speech.isRecording
                          ? "stop.circle.fill" : "mic.fill")
                        .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel(speech.isRecording ? "停止语音输入" : "语音输入")
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        parse()
                    } label: {
                        Image(systemName: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("解析")
                }
            }
            if speech.isRecording {
                Text("正在聆听…").font(.footnote).foregroundStyle(.secondary)
            }
            if let error = errorText ?? speech.errorText {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("AI 助手")
        } footer: {
            Text("一句话新建事项,或直接说要改哪个事项;输入内容和当前待办列表会发送给 DeepSeek 解析。")
        }
    }

    private func parse() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !busy else { return }
        speech.stop()
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                try await submit(trimmed)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func saveManual() {
        guard let parsed = form.makeParsed() else {
            errorText = "请补全事项内容和时间设置"
            return
        }
        onSaveManual(parsed)
        dismiss()
    }
}
#endif
