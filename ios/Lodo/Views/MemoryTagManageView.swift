import SwiftUI
import SwiftData
import LodoCore

/// 标签管理页(记忆 tab → "+" → 管理标签):新建、改名、删除,并显示使用条数。
struct MemoryTagManageView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    /// 只为触发列表随数据变化刷新;标签全集经 MemoryTags 汇总。
    @Query private var items: [MemoryItem]
    @Query private var createdTags: [MemoryTag]

    @State private var newTag = ""
    @State private var renaming: String?
    @State private var renameText = ""

    /// "资产""人脉""AI记录"都是保留标签,各自有专门的入口(记忆页筛选里的
    /// 资产/人脉开关 + 详情页的金额/联系方式字段、auto_memorize 的区分标记),
    /// 都不在这里跟普通标签混着改名/删除——改名会让判定失效,删除会让相应
    /// 条目"失去标记"(其实只是摘了标签,数据还在)。统一引用
    /// `MemoryItem.reservedTagNames`,不要在这里单独维护一份排除列表。
    private var entries: [(name: String, count: Int)] {
        MemoryTags.entries(in: context)
            .filter { !MemoryItem.reservedTagNames.contains($0.name) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("新标签", text: $newTag)
                            .onSubmit(create)
                        Button("创建", action: create)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("AI 整理新收藏时会优先复用这里的标签。")
                }
                if entries.isEmpty {
                    ContentUnavailableView("还没有标签", systemImage: "tag",
                                           description: Text("AI 整理收藏时会自动打标签,也可以在上面手动创建。"))
                } else {
                    Section("全部标签") {
                        ForEach(entries, id: \.name) { entry in
                            Button {
                                renaming = entry.name
                                renameText = entry.name
                            } label: {
                                HStack {
                                    Label(entry.name, systemImage: "tag")
                                    Spacer()
                                    Text("\(entry.count) 条")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    MemoryTags.delete(entry.name, context: context)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("标签")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("重命名标签", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("标签名", text: $renameText)
                Button("确定") {
                    if let old = renaming {
                        MemoryTags.rename(old, to: renameText, context: context)
                    }
                    renaming = nil
                }
                Button("取消", role: .cancel) { renaming = nil }
            } message: {
                Text("所有条目里的这个标签会一起改名。")
            }
        }
    }

    private func create() {
        MemoryTags.create(newTag, context: context)
        newTag = ""
    }
}
