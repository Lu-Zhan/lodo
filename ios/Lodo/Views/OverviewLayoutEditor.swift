import SwiftUI
import LodoCore

/// 总览页右上角「编辑布局」:拖动排序、开关显示、选大小卡。全是系统 List 的
/// 编辑态控件(拖动手柄、Toggle、菜单 Picker),不自己做抖动编辑那套。
/// 改动即时生效(背后的总览页跟着变),「完成」只是收起。
struct OverviewLayoutEditor: View {
    @Binding var layout: OverviewLayout
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lodoAccent) private var accent

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($layout.items) { $item in
                        row($item)
                    }
                    .onMove { source, destination in
                        layout.move(fromOffsets: source, toOffset: destination)
                    }
                } footer: {
                    Text("拖动右侧手柄调整顺序。两张相邻的小卡会并排显示。")
                }
                Section {
                    Button("恢复默认布局") {
                        withAnimation(.lodoAware(.snappy)) { layout = .default }
                    }
                    .disabled(layout == .default)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("编辑布局")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        // sheet 是独立呈现宿主,不继承根上的 tint(同 SettingsView)。
        .tint(accent.accent)
    }

    private func row(_ item: Binding<OverviewWidgetItem>) -> some View {
        let kind = item.wrappedValue.kind
        return HStack(spacing: 10) {
            Label(LocalizedStringKey(kind.title), systemImage: kind.systemImage)
                .foregroundStyle(item.wrappedValue.isVisible ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if kind.allowedSizes.count > 1 {
                Picker("大小", selection: item.size) {
                    Text("小").tag(OverviewWidgetSize.small)
                    Text("大").tag(OverviewWidgetSize.large)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!item.wrappedValue.isVisible)
            }
            Toggle(LocalizedStringKey(kind.title), isOn: item.isVisible)
                .labelsHidden()
        }
    }
}
