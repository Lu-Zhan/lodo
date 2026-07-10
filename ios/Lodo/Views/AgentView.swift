#if os(iOS)
import SwiftUI

/// 主页下拉唤出的全局 agent:大对话框,一句话新增/修改/完成/删除待办(可批量);
/// 右下角语音按钮,讲完话自动提交。单条新建/修改直达表单;
/// 批量或含完成/删除的操作先在本页确认;信息不全时反问并给候选。
struct AgentView: View {
    /// 解析并路由输入文本;返回本页要展示的回应形态。
    let submit: (String) async throws -> AgentReply
    /// 用户确认执行批量操作(操作暂存在 TodoListView)。
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var speech = SpeechInput()
    /// 开始录音时已输入的文字,听写结果追加在其后。
    @State private var typedPrefix = ""

    /// 待确认的操作描述清单。
    @State private var confirmLines: [String]?
    /// 反问:问题 + 候选补充。
    @State private var clarify: (question: String, options: [String])?
    /// 反问时保留的原话,选候选后拼接重新提交。
    @State private var clarifyBase = ""

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

                if let clarify {
                    clarifySection(clarify)
                }
                if let confirmLines {
                    confirmSection(confirmLines)
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
            .onAppear {
                #if DEBUG
                // 截图验证用:模拟确认清单 / 反问两种回应态
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-confirm") {
                    confirmLines = ["新建:开周会(明天 15:00 · 60 分钟)",
                                    "完成:给妈妈回电话", "删除:取快递"]
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-agent-clarify") {
                    clarifyBase = "提醒我交材料"
                    text = clarifyBase
                    clarify = (question: "什么时候提醒你交材料?",
                               options: ["明天 09:00", "明天 14:00", "今晚 20:00"])
                }
                #endif
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 回应区块

    private func clarifySection(_ clarify: (question: String, options: [String])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(clarify.question, systemImage: "questionmark.circle")
                .font(.subheadline)
            HStack {
                ForEach(clarify.options, id: \.self) { option in
                    Button(option) {
                        resolveClarify(with: option)
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
            }
        }
    }

    private func confirmSection(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(lines, id: \.self) { line in
                Label(line, systemImage: icon(for: line))
                    .font(.subheadline)
            }
            HStack {
                Button("取消") {
                    confirmLines = nil
                }
                .buttonStyle(.bordered)
                Button {
                    Haptics.success()
                    onConfirm()
                } label: {
                    Label("确认执行", systemImage: "checkmark")
                }
                .glassProminentButton()
            }
        }
        .padding(12)
        .background(.fill.quaternary,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func icon(for line: String) -> String {
        if line.hasPrefix("新建") { return "plus.circle" }
        if line.hasPrefix("修改") { return "pencil.circle" }
        if line.hasPrefix("完成") { return "checkmark.circle" }
        if line.hasPrefix("删除") { return "trash.circle" }
        return "circle"
    }

    // MARK: - 提交

    /// 反问后选了候选:原话 + 补充重新提交。
    private func resolveClarify(with option: String) {
        let base = clarifyBase.isEmpty ? text : clarifyBase
        clarify = nil
        parse(override: "\(base)\n补充:\(option)")
    }

    private func parse(override: String? = nil) {
        let trimmed = (override ?? text).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !busy else { return }
        speech.stop()
        busy = true
        errorText = nil
        confirmLines = nil
        Task {
            defer { busy = false }
            do {
                switch try await submit(trimmed) {
                case .routed:
                    break  // sheet 已切到新建/编辑表单
                case .confirm(let lines):
                    clarify = nil
                    confirmLines = lines
                case .clarify(let question, let options):
                    clarifyBase = trimmed
                    confirmLines = nil
                    clarify = (question: question, options: options)
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
#endif
