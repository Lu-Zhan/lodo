import SwiftUI
import LodoCore

/// 设置 → 提醒:稍等间隔/全天提醒时间 + 每日待办汇总,统一收在这一个入口下。
struct ReminderSettingsView: View {
    @AppStorage(AppSettings.snoozeMinutesKey) private var snoozeMinutes = 15
    @AppStorage(AppSettings.allDayTimeKey) private var allDayTime = "09:00"
    @AppStorage(AppSettings.quietHoursEnabledKey) private var quietHoursEnabled = true
    @AppStorage(AppSettings.quietHoursStartKey) private var quietHoursStart = "22:00"
    @AppStorage(AppSettings.quietHoursEndKey) private var quietHoursEnd = "08:00"
    @AppStorage(AppSettings.digestEnabledKey) private var digestEnabled = false
    @AppStorage(AppSettings.digestTimesKey) private var digestTimesRaw = ""
    @AppStorage(AppSettings.digestRepeatTypeKey) private var digestRepeatType = "daily"
    @AppStorage(AppSettings.digestDaysKey) private var digestDaysRaw = "0,1,2,3,4"
    @AppStorage(AppSettings.repeatReminderEnabledKey) private var repeatReminderEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("反复提醒", isOn: $repeatReminderEnabled)
                // 关掉反复提醒也不 disable 它:用户主动点「稍等」用的就是这个间隔。
                Stepper("稍等间隔:\(snoozeMinutes) 分钟",
                        value: $snoozeMinutes, in: 1...240, step: 5)
                DatePicker("全天事项提醒时间", selection: timeBinding($allDayTime),
                           displayedComponents: .hourAndMinute)
            } header: {
                Text("提醒")
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("到期后每隔一个稍等间隔重复提醒,直到完成。")
                    Text("关掉后只提醒一次:事项仍然显示为逾期,你主动点「稍等」也照样有效。")
                    Text("只有日期、没有时间的事项,当天几点提醒。")
                }
            }

            Section {
                Toggle("免打扰时段", isOn: $quietHoursEnabled)
                if quietHoursEnabled {
                    DatePicker("开始", selection: timeBinding($quietHoursStart),
                               displayedComponents: .hourAndMinute)
                    DatePicker("结束", selection: timeBinding($quietHoursEnd),
                               displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("时段内到期事项照样显示为到期,只是不弹通知,时段结束后补发。")
            }

            Section {
                Toggle("每日任务汇总", isOn: $digestEnabled)
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
        }
        .formStyle(.grouped)
        .navigationTitle("提醒")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onChange(of: digestEnabled) { refreshDigest() }
        .onChange(of: digestTimesRaw) { refreshDigest() }
        .onChange(of: digestRepeatType) { refreshDigest() }
        .onChange(of: digestDaysRaw) { refreshDigest() }
        .onChange(of: quietHoursEnabled) { refreshDigest() }
        .onChange(of: quietHoursStart) { refreshDigest() }
        .onChange(of: quietHoursEnd) { refreshDigest() }
    }

    private func refreshDigest() {
        Task { @MainActor in NotificationManager.shared.refreshAll() }
    }

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
