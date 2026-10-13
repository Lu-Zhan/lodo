import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
import LodoCore

// MARK: - 上传体检报告

/// 上传一份体检报告:选文件(PDF/图片,可多个)/ 拍照 / 相册,选好归在谁名下,
/// 点「整理」后端上提取文字 → AI 整理成条目 → 落库,直接打开那份报告。
///
/// 没有确认页,理由见 `DeepSeekClient.parseCheckupReport` 的注释。
struct CheckupImportView: View {
    var initialProfile: UUID?
    var onCreated: (MemoryItem) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HealthProfile.createdAt) private var profiles: [HealthProfile]

    @State private var profileID: UUID?
    @State private var files: [URL] = []
    @State private var photos: [Photo] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var working = false
    @State private var errorMessage: String?
    @State private var importTask: Task<Void, Never>?

    private struct Photo: Identifiable {
        let id = UUID()
        let data: Data
        var thumbnail: Image? { platformImage(from: data) }
    }

    /// 文件先拷进这里再整理:fileImporter 给的是 security-scoped 地址,整理是异步的,
    /// 拖到那时访问权早就还回去了。
    private static let stagingDir = FileManager.default.temporaryDirectory
        .appending(path: "checkup-import", directoryHint: .isDirectory)

    private var hasInput: Bool { !files.isEmpty || !photos.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("档案", selection: $profileID) {
                        Text("我").tag(UUID?.none)
                        ForEach(profiles) { profile in
                            Text(profile.name).tag(Optional(profile.uuid))
                        }
                    }
                } footer: {
                    if profileID != nil {
                        Text("家人的报告只记录和分享,不参与 AI 健康分析。")
                    }
                }

                Section {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("选择文件", systemImage: "doc")
                    }
                    #if os(iOS)
                    if CameraPicker.isAvailable {
                        Button {
                            showCamera = true
                        } label: {
                            Label("拍照", systemImage: "camera")
                        }
                    }
                    #endif
                    PhotosPicker(selection: $photoItems, matching: .images) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                    ForEach(files, id: \.self) { file in
                        Label(file.lastPathComponent, systemImage: "doc.text")
                            .lineLimit(1)
                    }
                    .onDelete { files.remove(atOffsets: $0) }
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        HStack(spacing: 12) {
                            if let image = photo.thumbnail {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            Text("第 \(index + 1) 页")
                        }
                    }
                    .onDelete { photos.remove(atOffsets: $0) }
                } header: {
                    Text("报告")
                } footer: {
                    Text("支持 PDF 和图片,纸质报告每页拍一张。文字在本机识别,发给 AI 的只有识别出来的文字;原文件留在本机,随时可以打开对照。")
                }

                if working {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在识别并整理报告…")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("项目多的报告要整理一两分钟。")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(LodoColor.critical)
                    }
                }
            }
            .disabled(working)
            .pageTitle("上传体检报告")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        importTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("整理") { startImport() }
                        .disabled(working || !hasInput || !DeepSeekClient.isConfigured)
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.pdf, .image],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { stage(urls) }
            }
            .onChange(of: photoItems) { _, items in loadPicked(items) }
            .onAppear { profileID = initialProfile }
            .onDisappear { importTask?.cancel() }
            #if os(iOS)
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { data in photos.append(Photo(data: data)) }
                    .ignoresSafeArea()
            }
            #endif
            .interactiveDismissDisabled(working)
        }
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

    private func loadPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                photos.append(Photo(data: Self.normalized(data)))
            }
            photoItems = []
        }
    }

    /// 相册里可能是 HEIC、分辨率很高;转成 JPEG 再存(同菜单导入)。
    private static func normalized(_ data: Data) -> Data {
        #if os(iOS)
        return UIImage(data: data)?.jpegData(compressionQuality: 0.8) ?? data
        #else
        return data
        #endif
    }

    private func startImport() {
        errorMessage = nil
        working = true
        let files = files
        let images = photos.map(\.data)
        let profileID = profileID
        importTask = Task {
            defer { working = false }
            do {
                let item = try await CheckupStore.importReport(
                    files: files, images: images, profileID: profileID, context: context)
                guard !Task.isCancelled else { return }
                for file in files { try? FileManager.default.removeItem(at: file) }
                onCreated(item)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 编辑一项

/// 改一项指标/检查项,或者整份报告的综合建议。entry 为 nil 时是新建。
struct CheckupEntryEditView: View {
    let report: MemoryItem
    let entry: CheckupEntry?
    let kind: CheckupEntryKind

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category = ""
    @State private var value = ""
    @State private var unit = ""
    @State private var reference = ""
    @State private var flag: CheckupFlag?
    @State private var conclusion = ""
    @State private var advice = ""
    @State private var loaded = false
    @State private var confirmDelete = false

    private var canSave: Bool {
        switch kind {
        case .item: return !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .advice: return !advice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .item: itemFields
                case .advice: adviceFields
                }
                if entry != nil {
                    Section {
                        Button("删除这一项", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("删除这一项?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let entry { CheckupStore.deleteEntry(entry, context: context) }
                    dismiss()
                }
            }
            .onAppear(perform: load)
        }
    }

    private var title: String {
        switch (kind, entry == nil) {
        case (.advice, _): return String(localized: "综合建议", bundle: .appLanguage(), locale: AppSettings.language.locale)
        case (.item, true): return String(localized: "添加一项", bundle: .appLanguage(), locale: AppSettings.language.locale)
        case (.item, false): return name
        }
    }

    @ViewBuilder
    private var itemFields: some View {
        Section {
            TextField("名称", text: $name)
            TextField("分类(如 血常规)", text: $category)
        }
        Section {
            TextField("结果", text: $value)
            TextField("单位", text: $unit)
            TextField("参考范围(如 3.9-6.1)", text: $reference)
            Picker("标记", selection: $flag) {
                CheckupFlagLabel(flag: nil).text.tag(CheckupFlag?.none)
                ForEach(CheckupFlag.allCases, id: \.self) { flag in
                    CheckupFlagLabel(flag: flag).text.tag(Optional(flag))
                }
            }
        } header: {
            Text("结果")
        } footer: {
            Text("没有标记时按参考范围自动判断高低。")
        }
        Section {
            TextField("结论或描述", text: $conclusion, axis: .vertical)
                .lineLimit(2...8)
        } header: {
            Text("结论")
        }
        Section {
            TextField("报告里针对这一项的分析或建议", text: $advice, axis: .vertical)
                .lineLimit(2...8)
        } header: {
            Text("建议")
        }
    }

    private var adviceFields: some View {
        Section {
            TextField("报告里的综合建议或总检结论", text: $advice, axis: .vertical)
                .lineLimit(4...16)
        } footer: {
            Text("单项的建议记在对应的那一项下面。")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let entry else { return }
        name = entry.name
        category = entry.category
        value = entry.value
        unit = entry.unit
        reference = entry.referenceRange
        flag = entry.flag
        conclusion = entry.conclusion
        advice = entry.advice
    }

    private func save() {
        let target = entry ?? CheckupStore.addEntry(to: report, kind: kind, context: context)
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        target.name = clean(name)
        target.category = clean(category)
        target.value = clean(value)
        target.unit = clean(unit)
        target.referenceRange = clean(reference)
        target.flagRaw = flag?.rawValue ?? ""
        target.conclusion = clean(conclusion)
        target.advice = clean(advice)
        CheckupStore.entryChanged(target, context: context)
        dismiss()
    }
}

// MARK: - 编辑报告信息

struct CheckupReportEditView: View {
    let report: MemoryItem

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \HealthProfile.createdAt) private var profiles: [HealthProfile]

    @State private var title = ""
    @State private var date = Date()
    @State private var institution = ""
    @State private var profileID: UUID?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("报告名称", text: $title)
                    DatePicker("体检日期", selection: $date, displayedComponents: .date)
                    TextField("体检机构", text: $institution)
                }
                Section {
                    Picker("档案", selection: $profileID) {
                        Text("我").tag(UUID?.none)
                        ForEach(profiles) { profile in
                            Text(profile.name).tag(Optional(profile.uuid))
                        }
                    }
                } footer: {
                    Text("只有「我」名下的报告参与 AI 健康分析。")
                }
            }
            .pageTitle("编辑报告信息")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("保存") {
                        CheckupStore.updateReport(report, title: title, date: date,
                                                  institution: institution, profileID: profileID,
                                                  context: context)
                        dismiss()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                title = report.title
                date = CheckupStore.date(of: report)
                institution = report.checkupInstitution ?? ""
                profileID = report.checkupProfileUUID
            }
        }
    }
}

