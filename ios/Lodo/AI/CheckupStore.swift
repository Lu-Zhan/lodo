import Foundation
import CoreText
import SwiftData
import LodoCore

/// 体检报告的应用层操作:导入整理、改报告/条目、删除、分享,以及喂给 AI 的摘要。
///
/// 一份报告 = 一条打了保留标签「体检报告」的 `MemoryItem`(原文件当附件,整理结果 +
/// OCR 原文当 `sourceText`,记忆搜索和"问 AI"能命中);一项指标/综合建议是挂在它下面
/// 的 `CheckupEntry`。**本人的报告**额外打「健康」标签,并且只有本人的数据会进 AI
/// 健康分析——家人的档案只记录、只分享,判据统一是 `profileUUID == nil`。
@MainActor
enum CheckupStore {

    /// sourceText 里整理结果和 OCR 原文之间的分隔:改了条目重写整理结果时,靠它把
    /// 原文那一半留下来(原文只在导入那一刻拿得到)。
    private static let rawMarker = "\n\n——报告原文——\n"

    // MARK: - 查询

    /// 某个人的报告(按体检日期从近到远),吃调用方手里的 @Query 结果。
    static func reports(of profileID: UUID?, in items: [MemoryItem]) -> [MemoryItem] {
        items.filter { $0.isCheckup && $0.checkupProfileUUID == profileID }
            .sorted { date(of: $0) > date(of: $1) }
    }

    static func date(of report: MemoryItem) -> Date { report.checkupDate ?? report.createdAt }

    static func value(of report: MemoryItem) -> CheckupReportValue {
        CheckupReportValue(id: report.uuid, title: report.title, date: date(of: report),
                           institution: report.checkupInstitution ?? "")
    }

    static func entries(of reportID: UUID, in entries: [CheckupEntry]) -> [CheckupEntryValue] {
        entries.filter { $0.reportUUID == reportID }.map(CheckupEntryValue.init(from:))
    }

    static func entries(ofProfile profileID: UUID?, in entries: [CheckupEntry]) -> [CheckupEntryValue] {
        entries.filter { $0.profileUUID == profileID }.map(CheckupEntryValue.init(from:))
    }

