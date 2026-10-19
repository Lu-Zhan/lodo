import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import LodoCore

// MARK: - 上传体重秤记录

/// 上传体脂秤 app 的截图/PDF/拍照 → 端上取字、AI 整理 → **确认页**逐条核对、勾选 → 落库。
/// 选文件这一半照抄体检报告的 `CheckupImportView`;确认页是这边多出来的一步,理由见
/// `WeightReportStore`。
struct WeightReportImportView: View {
    /// 已有的体重记录(手记 + 导入 + 健康库),用来标出"已经记过"的测量。
    let existing: [WeightEntry]

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var files: [URL] = []
    @State private var photos: [Photo] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var task: Task<Void, Never>?
    @State private var loadingPhotos = 0
    @State private var failedPhotos = 0

    /// 整理完的结果;非 nil 时显示确认页。
    @State private var prepared: (rawText: String, report: ParsedWeightReport)?
    @State private var drafts: [Draft] = []

    private struct Photo: Identifiable {
        let id = UUID()
        let data: Data
        var thumbnail: Image? { platformImage(from: data) }
    }

    /// 确认页上的一次测量:数字用文字框编辑,保存时再校验。
    struct Draft: Identifiable {
        let id = UUID()
        var include: Bool
        var duplicate: Bool
        /// 截图上看不出日期:要用户自己定,定之前不能保存这一条。
        var missingDate: Bool
        var date: Date
        var dateOnly: Bool
        var weight: String
        var bodyFat: String
        var muscle: String
        var visceral: String
        var basal: String
        var water: String
        var bone: String
    }

    private static let stagingDir = FileManager.default.temporaryDirectory
        .appending(path: "weight-report-import", directoryHint: .isDirectory)

    private var hasInput: Bool { !files.isEmpty || !photos.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if prepared == nil {
                    inputSections
                } else {
                    reviewSections
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(LodoColor.critical)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            .pageTitle(prepared == nil ? "上传体重秤记录" : "核对测量")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        task?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if prepared == nil {
                        confirmButton("整理") { startPrepare() }
                            .disabled(working || loadingPhotos > 0 || !hasInput || !DeepSeekClient.isConfigured)
                    } else {
                        confirmButton("保存") { save() }
                            .disabled(!canSave)
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .image],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { stage(urls) }
            }
            .onChange(of: photoItems) { _, items in loadPicked(items) }
            #if DEBUG
            .onAppear {
                guard ProcessInfo.processInfo.arguments.contains("--demo-weight-report-live"),
                      files.isEmpty, let pdf = WeightReportStore.demoPDFURL() else { return }
                stage([pdf])
                startPrepare()
            }
            #endif
            .onDisappear {
                // 拍照是全屏盖上来的,底下这页也会收到 onDisappear:那不是退出,
                // 已选的文件和正在跑的整理都得留着。
                guard !showCamera else { return }
                task?.cancel()
                cleanUp()
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in photos.append(Photo(data: data)) }
                    .ignoresSafeArea()
            }
            #endif
            .interactiveDismissDisabled(working || prepared != nil)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    // MARK: - 选文件

