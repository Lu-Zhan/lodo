import SwiftUI
import SwiftData
import PhotosUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// 记一位人脉(记忆 tab → "+" → 记一位人脉):姓名是结构化必填字段,直接落库
/// 不用等 AI 整理;其余字段可选。人脉本质是打了保留标签的记忆条目,见
/// MemoryItem.contactTagName 与 MemoryPipeline.saveContact。关系链接留到详情页
/// (新建表单先保持精简,和 AssetComposeView 同思路)。
struct ContactComposeView: View {
    /// 保存成功后回调(记忆列表页用来把"显示人脉"筛选打开,不然刚记的这位
    /// 人脉因为默认隐藏规则,保存完立刻从列表里"消失",像是没保存成功)。
    var onSaved: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var nickname = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var hasBirthday = false
    @State private var birthday = Date()
    @State private var preferences = ""
    @State private var note = ""

    @State private var photoSelection: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var pendingAttachments: [PendingContactAttachment] = []
    @State private var showFileImporter = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
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
                    TextField("姓名", text: $name)
                    TextField("昵称(可选)", text: $nickname)
                }
                Section("联系方式") {
                    TextField("手机(可选)", text: $phone)
                        #if os(iOS)
                        .keyboardType(.phonePad)
                        #endif
                    TextField("邮箱(可选)", text: $email)
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
                    TextField("如 咖啡、爬山(可选)", text: $preferences)
                }
                Section("备注") {
                    TextEditor(text: $note)
                        .frame(minHeight: 80)
                }
                Section {
                    ForEach(pendingAttachments) { attachment in
                        Label(attachment.displayName, systemImage: "paperclip")
                    }
                    .onDelete { indices in
                        pendingAttachments.remove(atOffsets: indices)
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("添加文件", systemImage: "plus")
                    }
                } header: {
                    Text("附件")
                } footer: {
                    Text("会自动打上「人脉」标签,记忆列表默认不显示,筛选里选中「人脉」才会看到。")
                }
            }
            .navigationTitle("记一位人脉")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .image, .plainText, .presentation, .data],
                allowsMultipleSelection: true
            ) { result in
                for url in (try? result.get()) ?? [] { stageAttachment(url) }
            }
            .onChange(of: photoSelection) { _, item in
                guard let item else { return }
                Task {
                    avatarData = try? await item.loadTransferable(type: Data.self)
                    photoSelection = nil
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    @ViewBuilder
    private var avatarPreview: some View {
        Group {
            if let avatarData, let image = platformImage(from: avatarData) {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(Circle())
    }

    private func save() {
        MemoryPipeline.saveContact(
            name: name, nickname: nickname, phone: phone, email: email,
            birthday: hasBirthday ? birthday : nil, preferences: preferences, note: note,
            avatarData: avatarData, attachmentFileURLs: pendingAttachments.map(\.stagedURL),
            context: context)
        onSaved()
        dismiss()
    }

    /// fileImporter 给的 URL 是 security-scoped 的,回调结束后访问权限可能失效;
    /// 挑选当下就拷进临时目录暂存,保存时(可能是稍后填完其余字段才点保存)
    /// 直接用这份暂存文件,不依赖已经过期的原始授权。
    private func stageAttachment(_ source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "contact-compose-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)) != nil else { return }
        let target = dir.appending(path: source.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: source, to: target)) != nil else { return }
        pendingAttachments.append(
            PendingContactAttachment(displayName: source.lastPathComponent, stagedURL: target))
    }
}

private struct PendingContactAttachment: Identifiable {
    let id = UUID()
    let displayName: String
    let stagedURL: URL
}

/// 头像 Data → 跨平台 Image;两端各自的原生图片类型不同,统一到这一处判断。
func platformImage(from data: Data) -> Image? {
    #if os(iOS)
    guard let ui = UIImage(data: data) else { return nil }
    return Image(uiImage: ui)
    #elseif os(macOS)
    guard let ns = NSImage(data: data) else { return nil }
    return Image(nsImage: ns)
    #endif
}
