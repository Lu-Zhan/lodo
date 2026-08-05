import SwiftUI
import SwiftData
import LodoCore

/// 批量导出:原生 List + 逐行 Button 切换勾选(和 AgentAskCard 的选项行同一套
/// 写法),不用 List(selection:) + editMode 那一套——这里只需要"点一下切换
/// 勾选"的简单交互,不需要系统编辑模式的其余行为(滑动删除等)。
/// 仅 iOS,理由同 ContactPickerView/ContactExportView:通讯录导入/导出这套
/// 入口整体只做 iOS。调用方(MemoryListView)负责先请求好通讯录权限再弹这个页。
#if os(iOS)
struct ContactExportPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\MemoryItem.title)]) private var allItems: [MemoryItem]
    @State private var selected: Set<UUID> = []
    @State private var resultMessage: String?

    private var contacts: [MemoryItem] { allItems.filter { $0.isContact } }

    var body: some View {
        NavigationStack {
            List {
                if contacts.isEmpty {
                    Text("还没有人脉。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(contacts) { contact in
                        Button {
                            toggle(contact.uuid)
                        } label: {
                            HStack {
                                Label(
                                    contact.title.isEmpty ? "(未命名)" : contact.title,
                                    systemImage: "person.crop.circle")
                                Spacer()
                                if selected.contains(contact.uuid) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("批量导出到通讯录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导出(\(selected.count))") { export() }
                        .disabled(selected.isEmpty)
                }
            }
            .alert("导出完成", isPresented: Binding(
                get: { resultMessage != nil },
                set: { if !$0 { resultMessage = nil; dismiss() } }
            )) {
                Button("好") { resultMessage = nil; dismiss() }
            } message: {
                Text(resultMessage ?? "")
            }
        }
    }

    private func toggle(_ uuid: UUID) {
        if selected.contains(uuid) { selected.remove(uuid) } else { selected.insert(uuid) }
    }

    private func export() {
        let items = contacts.filter { selected.contains($0.uuid) }
        let result = ContactsBridge.exportContacts(items)
        var message = "已导出 \(result.exported) 位"
        if result.skipped > 0 { message += ",跳过 \(result.skipped) 位重复" }
        if result.failed > 0 { message += ",\(result.failed) 位失败" }
        resultMessage = message
    }
}
#endif
