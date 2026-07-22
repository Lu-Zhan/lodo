import SwiftUI
import UniformTypeIdentifiers
import LodoCore

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @AppStorage(AppSettings.icloudSyncEnabledKey) private var icloudSyncEnabled = true

    @AppStorage(AppSettings.snoozeMinutesKey) private var snoozeMinutes = 15
    @AppStorage(AppSettings.allDayTimeKey) private var allDayTime = "09:00"
    @AppStorage(AppSettings.digestEnabledKey) private var digestEnabled = false
    @AppStorage(AppSettings.digestTimesKey) private var digestTimesRaw = ""
    @AppStorage(AppSettings.digestRepeatTypeKey) private var digestRepeatType = "daily"
    @AppStorage(AppSettings.digestDaysKey) private var digestDaysRaw = "0,1,2,3,4"

    @AppStorage(AppSettings.hapticsEnabledKey) private var hapticsEnabled = true

    // ---- 备份与恢复 ----
    @State private var exportedZipURL: URL?
    @State private var exportErrorMessage: String?
    @State private var showImportPicker = false
    @State private var pendingImportURL: URL?
    @State private var pendingImportManifest: BackupManifest?
    @State private var showImportConfirm = false
    @State private var importErrorMessage: String?
    @State private var importSuccessMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                // ---- iCloud ----
                Section {
                    Toggle("iCloud 同步", isOn: $icloudSyncEnabled)
                } footer: {
                    Text("开启后,待办会在登录同一 Apple ID 的 iPhone/Mac/Apple Watch 间自动同步;关闭后仅保存在本机。更改后需要退出并重新打开 App 才能生效。")
                }

                // ---- 备份与恢复 ----
                backupRestoreSection

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

                // ---- AI:服务商/API Key、思考、联网搜索、个性、语音、洞察、记忆、Skill 统一入口 ----
                Section {
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        Label("AI 设置", systemImage: "sparkles")
                    }
                } footer: {
                    Text("服务商与 API Key、思考强度、联网搜索、AI 个性、语音交互、完成洞察、AI 记忆、Skill 编辑都在这里。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onChange(of: digestEnabled) { refreshDigest() }
            .onChange(of: digestTimesRaw) { refreshDigest() }
            .onChange(of: digestRepeatType) { refreshDigest() }
            .onChange(of: digestDaysRaw) { refreshDigest() }
            .backupRestoreHandlers(
                showImportPicker: $showImportPicker,
                showImportConfirm: $showImportConfirm,
                confirmTitle: pendingImportManifest.map(importSummary) ?? "",
                onImportPicked: handleImportPicked,
                onMerge: { performImport(strategy: .merge) },
                onReplace: { performImport(strategy: .replace) },
                onCancelImport: {
                    pendingImportURL = nil
                    pendingImportManifest = nil
                },
                exportErrorMessage: $exportErrorMessage,
                importErrorMessage: $importErrorMessage,
                importSuccessMessage: $importSuccessMessage
            )
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func refreshDigest() {
        Task { @MainActor in NotificationManager.shared.refreshAll() }
    }

    // MARK: - 备份与恢复

    @ViewBuilder
    private var backupRestoreSection: some View {
        Section {
            Button {
                exportBackup()
            } label: {
                Label("导出备份", systemImage: "square.and.arrow.up")
            }
            if let exportedZipURL {
                ShareLink(item: exportedZipURL) {
                    Label("分享导出的文件", systemImage: "square.and.arrow.up.on.square")
                }
            }
            Button {
                showImportPicker = true
            } label: {
                Label("导入备份", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("备份与恢复")
        } footer: {
            Text("导出一份包含待办、记忆(含附件)、AI 对话与设置的 zip 文件,可用于换设备或本地留档;不含 API Key,与 iCloud 同步互不影响。")
        }
    }

    private func exportBackup() {
        do {
            exportedZipURL = try BackupManager.export(context: context)
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func handleImportPicked(_ result: Result<[URL], Error>) {
        guard let url = try? result.get().first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let localURL = FileManager.default.temporaryDirectory
                .appending(path: "lodo-import-\(UUID().uuidString).zip")
            try? FileManager.default.removeItem(at: localURL)
            try FileManager.default.copyItem(at: url, to: localURL)
            pendingImportManifest = try BackupManager.preview(zipURL: localURL)
            pendingImportURL = localURL
            showImportConfirm = true
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    private func performImport(strategy: BackupManager.MergeStrategy) {
        guard let url = pendingImportURL else { return }
        do {
            try BackupManager.commit(zipURL: url, strategy: strategy, context: context)
            importSuccessMessage = "待办、记忆与 AI 对话已导入;如果设置项有变化(如 iCloud 同步),需要退出并重新打开 App 才能生效。"
        } catch {
            importErrorMessage = error.localizedDescription
        }
        pendingImportURL = nil
        pendingImportManifest = nil
    }

    private func importSummary(_ manifest: BackupManifest) -> String {
        let date = manifest.exportedAt.formatted(date: .abbreviated, time: .shortened)
        return "导出于 \(date) · \(manifest.taskCount) 条待办 · \(manifest.memoryCount) 条记忆 · \(manifest.agentThreadCount) 个 AI 对话"
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
    /// 导出/导入备份用到的 fileImporter + 确认弹窗 + 三个提示 alert;拆成单独的
    /// modifier 是因为直接拼进 body 的修饰符链会让类型检查器超时
    /// (SettingsView 的 Form 本来就大)。
    func backupRestoreHandlers(
        showImportPicker: Binding<Bool>,
        showImportConfirm: Binding<Bool>,
        confirmTitle: String,
        onImportPicked: @escaping (Result<[URL], Error>) -> Void,
        onMerge: @escaping () -> Void,
        onReplace: @escaping () -> Void,
        onCancelImport: @escaping () -> Void,
        exportErrorMessage: Binding<String?>,
        importErrorMessage: Binding<String?>,
        importSuccessMessage: Binding<String?>
    ) -> some View {
        self
            .fileImporter(
                isPresented: showImportPicker,
                allowedContentTypes: [.zip],
                allowsMultipleSelection: false,
                onCompletion: onImportPicked
            )
            .confirmationDialog(
                confirmTitle, isPresented: showImportConfirm, titleVisibility: .visible
            ) {
                Button("合并更新", action: onMerge)
                Button("先清空再导入", role: .destructive, action: onReplace)
                Button("取消", role: .cancel, action: onCancelImport)
            } message: {
                Text("合并更新按待办/记忆逐条对齐,不删除设备上已有的内容;先清空再导入会删除设备上所有待办、记忆和 AI 对话,不可撤销。")
            }
            .alert("导出失败", isPresented: Binding(
                get: { exportErrorMessage.wrappedValue != nil },
                set: { if !$0 { exportErrorMessage.wrappedValue = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(exportErrorMessage.wrappedValue ?? "")
            }
            .alert("导入失败", isPresented: Binding(
                get: { importErrorMessage.wrappedValue != nil },
                set: { if !$0 { importErrorMessage.wrappedValue = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importErrorMessage.wrappedValue ?? "")
            }
            .alert("已导入", isPresented: Binding(
                get: { importSuccessMessage.wrappedValue != nil },
                set: { if !$0 { importSuccessMessage.wrappedValue = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importSuccessMessage.wrappedValue ?? "")
            }
    }
}
