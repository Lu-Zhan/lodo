import SwiftUI
import UniformTypeIdentifiers
import LodoCore
#if os(iOS)
import UIKit
#endif

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @AppStorage(AppSettings.icloudSyncEnabledKey) private var icloudSyncEnabled = true
    @AppStorage(AppSettings.hapticsEnabledKey) private var hapticsEnabled = true
    @AppStorage(AppSettings.openAgentOnLaunchKey) private var openAgentOnLaunch = true
    @AppStorage(AppSettings.calendarEnabledKey) private var calendarEnabled = false
    @AppStorage(AppSettings.calendarWriteEnabledKey) private var calendarWriteEnabled = false
    @AppStorage(AppSettings.healthEnabledKey) private var healthEnabled = false
    @AppStorage(AppSettings.healthRangeDaysKey) private var healthRangeDays = 14
    @AppStorage(AppSettings.assetDisplayCurrencyKey) private var assetDisplayCurrency = "CNY"
    @AppStorage(AppSettings.assetStatsHiddenKey) private var assetStatsHidden = true
    @AppStorage(AppSettings.assetsInSidebarKey) private var assetsInSidebar = true
    @AppStorage(AppSettings.assetsAIIsolatedKey) private var assetsAIIsolated = true
    @Environment(\.itemNavigator) private var itemNavigator
    @Environment(\.openURL) private var openURL
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }
    @AppStorage(AppSettings.appIconStyleKey) private var appIconStyleRaw = AppIconStyle.white.rawValue
    @AppStorage(AppSettings.accentPaletteKey) private var accentPaletteRaw =
        AccentPalette.terracotta.rawValue
    @State private var iconChangeErrorMessage: String?
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

    /// 当前强调色预设(设置页自己也要用它渲染色块)。
    private var accentPalette: AccentPalette {
        AccentPalette(rawValue: accentPaletteRaw) ?? .terracotta
    }

    /// 只给截图参数用的 push 栈:simctl 点不了行,二级页要靠 --demo-* 直接推进来。
    /// 页面里原有的 NavigationLink { } label: { } 不走这个栈,照常工作。
    @State private var path: [SettingsRoute] = []

    enum SettingsRoute: Hashable { case reminder, syncStatus }

    /// macOS 上设置是独立的「设置」窗口(⌘,),窗口自己有关闭按钮,不再挂「完成」。
    private let isSettingsWindow: Bool

    init(isSettingsWindow: Bool = false) {
        self.isSettingsWindow = isSettingsWindow
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                // ---- AI:服务商/API Key、思考、联网搜索、个性、语音、洞察、记忆、Skill 统一入口 ----
                Section {
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        Label("AI 设置", systemImage: "sparkles")
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text("服务商、API Key、联网搜索、语音、Skill 等。")
                }

                // ---- 侧键 / Siri 快捷启动 ----
                #if os(iOS)
                Section {
                    Label("侧键 / Siri 快捷启动", systemImage: "button.programmable")
                } footer: {
                    Text("对 Siri 说“打开lodo助手”,或把操作按钮设为这条快捷指令,一键呼出 AI 助手。")
                }
                #endif

                // ---- 提醒与自动化:稍等间隔/全天提醒/每日汇总 + 用户自定义的 AI 例行任务 ----
                Section {
                    NavigationLink {
                        ReminderSettingsView()
                    } label: {
                        Label("提醒", systemImage: "bell")
                    }
                    NavigationLink {
                        RoutineListView()
                    } label: {
                        Label("定时任务", systemImage: "clock.badge")
                    }
                } header: {
                    Text("提醒与自动化")
                } footer: {
                    Text("稍等间隔、全天提醒、每日汇总。")
                }

                // ---- 系统日历(iOS / macOS 同一份 EventKit 实现)----
                Section {
                    Toggle("连接系统日历", isOn: $calendarEnabled)
                        .onChange(of: calendarEnabled) { _, enabled in
                            // 打开时就把授权弹窗走一遍,免得用户进了日历页
                            // 还得再点一次「连接日历」。
                            guard enabled else {
                                // 关读也就关了写(写是读的下级),顺手把已经
                                // 写进去的镜像事件清掉——用户关开关的意思就是
                                // "别在我日历里留东西"。账本也要清:留着的话
                                // 下次开开关,那些"事件是被我们自己删掉的"记录
                                // 会被当成"用户在日历里删的",把任务一起删掉。
                                calendarWriteEnabled = false
                                CalendarBridge.removeAllMirroredEvents()
                                CalendarSyncLedger.reset()
                                return
                            }
                            Task { await CalendarBridge.requestAccess() }
                        }
                    if calendarEnabled {
                        Toggle("把任务写进系统日历", isOn: $calendarWriteEnabled)
                            .onChange(of: calendarWriteEnabled) { _, enabled in
                                Task { @MainActor in
                                    if enabled {
                                        await CalendarBridge.requestAccess()
                                        CalendarSync.reconcile(context: context)
                                    } else {
                                        CalendarBridge.removeAllMirroredEvents()
                                        CalendarSyncLedger.reset()
                                    }
                                }
                            }
                    }
                } header: {
                    Text("系统日历")
                } footer: {
                    Text("开启后「日历」页显示你的日程。「把任务写进系统日历」会新建一本 lodo 日历并双向同步:在日历里改时间或标题会回写任务,删掉事件会连任务一起删除(不可撤销);关掉时写入的事件一并清除。")
                }

                // ---- 健康分析(Mac 上没有健康数据:只说明,不给开关)----
                if !HealthKitBridge.isAvailable {
                    Section {
                        Text("这台设备没有健康数据,步数、睡眠、心率的趋势和 AI 分析请在 iPhone 上查看。")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("健康分析")
                    }
                } else {
                Section {
                    Toggle("健康分析", isOn: $healthEnabled)
                        .onChange(of: healthEnabled) { _, enabled in
                            // 打开时就把授权弹窗走一遍,免得用户进了健康页
                            // 只看到一句"暂无数据"却不知道去哪授权。
                            guard enabled else { return }
                            Task { await HealthKitBridge.requestAuthorization() }
                        }
                    if healthEnabled {
                        Picker("回看天数", selection: $healthRangeDays) {
                            Text("7 天").tag(7)
                            Text("14 天").tag(14)
                            Text("30 天").tag(30)
                        }
                        Button("重新请求健康权限") {
                            Task { await HealthKitBridge.requestAuthorization() }
                        }
                    }
                } header: {
                    Text("健康分析")
                } footer: {
                    Text("「健康」页在本机汇总步数、睡眠、心率等趋势。只有汇总统计会发给 AI 服务商,原始记录不会离开这台设备;关闭后不发任何请求。")
                }
                }

                // ---- 通用 ----
                Section {
                    #if os(iOS)
                    Toggle("振动反馈", isOn: $hapticsEnabled)
                    #endif
                    // 决定冷启动落在 AI 页还是总览页(见 AppShellView.shouldOpenAgentOnLaunch)。
                    Toggle("打开 App 后默认进入 AI 助手", isOn: $openAgentOnLaunch)
                } header: {
                    Text("通用")
                }

                // ---- 强调色 ----
                Section {
                    HorizontalChipRow {
                        ForEach(AccentPalette.allCases) { palette in
                            let selected = accentPaletteRaw == palette.rawValue
                            Button {
                                accentPaletteRaw = palette.rawValue
                                // 桌面小组件(Chat)跟着换色。
                                WidgetBridge.writeTheme()
                            } label: {
                                VStack(spacing: 6) {
                                    Circle()
                                        .fill(palette.fill)
                                        .frame(width: 44, height: 44)
                                        .overlay {
                                            // 选中态画在色块**里面**:描在外面的话六个
                                            // 圆点的间距会随选中来回跳。
                                            if selected {
                                                Image(systemName: "checkmark")
                                                    .font(.footnote.weight(.bold))
                                                    .foregroundStyle(palette.onFill)
                                            }
                                        }
                                        .overlay {
                                            Circle().strokeBorder(
                                                selected ? Color.primary.opacity(0.35) : .clear,
                                                lineWidth: 2)
                                        }
                                    Text(palette.displayName)
                                        .font(.footnote)
                                        .foregroundStyle(selected ? .primary : .secondary)
                                }
                            }
                            .pressable()
                            .accessibilityLabel(palette.displayName)
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("强调色")
                } footer: {
                    Text("按钮、选中态和链接的颜色。")
                }

                // ---- App 图标(莫兰迪色系,仅 iOS 支持切换备用图标)----
                #if os(iOS)
                Section {
                    HorizontalChipRow {
                        ForEach(AppIconStyle.allCases, id: \.rawValue) { style in
                            let selected = appIconStyleRaw == style.rawValue
                            Button {
                                appIconStyleRaw = style.rawValue
                                applyAppIcon(style)
                            } label: {
                                VStack(spacing: 6) {
                                    Image(style.previewImageName)
                                        .resizable()
                                        .aspectRatio(1, contentMode: .fit)
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                                        }
                                    Text(LocalizedStrings.translate(style.displayName, language: language))
                                        .font(.footnote)
                                        .foregroundStyle(selected ? .primary : .secondary)
                                }
                            }
                            .pressable()
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("App 图标")
                } footer: {
                    Text("莫兰迪色系,默认白色。")
                }
                #endif

                // ---- 语言 ----
                Section {
                    Picker("语言", selection: $languageRaw) {
                        ForEach(AppLanguage.allCases, id: \.rawValue) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                } header: {
                    Text("语言")
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
                    Toggle("隐藏资产统计", isOn: $assetStatsHidden)
                    Toggle("在侧栏显示资产", isOn: $assetsInSidebar)
                    // 备用入口:侧栏里关掉「资产」之后从这里进。
                    Button {
                        openAssets()
                    } label: {
                        Label("打开资产", systemImage: "banknote")
                    }
                    Toggle("AI 与资产隔离", isOn: $assetsAIIsolated)
                } header: {
                    Text("资产")
                } footer: {
                    Text("汇率每天联网更新一次。「隐藏资产统计」把资产页的金额显示成 ***,点一下露出;「AI 与资产隔离」让 AI 只能新建资产,看不到已有的。")
                }

                // ---- iCloud ----
                Section {
                    Toggle("iCloud 同步", isOn: $icloudSyncEnabled)
                    NavigationLink {
                        CloudSyncStatusView()
                    } label: {
                        Text("同步状态")
                    }
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("在登录同一 Apple ID 的设备间同步任务;更改后需重新打开 App 生效。")
                }

                // ---- 引导 ----
                Section {
                    Button {
                        showOnboarding = true
                    } label: {
                        Label("查看引导", systemImage: "sparkles")
                    }
                } footer: {
                    Text("重看首次打开时的功能介绍。")
                }

                // ---- 备份与恢复 ----
                backupRestoreSection
            }
            .formStyle(.grouped)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .reminder: ReminderSettingsView()
                case .syncStatus: CloudSyncStatusView()
                }
            }
            #if DEBUG
            // 截图验证用:直接推到「提醒」二级页(simctl 点不了那一行)。
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("--demo-reminder-settings") {
                    path = [.reminder]
                }
                if ProcessInfo.processInfo.arguments.contains("--demo-sync-status") {
                    path = [.syncStatus]
                }
            }
            #endif
            .pageTitle("设置")
            // 设置是 sheet(独立呈现宿主),根上那次柔和渐隐传不进来,自己挂一次:
            // 滚进标题栏的内容同 AI 页一样渐变消隐(用户要求)。
            .softTopScrollEdgeTransition()
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if !isSettingsWindow {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
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
            // macOS 没有 fullScreenCover(API 本身就不可用),用窗口 sheet 代替。
            #if os(iOS)
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(onFinish: { showOnboarding = false })
            }
            #else
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(onFinish: { showOnboarding = false })
            }
            #endif
            #if os(iOS)
            .alert("切换图标失败", isPresented: Binding(
                get: { iconChangeErrorMessage != nil },
                set: { if !$0 { iconChangeErrorMessage = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(iconChangeErrorMessage ?? "")
            }
            #endif
        }
        // 设置页是以 sheet 呈现的,而 **sheet 的内容是独立的呈现宿主,不继承
        // AppShellView 根上那份 .tint**(实测:根上换成赤陶后,设置页里的
        // Label 图标仍是系统蓝)。所以这里自己再下发一份,和根上同源同一个键。
        .tint(accentPalette.accent)
        .environment(\.lodoAccent, accentPalette)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    // MARK: - App 图标

    #if os(iOS)
    private func applyAppIcon(_ style: AppIconStyle) {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        guard UIApplication.shared.alternateIconName != style.alternateIconName else { return }
        UIApplication.shared.setAlternateIconName(style.alternateIconName) { error in
            if let error {
                iconChangeErrorMessage = error.localizedDescription
            }
        }
    }
    #endif

    // MARK: - 备份与恢复

    /// 设置里那一行「打开资产」:先收起设置再切到资产页。macOS 的设置是独立窗口、
    /// 拿不到页面导航,走 lodo://assets 交给主窗口。
    private func openAssets() {
        if let itemNavigator {
            dismiss()
            itemNavigator.open(.assets)
        } else if let url = URL(string: "lodo://assets") {
            openURL(url)
        }
    }

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
            Text("导出任务、记忆(含附件)、AI 对话与设置为 zip,不含 API Key。")
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
        Task {
            do {
                try await BackupManager.commit(zipURL: url, strategy: strategy, context: context)
                importSuccessMessage = LocalizedStrings.text(.ios_core_backup_import_success,
                                                              language: language)
            } catch {
                importErrorMessage = error.localizedDescription
            }
            pendingImportURL = nil
            pendingImportManifest = nil
        }
    }

    private func importSummary(_ manifest: BackupManifest) -> String {
        let date = LocalizedContent.abbreviatedDateTime(manifest.exportedAt)
        return String(format: LocalizedStrings.text(.ios_core_backup_import_summary,
                                                     language: language),
                      date as NSString, manifest.taskCount, manifest.memoryCount,
                      manifest.agentMessageCount)
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
                Text("合并更新按任务/记忆逐条对齐,不删除设备上已有的内容;先清空再导入会删除设备上所有任务、记忆和 AI 对话,不可撤销。")
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

private extension View {
    /// 关闭自动大写与纠错(macOS 无 textInputAutocapitalization)。
    /// 与 AISettingsView 里那份同名同实现——两处都是 fileprivate,各自持有一份,
    /// 不值得为两行代码再开一个共享文件。
    @ViewBuilder
    func plainKeyboard() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