    static func entryModels(of reportID: UUID, in context: ModelContext) -> [CheckupEntry] {
        (try? context.fetch(FetchDescriptor<CheckupEntry>(
            predicate: #Predicate { $0.reportUUID == reportID }))) ?? []
    }

    /// 报告的全部原文件(第一页 + 其余页),缺失的跳过。
    static func fileURLs(of report: MemoryItem) -> [URL] {
        [MemoryPipeline.fileURL(of: report)].compactMap { $0 }
            + MemoryPipeline.contactAttachmentURLs(of: report)
    }

    /// 预览用的副本:原文件在库里按 uuid 命名,Quick Look 的标题栏会显示那串 uuid;
    /// 拷一份按"报告名-页"命名的放进临时目录给它看。拷不出来就退回原文件。
    static func previewCopies(of report: MemoryItem) -> [URL] {
        let originals = fileURLs(of: report)
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "checkup-preview/\(report.uuid.uuidString)")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = safeName(report.title)
        return originals.enumerated().map { index, file in
            let name = originals.count > 1 ? "\(base)-\(index + 1)" : base
            let target = dir.appending(path: "\(name).\(file.pathExtension)")
            return (try? FileManager.default.copyItem(at: file, to: target)) != nil ? target : file
        }
    }

    // MARK: - 导入

    enum ImportError: LocalizedError {
        case noText
        case noItems

        var errorDescription: String? {
            switch self {
            case .noText:
                return loc("没有从文件里认出文字。拍照时尽量拍清楚、拍正,或者换成 PDF 原件试试。")
            case .noItems:
                return loc("没有从这份报告里整理出任何指标。")
            }
        }
    }

    /// 整理一份报告并落库。`files` 是已经拷到临时目录的文件(PDF/图片,调用方负责
    /// security-scoped 访问),`images` 是拍照/相册选的图。顺序是"先识别、再 AI、最后
    /// 才落库"——中途失败什么都不留(同 `MenuStore.importMenu`)。
    static func importReport(
        files: [URL], images: [Data], profileID: UUID?, context: ModelContext
    ) async throws -> MemoryItem {
        var parts: [String] = []
        for file in files {
            let text = await ContentExtractor.checkupText(fileURL: file)
            if !text.isEmpty { parts.append(text) }
        }
        for image in images {
            let text = await ContentExtractor.recognizeText(imageData: image)
            if !text.isEmpty { parts.append(text) }
        }
        let rawText = parts.joined(separator: "\n\n")
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.noText
        }
        try Task.checkCancellation()

        let existing = (try? context.fetch(FetchDescriptor<CheckupEntry>())) ?? []
        let known = CheckupPlan.knownNames(entries(ofProfile: profileID, in: existing))
        // 体检报告动辄几十页,比收藏的上限放宽一些(prompt 本身不长)。
        let parsed = try await DeepSeekClient.parseCheckupReport(
            text: MemorySearch.truncate(rawText, limit: 30_000), knownNames: known)
        try Task.checkCancellation()
        guard !parsed.items.isEmpty || !parsed.summaryAdvice.isEmpty else { throw ImportError.noItems }

        return save(parsed, rawText: rawText, files: files, images: images,
                    profileID: profileID, context: context)
    }

    /// 解析结果落库(单独拆出来:截图演示参数不走网络,直接喂一份样板进来)。
    @discardableResult
    static func save(
        _ parsed: ParsedCheckupReport, rawText: String, files: [URL], images: [Data],
        profileID: UUID?, context: ModelContext
    ) -> MemoryItem {
        let date = parsed.date ?? Date()
        let firstKind: MemoryKind = files.first.map {
            MemorySearch.kind(forExtension: $0.pathExtension) == .pdf ? .pdf : .image
        } ?? (images.isEmpty ? .text : .image)
        let item = MemoryItem(
            kind: firstKind,
            title: parsed.title.isEmpty ? defaultTitle(date) : parsed.title,
            tags: tags(for: profileID),
            status: .ready)
        item.checkupProfileUUID = profileID
        item.checkupDate = date
        item.checkupInstitution = parsed.institution.isEmpty ? nil : parsed.institution

        // 原文件全留着:整理错了的时候它是唯一能对照的东西,也是"查看文件"看的那份。
        var stored: [String] = []
        if let dir = AppGroup.memoryDirURL {
            for (index, file) in files.enumerated() {
                let ext = file.pathExtension.isEmpty ? "bin" : file.pathExtension
                let target = dir.appending(path: "\(item.uuid.uuidString)-\(index + 1).\(ext)")
                try? FileManager.default.removeItem(at: target)
                if (try? FileManager.default.copyItem(at: file, to: target)) != nil {
                    stored.append("Memory/\(target.lastPathComponent)")
                    if item.originalFileName == nil { item.originalFileName = file.lastPathComponent }
                }
            }
            for (index, image) in images.enumerated() {
                let target = dir.appending(path: "\(item.uuid.uuidString)-p\(index + 1).jpg")
                if (try? image.write(to: target, options: .atomic)) != nil {
                    stored.append("Memory/\(target.lastPathComponent)")
                }
            }
        }
        item.relativeFilePath = stored.first
        item.attachmentRelativePaths = Array(stored.dropFirst())

        for (index, parsedItem) in parsed.items.enumerated() {
            context.insert(CheckupEntry(
                reportUUID: item.uuid, profileUUID: profileID, kind: .item,
                category: parsedItem.category, name: parsedItem.name, value: parsedItem.value,
                unit: parsedItem.unit, referenceRange: parsedItem.reference, flag: parsedItem.flag,
                conclusion: parsedItem.conclusion, advice: parsedItem.advice,
                date: date, sortIndex: index))
        }
        if !parsed.summaryAdvice.isEmpty {
            context.insert(CheckupEntry(
                reportUUID: item.uuid, profileUUID: profileID, kind: .advice,
                advice: parsed.summaryAdvice, date: date, sortIndex: parsed.items.count))
        }
        item.sourceText = rawMarker + rawText
        context.insert(item)
        refreshDerived(item, context: context)
        return item
    }

    // MARK: - 修改

    /// 改报告本身(名称/日期/机构/归属)。日期和归属是冗余在条目上的,一起改;归属
    /// 变了还要重算「健康」标签——本人才有它。
    static func updateReport(
        _ report: MemoryItem, title: String, date: Date, institution: String,
        profileID: UUID?, context: ModelContext
    ) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        report.title = trimmed.isEmpty ? defaultTitle(date) : trimmed
        report.checkupDate = date
        let institution = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        report.checkupInstitution = institution.isEmpty ? nil : institution
        report.checkupProfileUUID = profileID
        let others = report.tags.filter { $0 != MemoryItem.healthTagName && $0 != MemoryItem.checkupTagName }
        report.tags = tags(for: profileID) + others
        for entry in entryModels(of: report.uuid, in: context) {
            entry.date = date
            entry.profileUUID = profileID
        }
        refreshDerived(report, context: context)
    }

