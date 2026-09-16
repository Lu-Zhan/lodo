import Foundation
import SwiftData
import LodoCore

/// 菜单的应用层操作:导入整理、菜品勾选、删除。
///
/// 一张菜单 = 一条打了保留标签「菜单」的 `MemoryItem`(照片当附件、整理出的清单
/// + OCR 原文当 `sourceText`,所以记忆搜索和"问 AI"能命中);菜品是挂在它下面
/// 的 `MenuDish`,见那边的注释。字段已经由 `parseMenu` 结构化好了,和
/// `TravelStore`/`saveAsset` 一样**不再经 `memorize()` 整理**,直接落成 ready。
@MainActor
enum MenuStore {

    // MARK: - 查询

    /// 某张菜单的菜品值快照,吃调用方手里的 @Query 结果(视图每帧重算,不再打 fetch)。
    static func entries(for menuUUID: UUID, from dishes: [MenuDish]) -> [MenuDishEntry] {
        MenuPlan.sorted(dishes.filter { $0.menuUUID == menuUUID }.map(MenuDishEntry.init(from:)))
    }

    static func dishes(for menuUUID: UUID, in context: ModelContext) -> [MenuDish] {
        (try? context.fetch(FetchDescriptor<MenuDish>(
            predicate: #Predicate { $0.menuUUID == menuUUID }))) ?? []
    }

    // MARK: - 导入

    /// 文案按应用内语言取(`LK` 表),不用 `String(localized:)`——后者跟的是
    /// 系统语言,不跟设置里的应用内语言开关。
    enum ImportError: Error {
        case noText
        case noDishes

        func message(_ language: AppLanguage) -> String {
            switch self {
            case .noText: return LocalizedStrings.text(.ios_core_menu_no_text, language: language)
            case .noDishes: return LocalizedStrings.text(.ios_core_menu_no_dishes, language: language)
            }
        }
    }

    /// 整理一份菜单并落库,返回新建的菜单条目。`images` 是拍照/截图(端上 OCR,
    /// 不上传图片本身),`text` 是直接贴进来的文字,两者可以同时给(拍了两页再补
    /// 一段手打的),拼起来一起交给 AI。
    /// 顺序是"先 OCR、再 AI、最后才落库"——中途失败什么都不留,不会在记忆库里
    /// 剩下一条 processing 的半成品(和收藏管线"先插条目再整理"不同:那边失败了
    /// 原文还有保留价值,这边一张没整理出菜品的菜单没有)。
    static func importMenu(
        images: [Data], text: String, language: AppLanguage, context: ModelContext
    ) async throws -> MemoryItem {
        var parts: [String] = []
        for data in images {
            let recognized = await ContentExtractor.recognizeMenuText(in: data)
            if !recognized.isEmpty { parts.append(recognized) }
        }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { parts.append(typed) }
        let rawText = parts.joined(separator: "\n\n")
        guard !rawText.isEmpty else { throw ImportError.noText }
        try Task.checkCancellation()

        let parsed = try await DeepSeekClient.parseMenu(
            text: MemorySearch.truncate(rawText), targetLanguage: targetLanguageName(language))
        try Task.checkCancellation()
        guard !parsed.dishes.isEmpty else { throw ImportError.noDishes }

        return save(parsed, rawText: rawText, imageData: images.first,
                    language: language, context: context)
    }

    /// 解析结果落库(单独拆出来:截图演示参数不走网络,直接喂一份样板进来)。
    @discardableResult
    static func save(
        _ parsed: ParsedMenu, rawText: String, imageData: Data?,
        language: AppLanguage, context: ModelContext
    ) -> MemoryItem {
        let item = MemoryItem(
            kind: imageData == nil ? .text : .image,
            title: parsed.restaurant.isEmpty
                ? LocalizedStrings.text(.ios_core_menu_untitled, language: language)
                : parsed.restaurant,
            summary: summary(parsed, language: language),
            tags: [MemoryItem.menuTagName],
            status: .ready,
            menuSourceLanguage: parsed.sourceLanguage.isEmpty ? nil : parsed.sourceLanguage,
            menuTargetLanguage: targetLanguageName(language),
            menuCurrency: parsed.currency)

        // 照片当条目附件存:菜单整理错了的时候,原图是唯一能对照的东西。只存第一张
        // (条目只有一个 relativeFilePath),多张图的文字已经都进了 sourceText。
        if let imageData, let dir = AppGroup.memoryDirURL {
            let target = dir.appending(path: "\(item.uuid.uuidString).jpg")
            if (try? imageData.write(to: target, options: .atomic)) != nil {
                item.relativeFilePath = "Memory/\(target.lastPathComponent)"
                item.originalFileName = target.lastPathComponent
            }
        }

        var entries: [MenuDishEntry] = []
        for (index, dish) in parsed.dishes.enumerated() {
            let model = MenuDish(
                menuUUID: item.uuid, originalName: dish.originalName,
                translatedName: dish.translatedName, intro: dish.intro,
                category: dish.category, price: dish.price, sortIndex: index)
            context.insert(model)
            entries.append(MenuDishEntry(from: model))
        }
        item.sourceText = MemorySearch.truncate(MenuPlan.searchText(
            restaurant: parsed.restaurant, dishes: entries, rawText: rawText))
        context.insert(item)
        MemoryPipeline.finishStructuredSave(item, context: context)
        return item
    }

    /// 喂给 prompt 的目标语言名。prompt 固定中文(不跟应用内语言走),所以这里
    /// 也是中文的语言名;存进 `menuTargetLanguage` 的也是这一份。
    static func targetLanguageName(_ language: AppLanguage) -> String {
        language == .en ? "英文" : "中文"
    }

    /// 条目摘要:记忆列表卡片上那一行,如"日语菜单 · 24 道菜"。
    private static func summary(_ parsed: ParsedMenu, language: AppLanguage) -> String {
        let count = LocalizedStrings.text(.ios_core_menu_dish_count, language: language)
            .replacingOccurrences(of: "{0}", with: "\(parsed.dishes.count)")
        guard !parsed.sourceLanguage.isEmpty else { return count }
        return "\(parsed.sourceLanguage) · \(count)"
    }

    // MARK: - 点菜

    static func toggle(_ dish: MenuDish, context: ModelContext) {
        dish.selected.toggle()
        try? context.save()
    }

    static func clearSelection(menuUUID: UUID, context: ModelContext) {
        for dish in dishes(for: menuUUID, in: context) where dish.selected {
            dish.selected = false
        }
        try? context.save()
    }

    static func deleteDish(_ dish: MenuDish, context: ModelContext) {
        context.delete(dish)
        try? context.save()
    }

    /// 删整张菜单。菜品的清理在 `MemoryPipeline.delete` 里做(从记忆页删也要清),
    /// 这里只是个语义化的入口。
    static func deleteMenu(_ item: MemoryItem, context: ModelContext) {
        MemoryPipeline.delete(item, context: context)
    }
}
