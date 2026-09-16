import SwiftUI
import SwiftData
import LodoCore

/// 已选菜品清单,点菜页底部悬浮条拉起来的那张(默认半屏,可上拉到九成)。
/// 这张是**给服务员看的**:每道菜原文名放大放在最上面(服务员认的是菜单上印的
/// 那个名字),译名小字跟在下面给自己对照。
struct MenuOrderView: View {
    let menu: MemoryItem

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var dishes: [MenuDish]

    init(menu: MemoryItem) {
        self.menu = menu
        let uuid = menu.uuid
        _dishes = Query(filter: #Predicate<MenuDish> { $0.menuUUID == uuid && $0.selected == true },
                        sort: \MenuDish.sortIndex)
    }

    private var entries: [MenuDishEntry] { dishes.map(MenuDishEntry.init(from:)) }

    var body: some View {
        NavigationStack {
            List {
                if dishes.isEmpty {
                    ContentUnavailableView("还没有选菜", systemImage: "fork.knife",
                                           description: Text("在菜单里点一下菜品就能选上。"))
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(dishes) { dish in
                        row(dish)
                    }
                } footer: {
                    if !dishes.isEmpty {
                        Text("左滑可以把这道菜从清单里去掉。")
                    }
                }
                if let total = MenuPlan.total(entries) {
                    Section {
                        HStack {
                            Text("合计")
                            Spacer()
                            Text(MenuPlan.priceText(total, currency: menu.menuCurrency))
                                .font(.headline.monospacedDigit())
                        }
                    } footer: {
                        let unpriced = MenuPlan.unpricedCount(entries)
                        if unpriced > 0 {
                            Text("有 \(unpriced) 道菜没标价,没算进合计。")
                        }
                    }
                }
            }
            .navigationTitle("已选菜品")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !dishes.isEmpty {
                        ShareLink(item: MenuPlan.orderText(entries, currency: menu.menuCurrency)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("分享清单")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("完成") { dismiss() }
                }
            }
        }
    }

    private func row(_ dish: MenuDish) -> some View {
        let entry = MenuDishEntry(from: dish)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 原文放大:这一行是指给服务员看的。
                Text(entry.originalName.isEmpty ? entry.displayName : entry.originalName)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                if entry.showsOriginal {
                    Text(entry.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let price = entry.price {
                Text(MenuPlan.priceText(price, currency: menu.menuCurrency))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                withAnimation { MenuStore.toggle(dish, context: context) }
            } label: {
                Label("去掉", systemImage: "minus.circle")
            }
        }
    }
}