    @ViewBuilder
    private var inputSections: some View {
        Section {
            Button { showFileImporter = true } label: { Label("选择文件", systemImage: "doc") }
            #if os(iOS)
            if CameraPicker.isAvailable {
                Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
            }
            #endif
            PhotosPicker(selection: $photoItems, matching: .images) {
                Label("从相册选择", systemImage: "photo.on.rectangle")
            }
            if loadingPhotos > 0 {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在读取 \(loadingPhotos) 张照片…").foregroundStyle(.secondary)
                }
            }
            if failedPhotos > 0 {
                Text("有 \(failedPhotos) 张照片没读出来,可以重新选一次。")
                    .font(.subheadline)
                    .foregroundStyle(LodoColor.critical)
            }
            ForEach(files, id: \.self) { file in
                Label(file.lastPathComponent, systemImage: "doc.text").lineLimit(1)
            }
            .onDelete { files.remove(atOffsets: $0) }
            ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                HStack(spacing: 12) {
                    if let image = photo.thumbnail {
                        image.resizable().scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Text("第 \(index + 1) 张")
                }
            }
            .onDelete { photos.remove(atOffsets: $0) }
        } header: {
            Text("记录")
        } footer: {
            Text("体脂秤 app 的测量详情、历史列表截图或导出的 PDF 都可以。文字在本机识别,发给 AI 的只有识别出来的文字;整理完先给你核对,确认后才记下,原文件留在本机。")
        }
        if working {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在识别并整理…").foregroundStyle(.secondary)
                }
            }
        }
        if !DeepSeekClient.isConfigured {
            Section {
                Text("整理要用 AI,先在「设置 → AI 设置」里配置服务商。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 核对

    private var canSave: Bool {
        let chosen = drafts.filter(\.include)
        return !chosen.isEmpty && chosen.allSatisfy { !$0.missingDate }
    }

    @ViewBuilder
    private var reviewSections: some View {
        Section {
            ForEach($drafts) { $draft in
                draftRow($draft)
            }
        } header: {
            Text("认出 \(drafts.count) 次测量")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("勾上的才会记下。已经记过的默认不勾;截图上看不出日期的要先选好日期。数字不对可以直接改。")
                if let dropped = prepared?.report.droppedValues, dropped > 0 {
                    Text("有 \(dropped) 个读数单位不明或不在合理范围内,没有填进来,需要的话手动补上。")
                }
            }
        }
    }

    private func draftRow(_ draft: Binding<Draft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: draft.include) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary(draft.wrappedValue))
                        .font(.body.weight(.medium))
                    if draft.wrappedValue.duplicate {
                        Text("这一天已经记过同样的体重").font(.footnote).foregroundStyle(.secondary)
                    }
                    if draft.wrappedValue.missingDate {
                        Text("截图上没看到日期,请选一下")
                            .font(.footnote)
                            .foregroundStyle(LodoColor.critical)
                    }
                }
            }
            if draft.wrappedValue.include {
                DatePicker("时间", selection: Binding(
                    get: { draft.wrappedValue.date },
                    set: { draft.wrappedValue.date = $0; draft.wrappedValue.missingDate = false }
                ), in: ...Date(), displayedComponents: draft.wrappedValue.dateOnly ? [.date] : [.date, .hourAndMinute])
                DisclosureGroup("读数") {
                    numberField("体重", unit: "公斤", text: draft.weight)
                    numberField("体脂率", unit: "%", text: draft.bodyFat)
                    numberField("肌肉量", unit: "公斤", text: draft.muscle)
                    numberField("内脏脂肪", unit: "级", text: draft.visceral)
                    numberField("基础代谢", unit: "千卡", text: draft.basal)
                    numberField("水分", unit: "%", text: draft.water)
                    numberField("骨量", unit: "公斤", text: draft.bone)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func numberField(_ title: LocalizedStringKey, unit: LocalizedStringKey,
                             text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", text: text)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func summary(_ draft: Draft) -> String {
        WeightReportText.line(measurement(draft) ?? ParsedWeightMeasurement(date: draft.date))
    }

    // MARK: - 动作

    private func startPrepare() {
        errorMessage = nil
        working = true
        let files = files
        let images = photos.map(\.data)
        task = Task {
            defer { working = false }
            do {
                let result = try await WeightReportStore.prepare(files: files, images: images)
                guard !Task.isCancelled else { return }
                drafts = result.report.measurements.map { m in
                    let duplicate = WeightReport.isDuplicate(m, existing: existing)
                    return Draft(include: !duplicate && m.date != nil, duplicate: duplicate,
                                 missingDate: m.date == nil, date: m.date ?? Date(), dateOnly: m.dateOnly,
                                 weight: text(m.weightKg), bodyFat: text(m.bodyFatPercent),
                                 muscle: text(m.muscleMassKg), visceral: text(m.visceralFatLevel),
                                 basal: text(m.basalMetabolicKcal), water: text(m.bodyWaterPercent),
                                 bone: text(m.boneMassKg))
                }
                prepared = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func save() {
        guard let prepared else { return }
        var chosen: [ParsedWeightMeasurement] = []
        for draft in drafts where draft.include {
            // DatePicker 的上限挡得住手选,挡不住解析出来的默认值,保存前再查一次。
            guard draft.date <= Date().addingTimeInterval(WeightReport.futureSlack) else {
                errorMessage = String(localized: "测量时间不能晚于现在,请改一下日期。",
                                      bundle: .appLanguage(), locale: AppSettings.language.locale)
                return
            }
            guard let m = measurement(draft) else {
                errorMessage = String(localized: "有读数填得不对:只能填数字,而且要在合理范围内(体重 1–500 公斤、体脂率 1–79%,肌肉量和骨量要小于体重)。",
                                      bundle: .appLanguage(), locale: AppSettings.language.locale)
                return
            }
            chosen.append(m)
        }
        WeightReportStore.save(chosen, report: prepared.report, rawText: prepared.rawText,
                               files: files, images: photos.map(\.data), context: context)
        Haptics.success()
        dismiss()
    }

    /// 文字框 → 一次测量;任何一项填了但不是合理的数就返回 nil(整条不能存),一项都没有也是 nil。
    private func measurement(_ draft: Draft) -> ParsedWeightMeasurement? {
        var invalid = false
        func value(_ text: String, _ range: ClosedRange<Double>) -> Double? {
            let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard !trimmed.isEmpty else { return nil }
            guard let number = WeightReport.number(trimmed), range.contains(number) else {
                invalid = true
                return nil
            }
            return number
        }
        let m = ParsedWeightMeasurement(
            date: draft.date, dateOnly: draft.dateOnly,
            weightKg: value(draft.weight, WeightReport.weightRange),
            bodyFatPercent: value(draft.bodyFat, WeightReport.bodyFatRange),
            muscleMassKg: value(draft.muscle, WeightReport.muscleRange),
            visceralFatLevel: value(draft.visceral, WeightReport.visceralRange),
            basalMetabolicKcal: value(draft.basal, WeightReport.basalRange),
            bodyWaterPercent: value(draft.water, WeightReport.waterRange),
            boneMassKg: value(draft.bone, WeightReport.boneRange))
        // 肌肉量、骨量是体重的一部分(解析时同样的检查,这里防的是确认页上改过的数)。
        if let weight = m.weightKg,
           (m.muscleMassKg ?? 0) >= weight || (m.boneMassKg ?? 0) >= weight {
            invalid = true
        }
        return invalid || !m.hasValue ? nil : m
    }

    private func text(_ value: Double?) -> String {
        value.map { WeightPlan.format($0) } ?? ""
    }

    private func stage(_ urls: [URL]) {
        try? FileManager.default.createDirectory(at: Self.stagingDir, withIntermediateDirectories: true)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let target = Self.stagingDir.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
            if (try? FileManager.default.copyItem(at: url, to: target)) != nil {
                files.append(target)
            }
        }
    }

    private func cleanUp() {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    private func loadPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        loadingPhotos += items.count
        failedPhotos = 0
        Task {
            var loaded: [Photo] = []
            var failed = 0
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    loaded.append(Photo(data: Self.normalized(data)))
                } else {
                    failed += 1
                }
            }
            photos.append(contentsOf: loaded)
            failedPhotos = failed
            loadingPhotos = max(0, loadingPhotos - items.count)
            photoItems = []
        }
    }

    private static func normalized(_ data: Data) -> Data {
        #if os(iOS)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.8) ?? data
        #else
        return data
        #endif
    }
}
