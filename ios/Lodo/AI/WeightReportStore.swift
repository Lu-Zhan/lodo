import Foundation
import SwiftData
import LodoCore

/// 体重秤报告导入(体脂秤 app 的截图/PDF/拍照):端上取字 → AI 整理出一组测量 →
/// **确认页核对、勾选** → 落库。纯解析与换算在 `WeightReport`(LodoCore)。
///
/// 和体检报告分两步(`prepare` 只整理不落库,`save` 才写):一次测量就是体重趋势上的
/// 一个点,日期或单位认错了会把整条曲线带歪,所以先给用户看一眼(体检报告没有确认页,
/// 那边上百项逐条确认更难受,而且认错一项不影响别的)。
///
/// 落库后:每次测量一条 `WeightRecord`(`reportUUID` 指回报告),整份报告一条打
/// 「体重秤报告」标签的记忆条目(原文件 + 整理结果 + OCR 原文),**不打「健康」**——
/// 原文不进 AI 健康分析,健康分析只看体重管理的汇总。
@MainActor
enum WeightReportStore {
    private static let rawMarker = "\n\n——报告原文——\n"

    enum ImportError: LocalizedError {
        case noText
        case noMeasurements

        var errorDescription: String? {
            switch self {
            case .noText:
                return loc("没有从文件里认出文字。截图尽量完整、清楚,或者换成 PDF 试试。")
            case .noMeasurements:
                return loc("没有从这份记录里认出体重或身体成分。")
            }
        }
    }

    /// 取字 + AI 整理,不落库。`files` 是已经拷到临时目录的文件,`images` 是拍照/相册的图。
    static func prepare(files: [URL], images: [Data]) async throws -> (rawText: String, report: ParsedWeightReport) {
        var parts: [String] = []
        // 每页单独标一下,AI 和确认页都能看出哪几次测量来自同一张图(去掉多张截图里重复的那次)。
        for (index, file) in files.enumerated() {
            let text = await ContentExtractor.checkupText(fileURL: file)
            if !text.isEmpty { parts.append("【第 \(index + 1) 份文件】\n" + text) }
        }
        for (index, image) in images.enumerated() {
            let text = await ContentExtractor.recognizeText(imageData: image)
            if !text.isEmpty { parts.append("【第 \(index + 1) 张图】\n" + text) }
        }
        let rawText = parts.joined(separator: "\n\n")
        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.noText
        }
        try Task.checkCancellation()
        let report = try await DeepSeekClient.parseWeightReport(
            text: MemorySearch.truncate(rawText, limit: 20_000))
        try Task.checkCancellation()
        guard !report.measurements.isEmpty else { throw ImportError.noMeasurements }
        return (rawText, report)
    }

    /// 用户核对过的测量落库。`measurements` 只放勾选了的,日期都已经定好(确认页不让
    /// 没日期的保存)。返回那份报告的记忆条目。
    @discardableResult
    static func save(_ measurements: [ParsedWeightMeasurement], report: ParsedWeightReport,
                     rawText: String, files: [URL], images: [Data], context: ModelContext) -> MemoryItem {
        let dates = measurements.compactMap(\.date)
        let item = MemoryItem(
            kind: files.first.map {
                MemorySearch.kind(forExtension: $0.pathExtension) == .pdf ? .pdf : .image
            } ?? (images.isEmpty ? .text : .image),
            title: report.title.isEmpty ? defaultTitle(dates.max() ?? Date()) : report.title,
            tags: [MemoryItem.weightReportTagName],
            status: .ready)

        // 原文件全留着:认错了的时候它是唯一能对照的东西。
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

        for m in measurements {
            let record = WeightRecord(date: m.date ?? Date(), weightKg: m.weightKg,
                                      bodyFatPercent: m.bodyFatPercent)
            record.muscleMassKg = m.muscleMassKg
            record.visceralFatLevel = m.visceralFatLevel
            record.basalMetabolicKcal = m.basalMetabolicKcal
            record.bodyWaterPercent = m.bodyWaterPercent
            record.boneMassKg = m.boneMassKg
            record.reportUUID = item.uuid
            context.insert(record)
        }

        let device = report.device.isEmpty ? [] : [report.device]
        item.summary = (device + [loc("\(measurements.count) 次测量")]).joined(separator: " · ")
        let lines = measurements.map { WeightReportText.line($0) }
        item.sourceText = MemorySearch.truncate(lines.joined(separator: "\n") + rawMarker + rawText,
                                                limit: 30_000)
        context.insert(item)
        MemoryPipeline.finishStructuredSave(item, context: context)
        return item
    }

    static func defaultTitle(_ date: Date) -> String {
        let day = date.formatted(.dateTime.month().day().locale(AppSettings.language.locale))
        return loc("体重秤记录 \(day)")
    }

    nonisolated private static func loc(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .appLanguage(), locale: AppSettings.language.locale)
    }
}

