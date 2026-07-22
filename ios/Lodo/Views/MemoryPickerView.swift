import SwiftUI
import SwiftData
import LodoCore

/// AI 助手聊天页"从记忆库选择"用的多选列表:搜索 + 点选,"添加"一次性把
/// 选中的条目回传给调用方(不做真正的导航,选择态只存在这个 sheet 里)。
struct MemoryPickerView: View {
    /// 已经在待发送附件里的 uuid,这里禁用掉避免重复添加同一条。
    let excluding: Set<UUID>
    let onDone: ([MemoryItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var items: [MemoryItem]

    @State private var query = ""
    @State private var selectedUUIDs: Set<UUID> = []
    /// 和记忆列表页一致:资产默认不出现在这个选择器里,避免不小心把私密的
    /// 资产条目当聊天附件发出去;需要时手动打开这个开关才看得到。
    @State private var showAssets = false

    private var filtered: [MemoryItem] {
        items.filter { item in
            !excluding.contains(item.uuid)
                && (showAssets ? item.isAsset : !item.isAsset)
                && item.matches(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered, id: \.uuid) { item in
                Button {
                    toggle(item.uuid)
                } label: {
                    row(for: item)
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if items.isEmpty {
                    ContentUnavailableView(
                        "还没有收藏", systemImage: "sparkles.rectangle.stack",
                        description: Text("先去「记忆」tab 收藏一些内容。"))
                } else if filtered.isEmpty {
                    ContentUnavailableView("没有匹配的收藏", systemImage: "magnifyingglass")
                }
            }
            .searchable(text: $query, prompt: "搜索记忆")
            .navigationTitle("选择记忆")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if items.contains(where: { $0.isAsset }) {
                    ToolbarItem(placement: .primaryAction) {
                        Toggle("显示资产", systemImage: "creditcard", isOn: $showAssets)
                            .toggleStyle(.button)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selectedUUIDs.isEmpty ? "添加" : "添加(\(selectedUUIDs.count))") {
                        onDone(items.filter { selectedUUIDs.contains($0.uuid) })
                        dismiss()
                    }
                    .disabled(selectedUUIDs.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func row(for item: MemoryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? (item.originalFileName ?? "正在整理…") : item.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: selectedUUIDs.contains(item.uuid) ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selectedUUIDs.contains(item.uuid) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .font(.title3)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func toggle(_ uuid: UUID) {
        if selectedUUIDs.contains(uuid) {
            selectedUUIDs.remove(uuid)
        } else {
            selectedUUIDs.insert(uuid)
        }
    }
}
