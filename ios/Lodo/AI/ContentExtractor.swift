import Foundation
import PDFKit
import Vision
import LodoCore

/// 收藏内容的端上文本提取:PDF 用 PDFKit、图片用 Vision OCR、网页抓正文,
/// 结果统一截断后交给 AI 整理。放 app 层(不进 LodoCore)是因为 Vision/PDFKit
/// 是平台框架,LodoCore 还要支撑 watchOS 编译。
enum ContentExtractor {

    /// PDF 最多解析的页数(超长文档取前面部分已足够 AI 整理)。
    static let maxPDFPages = 30
    /// 网页抓取限制:超时与最大字节数。
    static let webTimeout: TimeInterval = 10
    static let webMaxBytes = 2 * 1024 * 1024

    struct Extraction {
        var text: String
        var kind: MemoryKind
        /// 文件元数据里带的候选标题(如 PDF 的 Title 属性),AI 失败时兜底用。
        var suggestedTitle: String?
    }

    /// 纯文字(粘贴/手动输入)。
    static func extract(text: String) -> Extraction {
        Extraction(text: MemorySearch.truncate(text), kind: .text, suggestedTitle: nil)
    }

    /// 网页链接:抓取页面并用系统 HTML → 纯文本转换提取正文;
    /// 失败时只留 URL 本身,AI 凭 URL 推断。
    static func extract(url: URL) async -> Extraction {
        var request = URLRequest(url: url)
        request.timeoutInterval = webTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
              !data.isEmpty else {
            return Extraction(text: "", kind: .link, suggestedTitle: nil)
        }
        let capped = data.prefix(webMaxBytes)
        // NSAttributedString 的 HTML 导入底层走 WebKit,要求主线程
        let text = await MainActor.run { () -> String in
            let attributed = try? NSAttributedString(
                data: Data(capped),
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
            return attributed?.string ?? ""
        }
        return Extraction(text: MemorySearch.truncate(text), kind: .link, suggestedTitle: nil)
    }

    /// 本地文件:按扩展名分发到 PDF/图片/文本;认不出的类型不解析
    /// (原文件照留,AI 只看文件名)。
    static func extract(fileURL: URL) async -> Extraction {
        let kind = MemorySearch.kind(forExtension: fileURL.pathExtension)
        switch kind {
        case .pdf:
            // PDF 解析放后台队列,大文件不卡主线程
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: extractPDF(fileURL))
                }
            }
        case .image:
            return await extractImage(fileURL)
        case .text:
            return Extraction(text: MemorySearch.truncate(plainText(of: fileURL)),
                              kind: .text, suggestedTitle: nil)
        case .link, .file:
            return Extraction(text: "", kind: .file, suggestedTitle: nil)
        }
    }

    private static func extractPDF(_ url: URL) -> Extraction {
        guard let document = PDFDocument(url: url) else {
            return Extraction(text: "", kind: .pdf, suggestedTitle: nil)
        }
        var parts: [String] = []
        for index in 0..<min(document.pageCount, maxPDFPages) {
            if let text = document.page(at: index)?.string { parts.append(text) }
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        return Extraction(text: MemorySearch.truncate(parts.joined(separator: "\n")),
                          kind: .pdf,
                          suggestedTitle: title?.isEmpty == false ? title : nil)
    }

    /// 图片 OCR;识别不出文字不算失败(照片类图片本来就没字),sourceText 留空。
    private static func extractImage(_ url: URL) async -> Extraction {
        let text = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                let handler = VNImageRequestHandler(url: url)
                try? handler.perform([request])
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
        return Extraction(text: MemorySearch.truncate(text), kind: .image, suggestedTitle: nil)
    }

    /// 文本文件读取:UTF-8 优先,失败退 GB18030(中文老文件常见),再失败给空。
    private static func plainText(of url: URL) -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        return (try? String(contentsOf: url, encoding: gb18030)) ?? ""
    }
}
