#if os(iOS)
import SwiftUI

/// 底部"添加"按钮弹出的快速添加页:自然语言文本框 + 右侧语音输入,
/// 提交后走 AI 总入口路由(新建或修改),由 TodoListView 接管后续表单。
struct AddTaskView: View {
    /// 解析并路由输入文本;抛错时在本页显示错误。
    let submit: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var speech = SpeechInput()
    /// 开始录音时已输入的文字,听写结果追加在其后。
    @State private var typedPrefix = ""

    var body: some View {
        NavigationStack {
            Form {
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
                    }
                    if speech.isRecording {
                        Text("正在聆听…").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = errorText ?? speech.errorText {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text("一句话新建事项,或直接说要改哪个事项;输入内容和当前待办列表会发送给 DeepSeek 解析。")
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
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button {
                            parse()
                        } label: {
                            Label("添加", systemImage: "sparkles")
                        }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .onChange(of: speech.transcript) { _, transcript in
                if !transcript.isEmpty { text = typedPrefix + transcript }
            }
            .onDisappear { speech.stop() }
        }
        .presentationDetents([.medium, .large])
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
}
#endif
