import SwiftUI
import SwiftData
import LodoCore

/// "菜单"页:第七个平级页面。每一行是一张整理过的菜单(打了「菜单」保留标签的
/// 记忆条目),点进去是菜品清单,勾选后给服务员看。
struct MenuListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.sidebarChrome) private var sidebarChrome
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @Query(sort: [SortDescriptor(\MemoryItem.createdAt, order: .reverse)])
    private var memoryItems: [MemoryItem]
    @Query private var dishes: [MenuDish]

    @State private var path: [MemoryItem] = []
    @State private var importing = false
    @State private var pendingDelete: MemoryItem?

    private var menus: [MemoryItem] { memoryItems.filter(\.isMenu) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if menus.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("还没有菜单", systemImage: "menucard")
                        } description: {
                            Text("拍一张菜单或导入截图,AI 会整理出每道菜、翻译外文并补上简介,选好了直接给服务员看。")
                        } actions: {
                            Button("新建菜单") { importing = true }
                                .glassProminentButton()
                        }
                    }
                }
                ForEach(menus) { menu in
                    NavigationLink(value: menu) {
                        row(menu)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = menu
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("菜单")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sidebarToolbarButton()
            .floatingAddAction(isVisible: path.isEmpty && !(sidebarChrome?.hidesChrome ?? false)) {
                Button { importing = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建菜单")
            }
            .askBar(isVisible: path.isEmpty && !(sidebarChrome?.hidesChrome ?? false))
            .navigationDestination(for: MemoryItem.self) { menu in
                MenuDetailView(menu: menu)
            }
            .sheet(isPresented: $importing) {
                MenuImportView { path = [$0] }
            }
            .alert("删除这张菜单?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let menu = pendingDelete {
                        MenuStore.deleteMenu(menu, context: context)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("菜单照片和整理出来的菜品会一起删掉。")
            }
            #if DEBUG
            .onAppear(perform: applyDemoArgumentsIfNeeded)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func row(_ menu: MemoryItem) -> some View {
        let all = dishes.filter { $0.menuUUID == menu.uuid }
        let picked = all.filter(\.selected).count
        return VStack(alignment: .leading, spacing: 3) {
            Text(menu.title)
                .font(.body.weight(.medium))
            HStack(spacing: 4) {
                if let source = menu.menuSourceLanguage {
                    Text(source)
                    Text("·")
                }
                Text("\(all.count) 道菜")
                if picked > 0 {
                    Text("·")
                    Text("已选 \(picked) 道")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(menu.createdAt, format: .dateTime.month().day().hour().minute())
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    #if DEBUG
    /// 截图验证用:simctl 拍不了照、也点不了表单,启动参数直接塞一张样板菜单。
    private func applyDemoArgumentsIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo-menu") else { return }
        let menu = menus.first ?? seedDemoMenu()
        // 勾选每次都摆一遍:第二次启动时库里已经有菜单了,不能跟着种子一起挡掉。
        if args.contains("--demo-menu-order") {
            for dish in MenuStore.dishes(for: menu.uuid, in: context) {
                dish.selected = [0, 3, 5, 7].contains(dish.sortIndex)
            }
            try? context.save()
        }
        if args.contains("--demo-menu-detail") || args.contains("--demo-menu-order") {
            path = [menu]
        }
    }

    private func seedDemoMenu() -> MemoryItem {
        let dishes: [ParsedMenuDish] = [
            .init(originalName: "枝豆", translatedName: "盐水毛豆",
                  intro: "带荚煮熟的嫩毛豆撒海盐,居酒屋最常见的下酒小菜。",
                  category: "前菜", price: 380),
            .init(originalName: "揚げ出し豆腐", translatedName: "炸豆腐浸汁",
                  intro: "裹薄粉炸过的嫩豆腐,浇上鲣鱼高汤,配萝卜泥和葱花。",
                  category: "前菜", price: 520),
            .init(originalName: "月見とろろ", translatedName: "山药泥配生蛋黄",
                  intro: "磨成泥的山药上放一颗生蛋黄,像月亮,口感黏滑,拌着吃。",
                  category: "前菜", price: 480),
            .init(originalName: "鶏の唐揚げ", translatedName: "日式炸鸡块",
                  intro: "酱油姜蒜腌过的鸡腿肉裹粉油炸,外脆里嫩。",
                  category: "主菜", price: 780),
            .init(originalName: "鯖の塩焼き", translatedName: "盐烤青花鱼",
                  intro: "半条青花鱼抹盐炭烤,油脂丰富,配柠檬和萝卜泥。",
                  category: "主菜", price: 950),
            .init(originalName: "親子丼", translatedName: "鸡肉滑蛋盖饭",
                  intro: "鸡肉和洋葱用甜咸酱汁煮,淋半熟蛋液盖在米饭上。",
                  category: "饭类", price: 1100),
            .init(originalName: "抹茶アイス", translatedName: "抹茶冰淇淋",
                  intro: "宇治抹茶口味的冰淇淋,微苦回甘。",
                  category: "甜点", price: 420),
            .init(originalName: "生ビール", translatedName: "扎啤",
                  intro: "生啤酒,中杯。",
                  category: "饮品", price: 600),
        ]
        let parsed = ParsedMenu(restaurant: "居酒屋 とりまる", sourceLanguage: "日语",
                                currency: "JPY", dishes: dishes)
        let language = AppLanguage(rawValue: languageRaw) ?? .zhHans
        return MenuStore.save(parsed, rawText: dishes.map(\.originalName)
            .joined(separator: "\n"), imageData: nil, language: language, context: context)
    }
    #endif
}
