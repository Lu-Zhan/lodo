import SwiftUI
import UniformTypeIdentifiers
import LodoCore

/// 单个内置 skill/agent.md 的查看与编辑;保存直接改变发给 AI 的实际 prompt。
struct AgentSkillEditView: View {
    let id: AgentSkillID

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var confirmReset = false

    init(id: AgentSkillID) {
        self.id = id
        _text = State(initialValue: AgentSkillStore.content(for: id))
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.body.monospaced())
            .padding(.horizontal, 8)
            .navigationTitle(id.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        AgentSkillStore.save(text, for: id)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    // 分享的是编辑框里当前的文本,不必先保存
                    SkillShareLink(file: AgentSkillFile(
                        name: id.title, description: id.subtitle,
                        group: id.group.title, version: 1,
                        body: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("重置", role: .destructive) {
                        confirmReset = true
                    }
                    .disabled(!AgentSkillStore.isCustomized(id))
                }
            }
            .confirmationDialog("确定恢复默认内容吗?", isPresented: $confirmReset,
                                titleVisibility: .visible) {
                Button("重置", role: .destructive) {
                    AgentSkillStore.reset(id)
                    text = AgentSkillStore.defaultContent(for: id)
                }
            }
    }
}

/// 分享按钮:把 skill 写成 `<name>.md` 临时文件再交给系统分享面板,
/// 对方收到的是一个能直接导入的文件,不是一段粘贴文本。
struct SkillShareLink: View {
    let file: AgentSkillFile

    var body: some View {
        if let url = exportURL() {
            ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
        }
    }

