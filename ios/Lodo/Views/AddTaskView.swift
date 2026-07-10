#if os(iOS)
import SwiftUI
import LodoCore

/// tab 栏"添加"按钮弹出的添加页,纵向两个模块:
/// 上方 AI 输入(自然语言 + 语音),解析结果直接回填下方手动输入表单;
/// 没说时长时再按记忆文件建议时长,并以颜色 + 图标标注 AI 建议。
struct AddTaskView: View {
    /// 保存新事项(AI 回填和手动填写共用同一个保存出口)。
    let onSaveManual: (ParsedTask) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var speech = SpeechInput()
    /// 开始录音时已输入的文字,听写结果追加在其后。
    @State private var typedPrefix = ""

    @State private var form = TaskFormModel()
    /// AI 解析回填过表单。
    @State private var aiFilled = false
    /// AI 按记忆建议的时长值;用户手动改动后清除高亮。
    @State private var suggestedDuration: Int?

    var body: some View {
        NavigationStack {
            Form {
                aiSection
                TaskFormSections(form: $form, header: "手动输入",
                                 aiFilled: aiFilled,
                                 suggestedDuration: suggestedDuration != nil)
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
            .onChange(of: form.duration) { _, duration in
                // 用户手动改动时长后,不再是 AI 建议值,清除高亮
                if let suggested = suggestedDuration, duration != suggested {
                    suggestedDuration = nil
                }
            }
            .onDisappear { speech.stop() }
            .onAppear {
                #if DEBUG
                // 截图验证用:--demo-ai-filled 模拟 AI 回填 + 时长建议的展示状态
                if ProcessInfo.processInfo.arguments.contains("--demo-ai-filled") {
                    var parsed = ParsedTask(
                        title: "项目评审", remindAt: Date().addingTimeInterval(3600),
                        allDay: false, durationMinutes: 60, repeatType: .none,
                        repeatDays: [], repeatTimes: [])
                    parsed.durationMinutes = 60
                    form = TaskFormModel(from: parsed)
                    aiFilled = true
                    suggestedDuration = 60
                }
                #endif
            }
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
            Text("一句话描述事项,解析结果会填入下方表单;没说时长时 AI 会按历史记忆建议。")
        }
    }

    /// AI 解析(仅新建)→ 回填手动表单;无时长且有记忆时追加一次时长建议小请求。
    private func parse() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !busy else { return }
        speech.stop()
        busy = true
        errorText = nil
        Task {
            defer { busy = false }
            do {
                var parsed = try await DeepSeekClient.parse(trimmed)
                var suggested: Int?
                if parsed.durationMinutes == 0, let memory = DurationMemory.content,
                   let minutes = try? await DeepSeekClient.suggestDuration(
                       text: trimmed, title: parsed.title, memory: memory),
                   minutes > 0 {
                    parsed.durationMinutes = minutes
                    suggested = minutes
                }
                form = TaskFormModel(from: parsed)
                aiFilled = true
                suggestedDuration = suggested
                text = ""
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