// MARK: - 家人档案

/// 新建/编辑一位家人。删除时连同 TA 名下的报告一起删(先确认)。
struct HealthProfileEditView: View {
    let profile: HealthProfile?
    /// 删除后调用(档案页拿它退回上一页)。
    var onDeleted: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var relation = ""
    @State private var hasBirthday = false
    @State private var birthday = Date()
    @State private var notes = ""
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字", text: $name)
                    TextField("关系(如 妈妈)", text: $relation)
                    Toggle("生日", isOn: $hasBirthday.animation())
                    if hasBirthday {
                        DatePicker("生日", selection: $birthday, displayedComponents: .date)
                            .labelsHidden()
                    }
                } footer: {
                    Text("家人的报告只记录和分享,不参与 AI 健康分析。")
                }
                Section {
                    TextField("备注(过敏史、慢病等)", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                if profile != nil {
                    Section {
                        Button("删除这份档案", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(profile == nil
                             ? String(localized: "添加家人档案", bundle: .appLanguage(), locale: AppSettings.language.locale)
                             : (profile?.name ?? ""))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("删除这份档案?TA 名下的体检报告和原文件会一并删除。",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let profile { CheckupStore.deleteProfile(profile, context: context) }
                    dismiss()
                    onDeleted()
                }
            } message: {
                switch profile?.shareRole {
                case .owner:
                    Text("这份档案正在共享:删除会停止共享,其他成员那边留一份不再同步的副本。")
                case .participant:
                    Text("这份档案是别人共享给你的:删除只会退出共享、删掉这台设备上的这份,不影响其他成员。")
                case nil:
                    EmptyView()
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                guard let profile else { return }
                name = profile.name
                relation = profile.relation
                hasBirthday = profile.birthday != nil
                birthday = profile.birthday ?? Date()
                notes = profile.notes
            }
        }
    }

    private func save() {
        let target = profile ?? {
            let created = HealthProfile(name: "")
            context.insert(created)
            return created
        }()
        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.relation = relation.trimmingCharacters(in: .whitespacesAndNewlines)
        target.birthday = hasBirthday ? birthday : nil
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try? context.save()
        dismiss()
    }
}