    private func exportURL() -> URL? {
        let safeName = file.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(safeName).md")
        do {
            try Data(file.render().utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - 设置页里的 skill 分组

/// AI 设置里的 skill 区域:按分组列出内置 skill(带启用开关),最后是「我的 skills」
/// (导入/新建)和调试入口。放在 Form 里,直接产出多个 Section。
struct AgentSkillsSections: View {
    @State private var customSkills = AgentSkillStore.customSkills()
    /// Toggle 读的是 UserDefaults,SwiftUI 不知道它变了——用这个计数触发重绘。
    @State private var refresh = 0
    @State private var showImporter = false
    @State private var importPlan: AgentSkillImportPlan?
    @State private var importError: String?
    @State private var newSkill = false

    var body: some View {
        ForEach(AgentSkillGroup.allCases.filter { $0 != .custom }) { group in
            Section {
                ForEach(AgentSkillID.allCases.filter { $0.group == group }) { id in
                    builtinRow(id)
                }
            } header: {
                Text(LocalizedStringKey(group.title))
            } footer: {
                if group == .system {
                    Text("agent.md 是总则,其余是可分别编辑、可停用的技能;编辑会直接改变发给 AI 的指令,重置可恢复默认。")
                }
            }
        }

        Section {
            ForEach(customSkills) { skill in
                NavigationLink {
                    CustomSkillEditView(slug: skill.slug)
                } label: {
                    customRow(skill)
                }
            }
            Button("从文件导入…") { showImporter = true }
            Button("新建 skill") { newSkill = true }
            NavigationLink("查看最终 Prompt") { AgentPromptPreviewView() }
        } header: {
            Text(LocalizedStringKey(AgentSkillGroup.custom.title))
        } footer: {
            Text("导入别人分享的 .md 文件即可加载外部 skill。外部 skill 默认停用,启用后 AI 只在需要时按名字取回内容。")
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.importTypes) { result in
            handleImport(result)
        }
        .sheet(item: $importPlan.asIdentifiable) { wrapper in
            AgentSkillImportSheet(plan: wrapper.plan) {
                AgentSkillStore.apply(wrapper.plan)
                importPlan = nil
                reload()
            } onCancel: {
                importPlan = nil
            }
        }
        .sheet(isPresented: $newSkill, onDismiss: reload) {
            NavigationStack { CustomSkillEditView(slug: nil) }
        }
        .alert("无法导入", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onAppear(perform: reload)
    }

    private static let importTypes: [UTType] =
        [.plainText, UTType(filenameExtension: "md")].compactMap { $0 }

    private func reload() {
        customSkills = AgentSkillStore.customSkills()
        refresh += 1
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                importError = "读不出文件内容(需要 UTF-8 文本)"
                return
            }
            switch AgentSkillStore.planImport(text) {
            case .success(let plan): importPlan = plan
            case .failure(let error): importError = error.message
            }
        }
    }

    private func builtinRow(_ id: AgentSkillID) -> some View {
        HStack {
            NavigationLink {
                AgentSkillEditView(id: id)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(id.title)
                        if AgentSkillStore.isCustomized(id) { customizedBadge }
                    }
                    Text(id.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if id.isTogglable {
                Toggle("启用", isOn: Binding(
                    get: { AgentSkillStore.isEnabled(id) },
                    set: { AgentSkillStore.setEnabled($0, for: id); refresh += 1 }))
                    .labelsHidden()
            }
        }
    }

    private func customRow(_ skill: AgentCustomSkill) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(skill.file.name)
                Text(skill.file.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("启用", isOn: Binding(
                get: { AgentSkillStore.isCustomEnabled(slug: skill.slug) },
                set: { AgentSkillStore.setCustomEnabled($0, slug: skill.slug); refresh += 1 }))
                .labelsHidden()
        }
    }

    private var customizedBadge: some View {
        Text("已自定义")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}

/// `.sheet(item:)` 要 Identifiable,而 `AgentSkillImportPlan` 是 LodoCore 里的纯值,
/// 这里包一层,不给核心包加 UI 需要的协议。
private struct IdentifiablePlan: Identifiable {
    let id = UUID()
    let plan: AgentSkillImportPlan
}

private extension Binding where Value == AgentSkillImportPlan? {
    var asIdentifiable: Binding<IdentifiablePlan?> {
        Binding<IdentifiablePlan?>(
            get: { wrappedValue.map { IdentifiablePlan(plan: $0) } },
            set: { wrappedValue = $0?.plan })
    }
}

// MARK: - 导入确认

/// 导入前先把完整内容摆出来:外部 skill 是别人写的文本,会进 prompt,要让用户先看到。
struct AgentSkillImportSheet: View {
    let plan: AgentSkillImportPlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var file: AgentSkillFile {
        switch plan {
        case .newCustom(let file, _, _): return file
        case .overrideBuiltin(_, let file): return file
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("名称", value: file.name)
                    LabeledContent("描述", value: file.description)
                } footer: {
                    switch plan {
                    case .newCustom(_, _, let replacing):
                        Text(replacing
                             ? "已有同名的外部 skill,导入会覆盖它的内容(启用状态不变)。"
                             : "这是一个外部 skill,导入后默认停用。请先看完下面的内容,确认可信再启用。")
                    case .overrideBuiltin(let id, _):
                        Text("名称与内置 skill「\(id.title)」相同,导入会覆盖它当前的文本(可在编辑页重置)。")
                    }
                }
                Section("正文") {
                    Text(file.body)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("导入 skill")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) { Button("导入", action: onConfirm) }
            }
        }
    }
}

// MARK: - 用户 skill 编辑

/// 外部/自建 skill 的编辑:名称、描述(进 prompt 目录,决定 AI 何时加载)、正文。
/// slug 为 nil = 新建。
struct CustomSkillEditView: View {
    let slug: String?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var descriptionText = ""
    @State private var bodyText = ""
    @State private var confirmDelete = false
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
                TextField("描述", text: $descriptionText, axis: .vertical)
            } footer: {
                Text("描述要写清楚「什么时候该用」——AI 只看到名称和描述,靠它决定要不要加载正文。")
            }
            Section("正文") {
                TextEditor(text: $bodyText)
                    .font(.body.monospaced())
                    .frame(minHeight: 240)
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
            if slug != nil {
                Section {
                    Button("删除", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(slug == nil ? "新建 skill" : name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("保存", action: save) }
            if slug != nil {
                ToolbarItem(placement: .secondaryAction) {
                    SkillShareLink(file: AgentSkillFile(
                        name: name, description: descriptionText, body: bodyText))
                }
            }
            if slug == nil {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .confirmationDialog("确定删除这个 skill 吗?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let slug { AgentSkillStore.deleteCustom(slug: slug) }
                dismiss()
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let slug, name.isEmpty,
              let skill = AgentSkillStore.customSkills().first(where: { $0.slug == slug }) else { return }
        name = skill.file.name
        descriptionText = skill.file.description
        bodyText = skill.file.body
    }

    private func save() {
        // 走和导入同一套校验,长度上限一致
        let file = AgentSkillFile(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                  description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
                                  body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines))
        switch AgentSkillFile.parse(file.render()) {
        case .failure(let error):
            errorText = error.message
        case .success:
            let newSlug = slug ?? AgentSkillStore.slug(for: file.name)
            // 新建时不能顶掉别的 skill(或内置)
            if slug == nil,
               AgentSkillStore.customSkills().contains(where: { $0.slug == newSlug })
                || AgentSkillID.allCases.contains(where: { $0.title == file.name }) {
                errorText = "已经有同名的 skill 了"
                return
            }
            AgentSkillStore.saveCustom(file, slug: newSlug)
            dismiss()
        }
    }
}

// MARK: - 调试:最终 Prompt

/// 用当前的 skill 开关渲染 `command` 实际发给 AI 的 system prompt,方便调试 skill 写得对不对。
/// 能力开关按"全部具备"演示(真实对话里还取决于是否配了 Tavily key、有没有旅行等)。
struct AgentPromptPreviewView: View {
    private let blocks: [(title: String, enabled: Bool, count: Int)] = AgentSkillID.allCases.map {
        ($0.title, AgentSkillStore.isEnabled($0), AgentSkillStore.content(for: $0).count)
    }
    private let prompt = DeepSeekClient.commandSystemPrompt(
        tasks: [],
        capabilities: .init(memory: true, webSearch: true, health: true, travel: true, tripPlan: true)
    ).system

    var body: some View {
        List {
            Section {
                ForEach(blocks, id: \.title) { block in
                    HStack {
                        Text(block.title)
                        Spacer()
                        Text(block.enabled ? "\(block.count) 字" : "已停用")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            } header: {
                Text("各 skill 字数")
            } footer: {
                Text("以下按「全部能力都可用、没有待办、没有历史」渲染;实际请求里还会随配置增减。")
            }
            Section("最近一次对话加载的外部 skill") {
                let loaded = AgentSkillLoadLog.shared.lastTurn
                if loaded.isEmpty {
                    Text("没有加载过").foregroundStyle(.secondary)
                } else {
                    ForEach(loaded, id: \.self) { Text($0) }
                }
            }
            Section("完整 system prompt(共 \(prompt.count) 字)") {
                Text(prompt)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("最终 Prompt")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
