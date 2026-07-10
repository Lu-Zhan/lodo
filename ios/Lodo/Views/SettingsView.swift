import SwiftUI
import LodoCore

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.snoozeMinutesKey) private var snoozeMinutes = 15
    @AppStorage(AppSettings.allDayTimeKey) private var allDayTime = "09:00"
    @AppStorage(AppSettings.digestEnabledKey) private var digestEnabled = false
    @AppStorage(AppSettings.digestTimesKey) private var digestTimesRaw = ""
    @AppStorage(AppSettings.digestRepeatTypeKey) private var digestRepeatType = "daily"
    @AppStorage(AppSettings.digestDaysKey) private var digestDaysRaw = "0,1,2,3,4"

    @AppStorage(AppSettings.hapticsEnabledKey) private var hapticsEnabled = true
    @AppStorage(AppSettings.insightEnabledKey) private var insightEnabled = true

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
                        Picker("重复", selection: $digestRepeatType) {
                            Text("每天").tag("daily")
                            Text("每周").tag("weekly")
                        }
                        .pickerStyle(.segmented)
                        if digestRepeatType == "weekly" {
                            HStack {
                                ForEach(0..<7, id: \.self) { i in
                                    Toggle(String(weekdayNames[i].dropFirst()),
                                           isOn: digestDayBinding(i))
                                        .toggleStyle(.button)
                                }
                            }
                        }
                        ForEach(digestTimes.indices, id: \.self) { i in
                            DatePicker("时间 \(i + 1)", selection: digestTimeBinding(i),
                                       displayedComponents: .hourAndMinute)
                        }
                        .onDelete { offsets in
                            var times = digestTimes
                            times.remove(atOffsets: offsets)
                            setDigestTimes(times)
                        }
                        Button {
                            setDigestTimes(digestTimes + ["09:00"])
                        } label: {
                            Label("添加时间点", systemImage: "plus")
                        }
                    }
                } footer: {
                    Text("在设定时间提醒今天开始或到期的事项。")
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
                    Toggle("完成洞察", isOn: $insightEnabled)
                } footer: {
                    Text("每周在已完成页生成一句正向回顾,不会推送通知。")
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
            .onChange(of: digestTimesRaw) { refreshDigest() }
            .onChange(of: digestRepeatType) { refreshDigest() }
            .onChange(of: digestDaysRaw) { refreshDigest() }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func refreshDigest() {
        Task { @MainActor in NotificationManager.shared.refreshAll() }
    }

    // MARK: - 汇总设置的存取辅助

    /// 当前时间点列表(空值回退见 AppSettings.digestTimes)。
    private var digestTimes: [String] {
        let times = digestTimesRaw.split(separator: ",").map(String.init)
            .filter { !$0.isEmpty }
        return times.isEmpty ? AppSettings.digestTimes : times
    }

    private func setDigestTimes(_ times: [String]) {
        digestTimesRaw = times.joined(separator: ",")
    }

    private func digestTimeBinding(_ index: Int) -> Binding<Date> {
        Binding(
            get: {
                let times = digestTimes
                return AppSettings.time(index < times.count ? times[index] : "09:00",
                                        on: Date())
            },
            set: { date in
                var times = digestTimes
                guard index < times.count else { return }
                times[index] = AppSettings.hhmm(from: date)
                setDigestTimes(times)
            }
        )
    }

    private func digestDayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { AppSettings.digestDays.contains(day) },
            set: { on in
                var days = Set(digestDaysRaw.split(separator: ",").compactMap { Int($0) })
                if days.isEmpty { days = Set(AppSettings.digestDays) }
                if on { days.insert(day) } else { days.remove(day) }
                digestDaysRaw = days.sorted().map(String.init).joined(separator: ",")
            }
        )
    }

    /// "HH:MM" 字符串 ↔ DatePicker 的 Date 绑定。
    private func timeBinding(_ storage: Binding<String>) -> Binding<Date> {
        Binding(
            get: { AppSettings.time(storage.wrappedValue, on: Date()) },
            set: { storage.wrappedValue = AppSettings.hhmm(from: $0) }
        )
    }
}
