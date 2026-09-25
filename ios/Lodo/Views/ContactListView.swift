import SwiftUI
import SwiftData
import LodoCore

/// "人脉"页:第八个平级页面。一行是一位人脉,点进去是 ContactDetailView。
/// 这一页自己没有搜索框(同记忆页):底下常驻着「问问 AI」那条,找人说一句就行。
/// 人脉条目本身仍是打了「人脉」保留标签的记忆条目(和旅行/菜单/健康同一套路子:
/// 数据长在记忆库上、入口独立成页),所以订单附件、问 AI、记忆搜索都照旧能命中;
/// 独立出来是因为它有自己的一整套操作(关系图谱、通讯录导入导出),
/// 挂在记忆页的一个筛选态下面既找不着、也把记忆页的工具栏撑变形了。
struct ContactListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.sidebarChrome) private var sidebarChrome
    @Query(sort: [SortDescriptor(\MemoryItem.title)]) private var allItems: [MemoryItem]
    @Query private var edges: [ContactRelationship]

    @State private var path: [MemoryItem] = []
    @State private var showCompose = false
    @State private var showGraph = false
    @State private var pendingDelete: MemoryItem?
    #if os(iOS)
    @State private var showImportConfirm = false
    @State private var showPicker = false
    @State private var showExportPicker = false
    @State private var permissionDenied = false
    @State private var importResultMessage: String?
    #endif

    private var contacts: [MemoryItem] { allItems.filter(\.isContact) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if contacts.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("还没有人脉", systemImage: "person.crop.circle")
                        } description: {
                            Text("记下姓名、联系方式和喜好,再把人和人之间的关系连起来,可以看关系图谱。")
                        } actions: {
                            Button("记一位人脉") { showCompose = true }
                                .glassProminentButton()
                        }
                    }
                } else {
                    ForEach(contacts) { contact in
                        NavigationLink(value: contact) {
                            row(contact)
                        }
                        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                        // 全部收在 trailing:向右拖归抽屉(见 TaskRowView 同款注释)。
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = contact
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("人脉")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: MemoryItem.self) { contact in
                ContactDetailView(item: contact)
            }
            .toolbar {
                if !(sidebarChrome?.hidesChrome ?? false), !contacts.isEmpty {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            showGraph = true
                        } label: {
                            Label("关系图谱", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .navigation) {
                        Button {
                            Task { await beginExport() }
                        } label: {
                            Label("批量导出到通讯录", systemImage: "square.and.arrow.up")
                        }
                    }
                    #endif
                }
            }
            .sidebarToolbarButton()
            .floatingAddAction(isVisible: path.isEmpty && !(sidebarChrome?.hidesChrome ?? false)) {
                Menu {
                    Button("记一位人脉", systemImage: "person.crop.circle.badge.plus") {
                        showCompose = true
                    }
                    #if os(iOS)
                    Divider()
                    Button("从通讯录选择导入", systemImage: "person.crop.circle.badge.checkmark") {
                        // 系统选择器只把选中的联系人交给 app,无需读取通讯录权限。
                        showPicker = true
                    }
                    Button("从通讯录批量导入", systemImage: "person.2.badge.plus") {
                        showImportConfirm = true
                    }
                    #endif
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("记一位人脉")
            }
            .askBar(isVisible: path.isEmpty && !(sidebarChrome?.hidesChrome ?? false))
            .sheet(isPresented: $showCompose) {
                ContactComposeView()
            }
            .sheet(isPresented: $showGraph) {
                NavigationStack {
                    ContactGraphView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("关闭") { showGraph = false }
                            }
                        }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showPicker) {
                ContactPickerView(
                    onPicked: { cnContacts in
                        showPicker = false
                        importResultMessage = importSummary(
                            ContactsBridge.importContacts(cnContacts, context: context))
                    },
                    onCancel: { showPicker = false })
            }
            .sheet(isPresented: $showExportPicker) {
                ContactExportPickerView()
            }
            .confirmationDialog(
                "确定要导入通讯录中的全部联系人吗?", isPresented: $showImportConfirm,
                titleVisibility: .visible
            ) {
                Button("导入") { Task { await beginBulkImport() } }
            } message: {
                Text("已存在的人脉(按手机号/邮箱匹配)会自动跳过,不会重复导入。")
            }
            .alert("导入完成", isPresented: Binding(
                get: { importResultMessage != nil },
                set: { if !$0 { importResultMessage = nil } }
            )) {
                Button("好") { importResultMessage = nil }
            } message: {
                Text(importResultMessage ?? "")
            }
            .alert("无法访问通讯录", isPresented: $permissionDenied) {
                Button("好", role: .cancel) {}
            } message: {
                Text("请在系统设置 → 隐私与安全性 → 通讯录 里允许 lodo 访问。")
            }
            #endif
            .confirmationDialog(
                "删除这位人脉?头像与附件会一并删除,已建立的关系也会一起消失。",
                isPresented: Binding(
                    get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
                ), titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let contact = pendingDelete {
                        Haptics.warning()
                        MemoryPipeline.delete(contact, context: context)
                    }
                    pendingDelete = nil
                }
            }
            #if DEBUG
            .onAppear(perform: applyDemoArgumentsIfNeeded)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    // MARK: - 行

    /// 头像(没有就退回系统人像图标)+ 姓名 + 一行附注:昵称、联系方式、关系条数。
    /// 关系条数是这一页独有的信息——人脉页存在的理由就是那张关系网,
    /// 有几条线在列表里就该看得见。
    private func row(_ contact: MemoryItem) -> some View {
        HStack(spacing: 10) {
            avatar(contact)
            VStack(alignment: .leading, spacing: 3) {
                Text(contact.title.isEmpty ? "(未命名)" : contact.title)
                    .font(.body.weight(.medium))
                if !subtitle(contact).isEmpty {
                    Text(subtitle(contact))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func avatar(_ contact: MemoryItem) -> some View {
        Group {
            if let url = MemoryPipeline.contactAvatarURL(of: contact),
               let data = try? Data(contentsOf: url),
               let image = platformImage(from: data) {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
    }

    private func subtitle(_ contact: MemoryItem) -> String {
        var parts: [String] = []
        if let nickname = contact.contactNickname, !nickname.isEmpty { parts.append(nickname) }
        if let phone = contact.contactPhone, !phone.isEmpty {
            parts.append(phone)
        } else if let email = contact.contactEmail, !email.isEmpty {
            parts.append(email)
        }
        let count = edges.filter { $0.involves(contact.uuid) }.count
        if count > 0 { parts.append("\(count) 条关系") }
        return parts.joined(separator: " · ")
    }

    #if os(iOS)
    // MARK: - 通讯录批量导入/导出(权限门控,选择导入的系统选择器不需要走这里)

    private func beginBulkImport() async {
        guard await ContactsBridge.requestAccess() == .granted else {
            permissionDenied = true
            return
        }
        importResultMessage = importSummary(
            ContactsBridge.importContacts(ContactsBridge.fetchAllContacts(), context: context))
    }

    private func beginExport() async {
        guard await ContactsBridge.requestAccess() == .granted else {
            permissionDenied = true
            return
        }
        showExportPicker = true
    }

    private func importSummary(_ result: (imported: Int, skipped: Int)) -> String {
        var message = "已导入 \(result.imported) 位"
        if result.skipped > 0 { message += ",跳过 \(result.skipped) 位重复" }
        return message
    }
    #endif

    #if DEBUG
    /// 截图验证用:simctl 点不了 List 行,启动参数直接把各个态摆出来。
    /// 样板人脉原来是跟着记忆页的 --demo-seed-memory 一起塞的,人脉独立成页后
    /// 归这里种(记忆页那份只留非人脉条目)。
    private func applyDemoArgumentsIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains(where: { $0.hasPrefix("--demo-contact") }) else { return }
        if contacts.isEmpty { seedDemoContacts() }
        if args.contains("--demo-contact-compose") { showCompose = true }
        if args.contains("--demo-contact-graph") { showGraph = true }
        if args.contains("--demo-contact-detail"), let first = contacts.first {
            path = [first]
        }
        #if os(iOS)
        // 批量导出选择页不需要通讯录权限就能看列表(权限只在真正点"导出"时才
        // 用到),跳过 beginExport() 的权限请求直接弹出。
        if args.contains("--demo-contact-export-picker") { showExportPicker = true }
        #endif
    }

    private func seedDemoContacts() {
        let zhang = MemoryItem(
            kind: .text, title: "张三", summary: "前同事,喜欢爬山。",
            tags: [MemoryItem.contactTagName], sourceText: "前同事,喜欢爬山。咖啡",
            status: .ready, contactNickname: "小张", contactPhone: "13800000000",
            contactPreferences: "咖啡")
        let li = MemoryItem(
            kind: .text, title: "李四", summary: "大学同学。",
            tags: [MemoryItem.contactTagName], sourceText: "大学同学。",
            status: .ready, contactEmail: "li4@example.com")
        context.insert(zhang)
        context.insert(li)
        context.insert(ContactRelationship(
            memoryUUIDA: zhang.uuid, memoryUUIDB: li.uuid, label: "同事"))
        try? context.save()
    }
    #endif
}
