import SwiftUI
import UniformTypeIdentifiers
import LodoCore

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @AppStorage(AppSettings.icloudSyncEnabledKey) private var icloudSyncEnabled = true
    @AppStorage(AppSettings.hapticsEnabledKey) private var hapticsEnabled = true
    @AppStorage(AppSettings.assetDisplayCurrencyKey) private var assetDisplayCurrency = "CNY"
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }
    @State private var showOnboarding = false

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

                // ---- 提醒:稍等间隔/全天提醒时间 + 每日待办汇总统一入口 ----
                Section {
                    NavigationLink {
                        ReminderSettingsView()
                    } label: {
                        Label("提醒", systemImage: "bell")
                    }
                } footer: {
                    Text("稍等间隔、全天事项提醒时间、每日待办汇总都在这里。")
                }

                // ---- 定时任务:用户自定义的 AI 例行任务 ----
                Section {
                    NavigationLink {
                        RoutineListView()
                    } label: {
                        Label("定时任务", systemImage: "clock.badge")
                    }
                } footer: {
                    Text("让 AI 在你设定的时间自动跑一件事,比如早上总结今天的待办、看天气给穿搭建议。")
                }

                // ---- 通用 ----
                #if os(iOS)
                Section {
                    Toggle("振动反馈", isOn: $hapticsEnabled)
                } footer: {
                    Text("滑动完成、删除等操作时轻微振动。")
                }
                #endif

                // ---- 语言 ----
                Section {
                    Picker("语言", selection: $languageRaw) {
                        ForEach(AppLanguage.allCases, id: \.rawValue) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                } footer: {
                    Text("独立于系统语言设置;AI 助手的对话内容不受影响,始终为中文。")
                }

                // ---- 资产 ----
                Section {
                    Picker("汇总展示币种", selection: $assetDisplayCurrency) {
                        ForEach(CurrencyCatalog.common, id: \.code) { entry in
                            Text("\(LocalizedStrings.translate(entry.name, language: language))(\(entry.code))")
                                .tag(entry.code)
                        }
                    }
                } footer: {
                    Text("记忆 tab 的「资产总览」把不同币种的资产换算成这种货币求和;汇率联网免费获取,每天自动更新一次。")
                }

                // ---- iCloud ----
                Section {
                    Toggle("iCloud 同步", isOn: $icloudSyncEnabled)
                } footer: {
                    Text("开启后,待办会在登录同一 Apple ID 的 iPhone/Mac/Apple Watch 间自动同步;关闭后仅保存在本机。更改后需要退出并重新打开 App 才能生效。")
                }

                // ---- 引导 ----
                Section {
                    Button {
                        showOnboarding = true
                    } label: {
                        Label("查看引导", systemImage: "sparkles")
                    }
                } footer: {
                    Text("重新看一遍首次打开时的功能介绍。")
                }

                // ---- 备份与恢复 ----
                backupRestoreSection
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
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
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(onFinish: { showOnboarding = false })
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
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
