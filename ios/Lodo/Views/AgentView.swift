#if os(iOS)
import SwiftUI

/// 主页下拉唤出的全局 agent:大对话框,一句话新增或修改待办;
/// 右下角语音按钮,讲完话自动提交;解析后由 TodoListView 跳到新建/编辑表单。
struct AgentView: View {
    /// 解析并路由输入文本(新建/修改);抛错时在本页显示错误。
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
            VStack(alignment: .leading, spacing: 16) {
                TextField("例如:明天3点开会一小时 / 把开会改到晚上8点",
                          text: $text, axis: .vertical)
                    .font(.title3)
                    .lineLimit(3...8)
                    .padding(14)
                    .background(.fill.tertiary,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onSubmit { parse() }

                if speech.isRecording {
                    Text("正在聆听…").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = errorText ?? speech.errorText {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    // 右下角:语音输入,停止后自动提交
                    Button {
                        if speech.isRecording {
                            speech.stop()
                        } else {
                            typedPrefix = text
                            speech.toggle()
                        }
                    } label: {
                        Image(systemName: speech.isRecording
                              ? "stop.circle.fill" : "mic.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .accessibilityLabel(speech.isRecording ? "停止语音输入" : "语音输入")
                }
            }
            .padding()
            .navigationTitle("AI 助手")
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
                            Image(systemName: "sparkles")
                        }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityLabel("解析")
                    }
                }
            }
            .onChange(of: speech.transcript) { _, transcript in
                if !transcript.isEmpty { text = typedPrefix + transcript }
            }
            .onChange(of: speech.isRecording) { was, isRecording in
                // 讲完话(录音停止)稍等最终转写落定后自动提交
                if was && !isRecording && !busy && errorText == nil {
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        parse()
                    }
                }
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
