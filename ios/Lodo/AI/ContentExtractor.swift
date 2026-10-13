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
        let text = await recognizeText(VNImageRequestHandler(url: url))
        return Extraction(text: MemorySearch.truncate(text), kind: .image, suggestedTitle: nil)
    }

    /// 内存里的图片直接 OCR,不落文件(旅行页导入截图用:截图只是拿来读字的,
    /// 不需要存成一条记忆)。识别不出文字返回空串。
    static func recognizeText(imageData: Data) async -> String {
        await recognizeText(VNImageRequestHandler(data: imageData))
    }

    private static func recognizeText(_ handler: VNImageRequestHandler) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                try? handler.perform([request])
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }

    /// 体检报告的文字:PDF 先取文字层;文字层几乎是空的(扫描件、拍照转的 PDF)时
    /// 逐页渲染成图再 OCR。图片直接 OCR。认不出的类型返回空串。
    /// 和收藏那条 `extract(fileURL:)` 分开:那边扫描版 PDF 拿不到字也无所谓(原文件
    /// 还在),这边拿不到字整份报告就整理不出来。
    static func checkupText(fileURL: URL) async -> String {
        switch MemorySearch.kind(forExtension: fileURL.pathExtension) {
        case .pdf:
            let layer = extractPDF(fileURL).text
            if layer.filter({ !$0.isWhitespace }).count >= 80 { return layer }
            return await recognizePDFPages(fileURL)
        case .image:
            return await recognizeText(VNImageRequestHandler(url: fileURL))
        case .text:
            return plainText(of: fileURL)
        case .link, .file:
            return ""
        }
    }

    /// 扫描版 PDF:逐页按 2 倍渲染成位图再 OCR,最多 `maxPDFPages` 页。
    private static func recognizePDFPages(_ url: URL) async -> String {
        guard let document = PDFDocument(url: url) else { return "" }
        var parts: [String] = []
        for index in 0..<min(document.pageCount, maxPDFPages) {
            guard let page = document.page(at: index), let image = render(page) else { continue }
            let text = await recognizeText(VNImageRequestHandler(cgImage: image))
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n")
    }

    /// PDFPage → CGImage,不经 UIImage/NSImage(两个平台同一份代码)。
    private static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = CGSize(width: (rotated ? bounds.height : bounds.width) * scale,
                          height: (rotated ? bounds.width : bounds.height) * scale)
        guard size.width >= 1, size.height >= 1,
              let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// 菜单 OCR 优先尝试的语言(Vision 的识别语言代码)。和收藏用的 `extractImage`
    /// 分开:那边只认中英足够,菜单的主要场景恰恰是出国看不懂的外文菜单。
    /// 实际生效的是这份和系统支持列表的交集(老系统不支持日韩等语言时自动剔掉)。
    static let menuRecognitionLanguages = [
        "ja-JP", "ko-KR", "zh-Hans", "zh-Hant", "en-US", "fr-FR", "it-IT", "de-DE",
        "es-ES", "pt-BR", "th-TH", "vi-VT", "ru-RU",
    ]

    /// 菜单照片/截图 OCR。识别不出文字返回空串,由调用方给"没认出文字"的提示。
    /// 打开自动语言检测:一张菜单只会是一两种语言,把十几种候选同时当首选反而
    /// 容易把日文假名认成别的东西。
    static func recognizeMenuText(in data: Data) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                if let supported = try? request.supportedRecognitionLanguages() {
                    request.recognitionLanguages = menuRecognitionLanguages
                        .filter(supported.contains)
                }
                let handler = VNImageRequestHandler(data: data)
                try? handler.perform([request])
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
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
