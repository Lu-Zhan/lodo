import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.snoozeMinutesKey) private var snoozeMinutes = 15
    @AppStorage(AppSettings.allDayTimeKey) private var allDayTime = "09:00"
    @AppStorage(AppSettings.digestEnabledKey) private var digestEnabled = false
    @AppStorage(AppSettings.digestTimeKey) private var digestTime = "21:00"

    @AppStorage(AppSettings.hapticsEnabledKey) private var hapticsEnabled = true

    @State private var apiKey = KeychainHelper.apiKey ?? ""
    @State private var keySaved = KeychainHelper.apiKey != nil
    @State private var confirmMemoryReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("稍等间隔:\(snoozeMinutes) 分钟",
                            value: $snoozeMinutes, in: 1...240, step: 5)
                } footer: {
                    Text("稍等或忽略提醒后,间隔多久再次提醒,直到完成。")
                }

                Section {
                    DatePicker("全天事项提醒时间", selection: timeBinding($allDayTime),
                               displayedComponents: .hourAndMinute)
                } footer: {
                    Text("只有日期、没有时间的事项,当天几点提醒。")
                }

                Section {
                    Toggle("每日待办汇总", isOn: $digestEnabled)
                    if digestEnabled {
                        DatePicker("汇总提醒时间", selection: timeBinding($digestTime),
                                   displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("每天固定时间提醒当前未完成的事项数量。")
                }

                #if os(iOS)
                Section {
                    Toggle("振动反馈", isOn: $hapticsEnabled)
                } footer: {
                    Text("滑动完成、删除等操作时轻微振动。")
                }
                #endif

                Section {
                    SecureField("DeepSeek API Key(sk-…)", text: $apiKey)
                    Button(keySaved ? "已保存" : "保存 API Key") {
                        KeychainHelper.save(apiKey)
                        keySaved = true
                    }
                    .disabled(keySaved)
                } header: {
                    Text("AI(DeepSeek)")
                } footer: {
                    Text("用于自然语言创建和编辑事项,保存在钥匙串中。")
                }

                Section {
                    NavigationLink("编辑记忆") { MemoryEditView() }
                    Button("重置记忆", role: .destructive) {
                        confirmMemoryReset = true
                    }
                    .confirmationDialog("确定清空 AI 记忆吗?", isPresented: $confirmMemoryReset,
                                        titleVisibility: .visible) {
                        Button("重置记忆", role: .destructive) { DurationMemory.reset() }
                    }
                } header: {
                    Text("AI 记忆")
                } footer: {
                    Text("AI 会在事项完成后归纳\"类型 → 典型时长\",新建没说时长的事项时据此建议。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: apiKey) { keySaved = false }
            .onChange(of: digestEnabled) { refreshDigest() }
            .onChange(of: digestTime) { refreshDigest() }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func refreshDigest() {
        Task { @MainActor in NotificationManager.shared.refreshAll() }
    }

    /// "HH:MM" 字符串 ↔ DatePicker 的 Date 绑定。
    private func timeBinding(_ storage: Binding<String>) -> Binding<Date> {
        Binding(
            get: { AppSettings.time(storage.wrappedValue, on: Date()) },
            set: { storage.wrappedValue = AppSettings.hhmm(from: $0) }
        )
    }
}
