import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.snoozeMinutesKey) private var snoozeMinutes = 15
    @AppStorage(AppSettings.allDayTimeKey) private var allDayTime = "09:00"
    @AppStorage(AppSettings.digestEnabledKey) private var digestEnabled = false
    @AppStorage(AppSettings.digestTimeKey) private var digestTime = "21:00"

    @State private var apiKey = KeychainHelper.apiKey ?? ""
    @State private var keySaved = false

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
            }
            .navigationTitle("设置")
            .onChange(of: apiKey) { keySaved = false }
            .onChange(of: digestEnabled) { refreshDigest() }
            .onChange(of: digestTime) { refreshDigest() }
        }
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
