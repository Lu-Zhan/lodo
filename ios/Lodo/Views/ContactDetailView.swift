import SwiftUI
import SwiftData
import QuickLook
import PhotosUI
import LodoCore
#if os(iOS)
import Contacts
#endif

/// 联系人详情:比通用的 MemoryDetailView 多出一整套结构化字段(头像/昵称/
/// 联系方式/生日/喜好/多附件/关系),塞进通用详情页会把它搞乱,所以单独一个
/// 视图——和资产共用 MemoryDetailView 只多一个字段的情况不一样。
struct ContactDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var item: MemoryItem

    @State private var tagsText: String
    @State private var nickname: String
    @State private var phone: String
    @State private var email: String
    @State private var hasBirthday: Bool
    @State private var birthday: Date
    @State private var preferences: String

    @State private var photoSelection: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var previewURL: URL?
    @State private var confirmDelete = false
    /// 已删除后 onDisappear 不再回写(避免访问已删除的模型)。
    @State private var deleted = false
    @State private var showAddRelationship = false
    /// contactRelationships(of:) 不是 @Query,不会随数据变化自动刷新;
    /// 每次增删关系后手动 +1,借 SwiftUI 对任意 @State 变化都会整体重算
    /// body 的机制,顺带让下面的 relationships 计算属性拿到最新结果。
    @State private var relationshipsTick = 0
    #if os(iOS)
    @State private var showExportSheet = false
    @State private var exportMutableContact: CNMutableContact?
    @State private var exportPermissionDenied = false
    @State private var exportResultMessage: String?
    #endif

    init(item: MemoryItem) {
        self.item = item
        _tagsText = State(initialValue: item.tags.joined(separator: "、"))
        _nickname = State(initialValue: item.contactNickname ?? "")
        _phone = State(initialValue: item.contactPhone ?? "")
        _email = State(initialValue: item.contactEmail ?? "")
        _hasBirthday = State(initialValue: item.contactBirthday != nil)
        _birthday = State(initialValue: item.contactBirthday ?? Date())
        _preferences = State(initialValue: item.contactPreferences ?? "")
    }

    private var relationships: [(relationship: ContactRelationship, other: MemoryItem)] {
        _ = relationshipsTick
        return MemoryPipeline.contactRelationships(of: item.uuid, context: context)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        avatarPreview
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section {
                TextField("姓名", text: $item.title)
                TextField("昵称", text: $nickname)
            }
            Section("联系方式") {
                TextField("手机", text: $phone)
                    #if os(iOS)
                    .keyboardType(.phonePad)
                    #endif
                TextField("邮箱", text: $email)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            Section {
                Toggle("生日", isOn: $hasBirthday)
                if hasBirthday {
                    DatePicker("生日", selection: $birthday, displayedComponents: .date)
                        .labelsHidden()
                }
            }
            Section("喜好") {
                TextField("如 咖啡、爬山", text: $preferences)
            }
            Section("备注") {
                TextEditor(text: $item.summary)
                    .frame(minHeight: 80)
            }
            Section("标签") {
                TextField("标签(用、分隔)", text: $tagsText)
                if !existingTags.isEmpty {
                    HorizontalChipRow {
                        ForEach(existingTags, id: \.self) { tag in
                            let selected = currentTags.contains(tag)
                            Button("#\(tag)") { toggle(tag) }
                                .font(.footnote)
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(selected ? Color.accentColor : Color.secondary)
                        }
                    }
                }
            }

            if !attachmentURLs.isEmpty {
                Section("附件") {
                    ForEach(attachmentURLs, id: \.self) { url in
                        Button {
                            previewURL = url
                        } label: {
                            Label(attachmentDisplayName(url), systemImage: "paperclip")
                        }
                    }
                }
            }

            Section {
                if relationships.isEmpty {
                    Text("还没有关联的联系人。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(relationships, id: \.relationship.uuid) { entry in
                        NavigationLink {
                            ContactDetailView(item: entry.other)
                        } label: {
                            LabeledContent(
                                entry.other.title.isEmpty ? "(未命名)" : entry.other.title,
                                value: entry.relationship.label)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                MemoryPipeline.deleteContactRelationship(
                                    entry.relationship, context: context)
                                relationshipsTick += 1
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    showAddRelationship = true
                } label: {
                    Label("添加关系", systemImage: "person.2")
                }
            } header: {
                Text("关系")
            }

            #if os(iOS)
            Section {
                Button {
                    Task { await beginExport() }
                } label: {
                    Label("导出到通讯录", systemImage: "square.and.arrow.up")
                }
            }
            #endif

            Section {
                Button("删除联系人", role: .destructive) {
                    confirmDelete = true
                }
            }
        }
        .navigationTitle(item.title.isEmpty ? "联系人" : item.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .quickLookPreview($previewURL)
        .onAppear {
            if avatarData == nil, let url = MemoryPipeline.contactAvatarURL(of: item) {
                avatarData = try? Data(contentsOf: url)
            }
        }
        .onChange(of: photoSelection) { _, selection in
            guard let selection else { return }
            Task {
                if let data = try? await selection.loadTransferable(type: Data.self) {
                    avatarData = data
                    saveAvatar(data)
                }
                photoSelection = nil
            }
        }
        .sheet(isPresented: $showAddRelationship) {
            AddContactRelationshipSheet(excluding: item.uuid) { other, label in
                MemoryPipeline.upsertContactRelationship(
                    between: item.uuid, and: other.uuid, label: label, context: context)
                relationshipsTick += 1
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showExportSheet) {
            if let exportMutableContact {
                ContactExportView(contact: exportMutableContact) { saved in
                    showExportSheet = false
                    exportResultMessage = saved ? "已导出到通讯录。" : nil
                }
            }
        }
        .alert("无法访问通讯录", isPresented: $exportPermissionDenied) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请在系统设置 → 隐私与安全性 → 通讯录 里允许 lodo 访问。")
        }
        .alert("已导出", isPresented: Binding(
            get: { exportResultMessage != nil },
            set: { if !$0 { exportResultMessage = nil } }
        )) {
            Button("好") { exportResultMessage = nil }
        } message: {
            Text(exportResultMessage ?? "")
        }
        #endif
        .confirmationDialog(
            "删除这位联系人?头像与附件会一并删除,已建立的关系也会一起消失。",
            isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deleted = true
                MemoryPipeline.delete(item, context: context)
                dismiss()
            }
        }
        .onDisappear { commitEdits() }
    }

    @ViewBuilder
    private var avatarPreview: some View {
        Group {
            if let avatarData, let image = platformImage(from: avatarData) {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(Circle())
    }

    private var attachmentURLs: [URL] {
        MemoryPipeline.contactAttachmentURLs(of: item)
    }

    /// 附件文件名是 "<uuid>-原文件名.ext"(见 MemoryPipeline.copyContactAttachment),
    /// 剥掉固定 37 字符的 uuid 前缀还原成用户能认出来的原名。
    private func attachmentDisplayName(_ url: URL) -> String {
        let name = url.lastPathComponent
        let prefixLength = 37
        guard name.count > prefixLength,
              name[name.index(name.startIndex, offsetBy: 36)] == "-" else { return name }
        return String(name.dropFirst(prefixLength))
    }

    private var existingTags: [String] {
        MemoryTags.all(in: context)
    }

    private var currentTags: [String] {
        Self.parseTags(tagsText)
    }

    private func toggle(_ tag: String) {
        var tags = currentTags
        if tags.contains(tag) {
            tags.removeAll { $0 == tag }
        } else {
            tags.append(tag)
        }
        tagsText = tags.joined(separator: "、")
    }

    private func saveAvatar(_ data: Data) {
        guard let dir = AppGroup.contactsDirURL else { return }
        let target = dir.appending(path: "\(item.uuid.uuidString)-avatar.jpg")
        guard (try? data.write(to: target, options: .atomic)) != nil else { return }
        item.contactAvatarRelativePath = "Contacts/\(target.lastPathComponent)"
        try? context.save()
    }

    #if os(iOS)
    private func beginExport() async {
        guard await ContactsBridge.requestAccess() == .granted else {
            exportPermissionDenied = true
            return
        }
        exportMutableContact = ContactsBridge.makeMutableContact(from: item)
        showExportSheet = true
    }
    #endif

    private func commitEdits() {
        guard !deleted else { return }
        let tags = Self.parseTags(tagsText)
        if tags != item.tags { item.tags = tags }
        item.contactNickname = nickname.isEmpty ? nil : nickname
        item.contactPhone = phone.isEmpty ? nil : phone
        item.contactEmail = email.isEmpty ? nil : email
        item.contactBirthday = hasBirthday ? birthday : nil
        item.contactPreferences = preferences.isEmpty ? nil : preferences
        try? context.save()
    }

    private static func parseTags(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "、,, "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// "关系" Section 里"添加关系"弹出的小 sheet:选一位其他联系人 + 填关系描述。
private struct AddContactRelationshipSheet: View {
    let excluding: UUID
    let onAdd: (MemoryItem, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\MemoryItem.title)]) private var allItems: [MemoryItem]
    @State private var selected: MemoryItem?
    @State private var label = ""

    private var candidates: [MemoryItem] {
        allItems.filter { $0.isContact && $0.uuid != excluding }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("联系人") {
                    if candidates.isEmpty {
                        Text("还没有其他联系人可以关联。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("联系人", selection: $selected) {
                            Text("请选择").tag(Optional<MemoryItem>.none)
                            ForEach(candidates) { contact in
                                Text(contact.title.isEmpty ? "(未命名)" : contact.title)
                                    .tag(Optional(contact))
                            }
                        }
                    }
                }
                Section("关系") {
                    TextField("如 同事、大学同学", text: $label)
                }
            }
            .navigationTitle("添加关系")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if let selected {
                            onAdd(selected, label)
                        }
                        dismiss()
                    }
                    .disabled(selected == nil
                              || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
