import SwiftUI
import LodoCore

/// 侧栏和设置页共用同一份存储与旧资产开关的兼容逻辑。
@propertyWrapper
struct SidebarLayoutStorage: DynamicProperty {
    @AppStorage(AppSettings.sidebarLayoutKey) private var raw = ""
    @AppStorage(AppSettings.assetsInSidebarKey) private var assetsInSidebar = true

    var wrappedValue: SidebarLayout {
        get {
            SidebarLayout.decode(raw, defaultOrder: AppSection.pages.map(\.rawValue),
                                 initiallyHidden: assetsInSidebar ? [] : [AppSection.assets.rawValue])
        }
        nonmutating set {
            raw = newValue.encoded()
            // 新布局优先;同步旧 key,避免其他旧入口读到相反的资产偏好。
            assetsInSidebar = newValue.visibleIDs.contains(AppSection.assets.rawValue)
        }
    }
}

struct SidebarSettingsView: View {
    @SidebarLayoutStorage private var layout

    var body: some View {
        List {
            Section {
                ForEach(layout.items) { item in
                    if let page = AppSection(rawValue: item.id) {
                        Toggle(isOn: visibility(for: item.id)) {
                            Label(page.title, systemImage: page.systemImage)
                        }
                    }
                }
                .onMove { source, destination in
                    var updated = layout
                    updated.move(fromOffsets: source, toOffset: destination)
                    layout = updated
                }
            } footer: {
                Text("开关控制侧边栏显示的页面,拖动右侧把手调整顺序。")
            }
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .pageTitle("侧边栏自定义")
    }

    private func visibility(for id: String) -> Binding<Bool> {
        Binding(
            get: { layout.items.first(where: { $0.id == id })?.isVisible ?? false },
            set: { visible in
                var updated = layout
                updated.setVisible(visible, for: id)
                layout = updated
            })
    }
}
