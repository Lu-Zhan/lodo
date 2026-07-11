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
    @AppStorage(AppSettings.agentPersonaStyleKey) private var personaStyle = "默认"
    @AppStorage(AppSettings.agentPersonaCustomKey) private var personaCustom = ""
    @AppStorage(AppSettings.aiProviderKey) private var aiProvider = "DeepSeek"
    @AppStorage(AppSettings.aiModelKey) private var aiModel = ""
    @AppStorage(AppSettings.aiCustomEndpointKey) private var aiCustomEndpoint = ""

    @State private var apiKey = KeychainHelper.apiKey ?? ""
    @State private var keySaved = KeychainHelper.apiKey != nil
    @State private var confirmMemoryReset = false

    var body: some View {
        NavigationStack {
            Form {
                // ---- 提醒 ----
                Section {
                    Stepper("稍等间隔:\(snoozeMinutes) 分钟",
                            value: $snoozeMinutes, in: 1...240, step: 5)
                    DatePicker("全天事项提醒时间", selection: timeBinding($allDayTime),
                               displayedComponents: .hourAndMinute)
                } header: {
                    Text("提醒")
                } footer: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("稍等或忽略提醒后,间隔多久再次提醒,直到完成。")
                        Text("只有日期、没有时间的事项,当天几点提醒。")
                    }
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

                // ---- 通用 ----
                #if os(iOS)
                Section {
                    Toggle("振动反馈", isOn: $hapticsEnabled)
                } footer: {
                    Text("滑动完成、删除等操作时轻微振动。")
                }
                #endif

                // ---- AI:服务 → 个性 → 洞察 → 记忆 ----
                Section {
                    Picker("服务商", selection: $aiProvider) {
                        ForEach(AppSettings.aiProviders, id: \.name) { provider in
                            Text(provider.name).tag(provider.name)
                        }
                        Text(AppSettings.appleIntelligenceProvider)
                            .tag(AppSettings.appleIntelligenceProvider)
                        Text("自定义").tag("自定义")
                    }
                    if aiProvider == AppSettings.appleIntelligenceProvider {
                        Group {
                            if #available(iOS 26.0, macOS 26.0, *) {
                                Text(FoundationModelsClient.availabilityHint)
                            } else {
                                Text("苹果智能需要 iOS 26 及以上系统。")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    } else if aiProvider == "自定义" {
                        TextField("接口地址(…/chat/completions)", text: $aiCustomEndpoint)
                            .plainKeyboard()
                        TextField("模型名称", text: $aiModel)
                            .plainKeyboard()
                    } else {
                        TextField(
                            "模型(默认 \(AppSettings.aiProviders.first { $0.name == aiProvider }?.model ?? ""))",
                            text: $aiModel
                        )
                        .plainKeyboard()
                    }
                    if aiProvider != AppSettings.appleIntelligenceProvider {
                        SecureField("API Key", text: $apiKey)
                        Button(keySaved ? "已保存" : "保存 API Key") {
                            KeychainHelper.save(apiKey, for: aiProvider)
                            keySaved = true
                        }
                        .disabled(keySaved)
                    }
                } header: {
                    Text("AI 服务")
                } footer: {
                    Text("默认 DeepSeek;云服务商均为 OpenAI 兼容接口,key 按服务商分别保存在钥匙串中;苹果智能在设备端运行,免 key。")
                }

                Section {
                    Picker("AI 个性", selection: $personaStyle) {
                        Text("默认").tag("默认")
                        ForEach(AppSettings.personaPresets, id: \.name) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                        Text("自定义").tag("自定义")
                    }
                    if personaStyle == "自定义" {
                        TextField("描述 AI 的说话风格,例如:像武侠小说里的师父",
                                  text: $personaCustom, axis: .vertical)
                            .lineLimit(1...4)
                    } else if let preset = AppSettings.personaPresets
                        .first(where: { $0.name == personaStyle }) {
                        Text(preset.text)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("AI 个性")
                } footer: {
                    Text("影响反问、汇总和洞察的说话风格,不影响解析结果;默认为无个性。")
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
            .onChange(of: aiProvider) { _, provider in
                // 切换服务商:载入该服务商已存的 key,清掉模型覆盖值
                apiKey = KeychainHelper.apiKey(for: provider) ?? ""
                keySaved = !apiKey.isEmpty
                aiModel = ""
            }
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

private extension View {
    /// 关闭自动大写与纠错(macOS 无 textInputAutocapitalization)。
    @ViewBuilder
    func plainKeyboard() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
