import SwiftUI
import SwiftData
import LodoCore

/// 一张菜单的点菜页:按分类列出每道菜(译名 / 原文 / AI 简介 / 价格),点一下勾选。
/// 选了菜之后底部浮出一条 Liquid Glass 条,点它从下面拉起已选清单
/// (默认半屏、可以上拉到九成),那张是给服务员看的。
struct MenuDetailView: View {
    @Bindable var menu: MemoryItem

    @Environment(\.modelContext) private var context
    @Query private var dishes: [MenuDish]

    @State private var searchText = ""
    @State private var showOrder = false
    @State private var renaming = false
    @State private var draftTitle = ""

    init(menu: MemoryItem) {
        self.menu = menu
        let uuid = menu.uuid
        _dishes = Query(filter: #Predicate<MenuDish> { $0.menuUUID == uuid },
                        sort: \MenuDish.sortIndex)
    }

    private var entries: [MenuDishEntry] { dishes.map(MenuDishEntry.init(from:)) }
    private var selected: [MenuDishEntry] { MenuPlan.selected(entries) }

    private var courses: [MenuCourse] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return MenuPlan.group(entries.filter { $0.matches(query) })
    }

    private func dish(for entry: MenuDishEntry) -> MenuDish? {
        dishes.first { $0.uuid == entry.id }
    }

    var body: some View {
        List {
            if dishes.isEmpty {
                ContentUnavailableView("这张菜单没有菜品", systemImage: "menucard")
            } else if courses.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
            ForEach(courses) { course in
                Section {
                    ForEach(course.dishes) { entry in
                        row(entry)
                    }
                } header: {
                    if course.category.isEmpty {
                        Text("其他")
                    } else {
                        Text(course.category)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: Text("搜索菜品"))
        .navigationTitle(menu.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        draftTitle = menu.title
                        renaming = true
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        withAnimation(.lodoAware(.default)) { MenuStore.clearSelection(menuUUID: menu.uuid, context: context) }
                    } label: {
                        Label("清空已选", systemImage: "xmark.circle")
                    }
                    .disabled(selected.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.lodoAware(.snappy), value: selected.isEmpty)
        .sheet(isPresented: $showOrder) {
            MenuOrderView(menu: menu)
                .presentationDetents([.medium, .fraction(0.9)])
                .presentationDragIndicator(.visible)
        }
        .alert("重命名菜单", isPresented: $renaming) {
            TextField("店名", text: $draftTitle)
            Button("取消", role: .cancel) {}
            Button("保存") {
                let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                menu.title = trimmed
                try? context.save()
            }
        }
        #if DEBUG
        .onAppear {
            // 截图验证用:simctl 点不了悬浮条,启动参数直接把已选清单拉起来。
            if ProcessInfo.processInfo.arguments.contains("--demo-menu-order") {
                showOrder = true
            }
        }
        #endif
    }

    // MARK: - 行

    private func row(_ entry: MenuDishEntry) -> some View {
        Button {
            guard let dish = dish(for: entry) else { return }
            withAnimation(.lodoAware(.snappy)) { MenuStore.toggle(dish, context: context) }
            Haptics.tick()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(entry.selected ? Color.accentColor : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        if let price = entry.price {
                            Text(MenuPlan.priceText(price, currency: menu.menuCurrency))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if entry.showsOriginal {
                        Text(entry.originalName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !entry.intro.isEmpty {
                        Text(entry.intro)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .pressableCard()
        .accessibilityAddTraits(entry.selected ? .isSelected : [])
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                if let dish = dish(for: entry) {
                    MenuStore.deleteDish(dish, context: context)
                }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 底部悬浮条

    /// 已选菜品的悬浮条。玻璃材质走 `glassBackground`(iOS 26 Liquid Glass,
    /// 旧系统回退 material),这属于"系统 chrome 式的独立主操作",符合玻璃的使用口径。
    private var selectionBar: some View {
        Button {
            showOrder = true
        } label: {
            HStack(spacing: 12) {
                Text("\(selected.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("已选菜品")
                        .font(.subheadline.weight(.semibold))
                    Text(selected.map(\.displayName).joined(separator: "、"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let total = MenuPlan.total(selected) {
                    Text(MenuPlan.priceText(total, currency: menu.menuCurrency))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Capsule())
        }
        .pressableCard()
        .glassBackground(Capsule())
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityHint(Text("展开已选菜品,给服务员看"))
    }
}