    /// 新建一项(报告漏整理了的,手动补)。
    @discardableResult
    static func addEntry(to report: MemoryItem, kind: CheckupEntryKind, context: ModelContext) -> CheckupEntry {
        let existing = entryModels(of: report.uuid, in: context)
        let entry = CheckupEntry(
            reportUUID: report.uuid, profileUUID: report.checkupProfileUUID, kind: kind,
            date: date(of: report), sortIndex: (existing.map(\.sortIndex).max() ?? -1) + 1)
        context.insert(entry)
        return entry
    }

    /// 条目改完(或新建完)之后:重写报告的摘要和 sourceText。
    static func entryChanged(_ entry: CheckupEntry, context: ModelContext) {
        let reportID = entry.reportUUID
        guard let report = ((try? context.fetch(FetchDescriptor<MemoryItem>(
            predicate: #Predicate { $0.uuid == reportID }))) ?? []).first else {
            try? context.save()
            return
        }
        refreshDerived(report, context: context)
    }

    static func deleteEntry(_ entry: CheckupEntry, context: ModelContext) {
        let reportID = entry.reportUUID
        context.delete(entry)
        try? context.save()
        if let report = ((try? context.fetch(FetchDescriptor<MemoryItem>(
            predicate: #Predicate { $0.uuid == reportID }))) ?? []).first {
            refreshDerived(report, context: context)
        }
    }

    static func deleteReport(_ report: MemoryItem, context: ModelContext) {
        MemoryPipeline.delete(report, context: context)
    }

    /// 删一位家人:连同 TA 名下的全部报告(和原文件)一起删。
    static func deleteProfile(_ profile: HealthProfile, context: ModelContext) {
        // 共享着的档案先摘出共享(owner 停止共享、成员退出),再删本地——见 willDelete。
        SharedTripSync.shared.willDelete(profile)
        let profileID: UUID? = profile.uuid
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        for report in items where report.isCheckup && report.checkupProfileUUID == profileID {
            MemoryPipeline.delete(report, context: context)
        }
        context.delete(profile)
        try? context.save()
    }

    // MARK: - 重新匹配检查项

    /// 算出一个人的档案要怎么合并、去重(不落库)。配了 AI 时先让它按清单归组,再叠上
    /// 本地的缩写规则;没配 AI 只用本地规则和完全重复的记录。AI 请求失败照常抛错。
    static func normalizationPlan(profileID: UUID?, context: ModelContext) async throws -> CheckupNormalizationPlan {
        let all = (try? context.fetch(FetchDescriptor<CheckupEntry>())) ?? []
        let entries = entries(ofProfile: profileID, in: all)
        let catalog = CheckupNormalizer.catalog(entries)
        var aiGroups: [CheckupNameGroup] = []
        if DeepSeekClient.isConfigured, catalog.count >= 2 {
            aiGroups = try await DeepSeekClient.matchCheckupNames(catalog)
        }
        let groups = CheckupNormalizer.merge(aiGroups, CheckupNormalizer.localGroups(catalog))
        return CheckupNormalizer.plan(entries, groups: groups)
    }

    /// 应用方案:改名/补字段、删掉重复项,再重写受影响报告的摘要和 sourceText。
    /// 算方案之后条目可能已经被改过或删掉(共享档案别人在改),找不到的跳过。
    static func apply(_ plan: CheckupNormalizationPlan, context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<CheckupEntry>())) ?? []
        let byID = Dictionary(all.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        var touched = Set<UUID>()
        for (id, value) in plan.updates {
            guard let entry = byID[id] else { continue }
            entry.name = value.name
            entry.category = value.category
            entry.value = value.value
            entry.unit = value.unit
            entry.referenceRange = value.referenceRange
            entry.flagRaw = value.flag?.rawValue ?? ""
            entry.conclusion = value.conclusion
            entry.advice = value.advice
            touched.insert(entry.reportUUID)
        }
        for removal in plan.removals {
            guard let entry = byID[removal.id] else { continue }
            touched.insert(entry.reportUUID)
            context.delete(entry)
        }
        try? context.save()
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        for report in items where touched.contains(report.uuid) {
            refreshDerived(report, context: context)
        }
    }

    /// 摘要(记忆列表卡片那一行)+ sourceText(整理结果在前、原文在后),再重建索引。
    private static func refreshDerived(_ report: MemoryItem, context: ModelContext) {
        let entries = entryModels(of: report.uuid, in: context).map(CheckupEntryValue.init(from:))
        let itemCount = entries.filter { $0.kind == .item }.count
        let abnormal = CheckupPlan.abnormalCount(entries)
        var parts: [String] = []
        if let institution = report.checkupInstitution { parts.append(institution) }
        parts.append(loc("\(itemCount) 项"))
        if abnormal > 0 { parts.append(loc("\(abnormal) 项异常")) }
        report.summary = parts.joined(separator: " · ")

        let raw = report.sourceText.range(of: rawMarker).map { String(report.sourceText[$0.lowerBound...]) } ?? ""
        let structured = CheckupPlan.reportText(value(of: report), entries: entries)
        report.sourceText = MemorySearch.truncate(structured + raw, limit: 30_000)
        MemoryPipeline.finishStructuredSave(report, context: context)
    }

    private static func tags(for profileID: UUID?) -> [String] {
        profileID == nil ? [MemoryItem.checkupTagName, MemoryItem.healthTagName] : [MemoryItem.checkupTagName]
    }

    static func defaultTitle(_ date: Date) -> String {
        let year = Calendar.current.component(.year, from: date)
        return loc("\(String(year)) 年体检报告")
    }

    // MARK: - AI

    /// 本人的体检摘要(给健康分析和 read_health 用)。**只取本人的**——家人的档案
    /// 不参与健康分析,这是这个功能的硬约束。没有报告返回 nil。
    static func selfPromptSummary(items: [MemoryItem], entries: [CheckupEntry]) -> String? {
        let reports = reports(of: nil, in: items).map(value(of:))
        return CheckupPlan.promptSummary(reports: reports, entries: self.entries(ofProfile: nil, in: entries))
    }

    static func selfPromptSummary(context: ModelContext) -> String? {
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        let entries = (try? context.fetch(FetchDescriptor<CheckupEntry>(
            predicate: #Predicate { $0.profileUUID == nil }))) ?? []
        return selfPromptSummary(items: items, entries: entries)
    }

    // MARK: - 分享

    /// 分享一个人的档案:一份整理好的文字 + 每份报告的原文件(按"日期-报告名-页"重命名),
    /// 都放进临时目录,交给系统分享面板。对方收到的是普通文件,不需要装 lodo。
    static func shareFiles(profileID: UUID?, name: String, context: ModelContext) throws -> [URL] {
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        let reports = reports(of: profileID, in: items)
        let allEntries = (try? context.fetch(FetchDescriptor<CheckupEntry>())) ?? []
        let entries = self.entries(ofProfile: profileID, in: allEntries)

        let dir = FileManager.default.temporaryDirectory
            .appending(path: "checkup-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = CheckupPlan.shareText(profileName: name, reports: reports.map(value(of:)), entries: entries)
        let textURL = dir.appending(path: "\(safeName(loc("\(name)的体检档案"))).txt")
        try text.write(to: textURL, atomically: true, encoding: .utf8)

        var urls = [textURL]
        for report in reports {
            let prefix = safeName("\(CheckupPlan.dayString(date(of: report)))-\(report.title)")
            for (index, file) in fileURLs(of: report).enumerated() {
                let target = dir.appending(path: "\(prefix)-\(index + 1).\(file.pathExtension)")
                if (try? FileManager.default.copyItem(at: file, to: target)) != nil { urls.append(target) }
            }
        }
        return urls
    }

    private static func safeName(_ text: String) -> String {
        String(text.map { "/\\:?*\"<>|".contains($0) ? "-" : $0 }.prefix(60))
    }

    nonisolated private static func loc(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .appLanguage(), locale: AppSettings.language.locale)
    }
}

#if DEBUG
extension CheckupStore {
    /// 截图用样板:本人 2025、2026 两份报告 + 「妈妈」一份。库里已经有体检报告就不再塞。
    /// 2026 那份带一个现画的 PDF 当原文件,用来核对"查看原文件"。
    static func seedDemo(context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        guard !items.contains(where: \.isCheckup) else { return }
        func day(_ text: String) -> Date {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: text) ?? Date()
        }
        let older = ParsedCheckupReport(
            title: "2025 年度健康体检", date: day("2025-05-12"), institution: "美年大健康",
            items: [
                ParsedCheckupItem(category: "一般检查", name: "体重指数(BMI)", value: "23.8", unit: "kg/m²", reference: "18.5-24"),
                ParsedCheckupItem(category: "一般检查", name: "血压", value: "126/82", unit: "mmHg", reference: "<140/90"),
                ParsedCheckupItem(category: "血脂", name: "总胆固醇(TC)", value: "5.1", unit: "mmol/L", reference: "<5.2"),
                ParsedCheckupItem(category: "血脂", name: "低密度脂蛋白(LDL-C)", value: "3.2", unit: "mmol/L", reference: "<3.4"),
                ParsedCheckupItem(category: "血糖", name: "空腹血糖", value: "5.4", unit: "mmol/L", reference: "3.9-6.1"),
                ParsedCheckupItem(category: "肝功能", name: "谷丙转氨酶(ALT)", value: "38", unit: "U/L", reference: "9-50"),
                ParsedCheckupItem(category: "影像", name: "腹部B超", value: "未见明显异常", conclusion: "肝、胆、胰、脾、双肾未见明显异常"),
            ],
            summaryAdvice: "各项指标基本正常,建议保持规律作息,一年后复查。")
        let newer = ParsedCheckupReport(
            title: "2026 年度健康体检", date: day("2026-05-08"), institution: "美年大健康",
            items: [
                ParsedCheckupItem(category: "一般检查", name: "体重指数(BMI)", value: "24.6", unit: "kg/m²", reference: "18.5-24", flag: .high),
                ParsedCheckupItem(category: "一般检查", name: "血压", value: "132/86", unit: "mmHg", reference: "<140/90"),
                ParsedCheckupItem(category: "血脂", name: "总胆固醇(TC)", value: "5.8", unit: "mmol/L", reference: "<5.2", flag: .high,
                                  advice: "总胆固醇偏高,建议减少动物内脏、油炸食品,3 个月后复查血脂。"),
                ParsedCheckupItem(category: "血脂", name: "低密度脂蛋白(LDL-C)", value: "3.7", unit: "mmol/L", reference: "<3.4", flag: .high),
                ParsedCheckupItem(category: "血糖", name: "空腹血糖", value: "5.6", unit: "mmol/L", reference: "3.9-6.1"),
                ParsedCheckupItem(category: "肝功能", name: "谷丙转氨酶(ALT)", value: "56", unit: "U/L", reference: "9-50", flag: .high,
                                  advice: "转氨酶轻度升高,可能与脂肪肝有关,建议戒酒、控制体重后复查。"),
                ParsedCheckupItem(category: "影像", name: "腹部B超", value: "轻度脂肪肝", flag: .abnormal,
                                  conclusion: "肝脏大小正常,实质回声细密增强\n胆、胰、脾、双肾未见明显异常"),
            ],
            summaryAdvice: "1. 血脂偏高、轻度脂肪肝,建议低脂饮食,每周 150 分钟中等强度运动。\n2. 体重略超,建议减重 3–5 公斤。\n3. 3 个月后复查血脂和肝功能。")
        let mother = HealthProfile(name: "妈妈", relation: "母亲")
        context.insert(mother)
        let motherReport = ParsedCheckupReport(
            title: "2026 年体检", date: day("2026-04-20"), institution: "市第一人民医院",
            items: [
                ParsedCheckupItem(category: "血糖", name: "空腹血糖", value: "6.8", unit: "mmol/L", reference: "3.9-6.1", flag: .high),
                ParsedCheckupItem(category: "骨密度", name: "骨密度 T 值", value: "-1.8", reference: ">-1.0", flag: .low,
                                  advice: "骨量减少,建议补钙、多晒太阳。"),
            ])

        let pdf = demoPDFURL()
        save(older, rawText: "", files: [], images: [], profileID: nil, context: context)
        save(newer, rawText: "", files: pdf.map { [$0] } ?? [], images: [], profileID: nil, context: context)
        save(motherReport, rawText: "", files: [], images: [], profileID: mother.uuid, context: context)
    }

    static func demoPDFURL() -> URL? {
        demoPDF(lines: ["2026 年度健康体检报告", "美年大健康  体检日期:2026-05-08", "",
                        "【血脂】", "总胆固醇(TC)  5.8 ↑  mmol/L  参考 <5.2",
                        "低密度脂蛋白(LDL-C)  3.7 ↑  mmol/L  参考 <3.4",
                        "【肝功能】", "谷丙转氨酶(ALT)  56 ↑  U/L  参考 9-50",
                        "【腹部B超】", "肝脏实质回声细密增强,提示轻度脂肪肝。", "",
                        "总检建议:", "1. 血脂偏高,建议低脂饮食,3 个月后复查。",
                        "2. 转氨酶轻度升高,建议戒酒、控制体重后复查肝功能。"])
    }

    /// 现画一页 A4 PDF(CoreText 写几行字)。
    private static func demoPDF(lines: [String]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appending(path: "demo-checkup.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        pdf.beginPDFPage(nil)
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, 16, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(
                string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            pdf.textPosition = CGPoint(x: 56, y: 780 - CGFloat(index) * 28)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), pdf)
        }
        pdf.endPDFPage()
        pdf.closePDF()
        return url
    }
}
#endif