#if DEBUG
extension WeightReportStore {
    /// 截图参数 --demo-weight-report-live:一份样板「体脂秤 app 历史记录」PDF(一次详情 +
    /// 两行历史,其中一行用斤),真发一次 AI 走完整的识别 → 整理 → 确认页。
    static func demoPDFURL() -> URL? {
        CheckupStore.demoPDF(lines: [
            "小米运动健康 · 体脂秤", "",
            "2026年10月18日 07:32", "体重 62.4kg   体脂率 21.3%", "肌肉量 46.2kg   内脏脂肪等级 7",
            "基础代谢 1420kcal   水分 54.8%   骨量 2.6kg", "",
            "历史记录",
            "10月15日 08:01   125.6斤   体脂率 21.8%",
            "10月12日 07:45   63.1kg   体脂率 22.0%",
        ], name: "demo-weight-report")
    }
}
#endif

/// 一次测量的文字(报告条目的 sourceText、确认页的摘要共用)。
enum WeightReportText {
    static func line(_ m: ParsedWeightMeasurement) -> String {
        var parts: [String] = []
        if let date = m.date {
            parts.append(date.formatted(m.dateOnly
                ? .dateTime.year().month().day().locale(AppSettings.language.locale)
                : .dateTime.year().month().day().hour().minute().locale(AppSettings.language.locale)))
        }
        parts.append(contentsOf: values(weightKg: m.weightKg, bodyFat: m.bodyFatPercent,
                                        muscle: m.muscleMassKg, visceral: m.visceralFatLevel,
                                        basal: m.basalMetabolicKcal, water: m.bodyWaterPercent,
                                        bone: m.boneMassKg))
        return parts.joined(separator: " · ")
    }

    /// 体重之外的身体成分,如「肌肉 46.2 公斤 · 内脏脂肪 7 · 基础代谢 1420 千卡」。
    static func composition(_ record: WeightRecord) -> String {
        values(weightKg: nil, bodyFat: nil, muscle: record.muscleMassKg, visceral: record.visceralFatLevel,
               basal: record.basalMetabolicKcal, water: record.bodyWaterPercent, bone: record.boneMassKg)
            .joined(separator: " · ")
    }

    private static func values(weightKg: Double?, bodyFat: Double?, muscle: Double?, visceral: Double?,
                               basal: Double?, water: Double?, bone: Double?) -> [String] {
        func loc(_ key: String.LocalizationValue) -> String {
            String(localized: key, bundle: .appLanguage(), locale: AppSettings.language.locale)
        }
        var parts: [String] = []
        if let weightKg { parts.append(loc("\(WeightPlan.format(weightKg)) 公斤")) }
        if let bodyFat { parts.append(loc("体脂 \(WeightPlan.format(bodyFat))%")) }
        if let muscle { parts.append(loc("肌肉 \(WeightPlan.format(muscle)) 公斤")) }
        if let visceral { parts.append(loc("内脏脂肪 \(WeightPlan.format(visceral))")) }
        if let basal { parts.append(loc("基础代谢 \(Int(basal)) 千卡")) }
        if let water { parts.append(loc("水分 \(WeightPlan.format(water))%")) }
        if let bone { parts.append(loc("骨量 \(WeightPlan.format(bone)) 公斤")) }
        return parts
    }
}
