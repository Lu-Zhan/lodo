import SwiftUI
import SwiftData
import LodoCore

/// 一篇文章,**阅读模式**排版(参考 Safari 阅读器):不用 List/Section,从上到下直接写——
/// 标题、时间、一行可展开的 AI 总结、正文(分段、小标题、引用、列表、图片)、
/// 最后是「阅读原文」和来源信息。
///
/// 打开即标为已读,并且**自动**做两件事:去原网页抓正文(`NewsStore.content`,保留段落
/// 结构和图片;很多 RSS 只给一两句摘要)、没总结过就总结一次。AI 总结做过一次就存在
/// 文章上(`NewsArticle.aiSummary`),再打开不再花一次请求;正文只在内存里缓存。
struct NewsArticleView: View {
    let article: NewsArticle

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @AppStorage(AppSettings.newsFontSizeKey) private var fontSizeRaw = NewsFontSize.standard.rawValue
    @AppStorage(AppSettings.newsMarginKey) private var marginRaw = NewsMargin.standard.rawValue
    @AppStorage(AppSettings.accentPaletteKey) private var accentPaletteRaw =
        AccentPalette.terracotta.rawValue
    @State private var showReadingSettings = false

    @State private var summarizeTask: Task<Void, Never>?
    @State private var summaryError: String?
    /// 抓到的阅读模式正文;nil = 还在抓或没抓到(那时显示 feed 摘要)。
    @State private var content: ArticleContent?
    @State private var isFetchingText = false
    /// AI 总结那一行默认收起,点了才展开。
    @State private var summaryExpanded = false

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }
    private var link: URL? {
        URL(string: article.link).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
    }

    /// 正文最宽这么多:iPad/Mac 上一行太长读着累,阅读器都会收一收。
    private static let readableWidth: CGFloat = 680

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                aiSummary
                Divider()
                articleBody
                Divider()
                footer
                    .id("end")
            }
            // 阅读设置:字号整体套一个 Dynamic Type 档位,边距按档位给点数。
            .dynamicTypeSize(NewsFontSize.stored(fontSizeRaw).dynamicTypeSize)
            .padding(.horizontal, NewsMargin.stored(marginRaw).points)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: Self.readableWidth + NewsMargin.stored(marginRaw).points * 2, alignment: .leading)
            .frame(maxWidth: .infinity)
            .animation(.lodoAware(.snappy), value: fontSizeRaw)
            .animation(.lodoAware(.snappy), value: marginRaw)
        }
        #if DEBUG
        // 截图用:--demo-news-summary-open 展开 AI 总结,--demo-news-article-end 滚到底看来源。
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--demo-news-summary-open") { summaryExpanded = true }
            if args.contains("--demo-news-article-end") {
                try? await Task.sleep(for: .seconds(12))
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
        #endif
        }
        // 顶部只显示标题(在正文里),导航栏不再重复一遍来源名。
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showReadingSettings) {
            let palette = AccentPalette(rawValue: accentPaletteRaw) ?? .terracotta
            NewsReadingSettingsView()
                .tint(palette.accent)
                .environment(\.lodoAccent, palette)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showReadingSettings = true
                } label: {
                    Label("阅读设置", systemImage: "textformat.size")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NewsStore.toggleStar(article, context: context)
                } label: {
                    Label(LocalizedStringKey(article.isStarred ? "取消收藏" : "收藏"),
                          systemImage: article.isStarred ? "star.fill" : "star")
                }
            }
            if let link {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: link, subject: Text(article.title)) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear { NewsStore.setRead(article, true, context: context) }
        .task { await loadOnOpen() }
        .onDisappear { summarizeTask?.cancel() }
    }

    // MARK: - 标题 + 时间

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(article.title)
                .font(.title.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(article.publishedAt, format: .dateTime.year().month().day().hour().minute()
                    .locale(language.locale))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - AI 总结(默认收起)

    @ViewBuilder
    private var aiSummary: some View {
        if article.aiSummary != nil || DeepSeekClient.isConfigured {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.lodoAware(.snappy)) { summaryExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                        Text("AI 总结")
                            .font(.subheadline.weight(.semibold))
                        if summarizeTask != nil && article.aiSummary == nil {
                            ProgressView().controlSize(.mini)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(summaryExpanded ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .pressable()
                .accessibilityValue(summaryExpanded ? Text("已展开") : Text("已收起"))

                if summaryExpanded {
                    summaryContent
                        .transition(.opacity)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.fill.quaternary))
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        if let summary = article.aiSummary {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.summary)
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                ForEach(Array(summary.points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(point)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // 换了总结语言、或者总结得不好时重写一份(总结只在文章上存一份)。
                if DeepSeekClient.isConfigured {
                    Button {
                        summarize(force: true)
                    } label: {
                        if summarizeTask != nil {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("正在总结…")
                            }
                        } else {
                            Label("重新总结", systemImage: "arrow.clockwise")
                        }
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.tint)
                    .pressable()
                    .disabled(summarizeTask != nil)
                }
            }
        } else if let summaryError {
            VStack(alignment: .leading, spacing: 6) {
                Text(summaryError)
                    .font(.subheadline)
                    .foregroundStyle(LodoColor.critical)
                Button {
                    summarize()
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.subheadline)
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(LocalizedStringKey(isFetchingText ? "正在读原文…" : "正在总结…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 正文

    /// 抓到正文就按结构排版;没抓到先显示 feed 摘要(抓的时候下面挂一行进度)。
    @ViewBuilder
    private var articleBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let content {
                ForEach(Array(bodyBlocks(content).enumerated()), id: \.offset) { _, block in
                    ArticleBlockView(block: block)
                }
            } else if !article.summary.isEmpty {
                ArticleBlockView(block: .paragraph(article.summary))
            }
            if isFetchingText {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在抓取全文…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if content == nil, !article.summary.isEmpty {
                Text("这个订阅只提供了摘要,原网页也没能抓到全文。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 正文里和文章标题一样的小标题去掉:不少站用 h2 写页面标题,顶上已经有了。
    private func bodyBlocks(_ content: ArticleContent) -> [ArticleBlock] {
        let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return content.blocks.filter { block in
            if case .heading(let text) = block { return text != title }
            return true
        }
    }

    // MARK: - 阅读原文 + 来源

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let link {
                Button {
                    openURL(link)
                } label: {
                    Label("阅读原文", systemImage: "safari")
                        .font(.body.weight(.semibold))
                }
                .pressable()
            }
            VStack(alignment: .leading, spacing: 4) {
                sourceLine("来源", article.feedTitle)
                if !article.author.isEmpty { sourceLine("作者", article.author) }
                sourceLine("发布时间", article.publishedAt.formatted(
                    .dateTime.year().month().day().hour().minute().locale(language.locale)))
                if let host = link?.host { sourceLine("网址", host) }
            }
        }
    }

    private func sourceLine(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .font(.footnote)
    }

    // MARK: - 加载

    /// 打开时:先抓正文,再用它总结(总结过的只抓正文)。
    private func loadOnOpen() async {
        if content == nil {
            isFetchingText = true
            content = await NewsStore.content(article)
            isFetchingText = false
        }
        if article.aiSummary == nil, DeepSeekClient.isConfigured, summarizeTask == nil {
            summarize()
        }
    }

    private func summarize(force: Bool = false) {
        summaryError = nil
        summarizeTask = Task {
            do {
                _ = try await NewsStore.summarize(article, language: language, force: force, context: context)
            } catch is CancellationError {
            } catch {
                summaryError = error.localizedDescription
            }
            summarizeTask = nil
        }
    }
}

/// 阅读模式里的一块:段落行距放宽、小标题加粗、引用左边一道竖线、列表带圆点、
/// 图片按宽度铺满并加圆角(加载失败就不占位)。
private struct ArticleBlockView: View {
    let block: ArticleBlock

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title3.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                Capsule()
                    .fill(.tint)
                    .frame(width: 3)
                Text(text)
                    .font(.body)
                    .italic()
                    .lineSpacing(6)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .listItem(let text):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•").foregroundStyle(.secondary)
                Text(text)
                    .font(.body)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .image(let url):
            ArticleImage(url: url)
        }
    }
}

/// 正文图片:加载中是一块浅灰占位,失败(防盗链、失效)就整块不显示。
private struct ArticleImage: View {
    let url: URL
    @State private var failed = false

    var body: some View {
        if !failed {
            AsyncImage(url: url, transaction: Transaction(animation: .lodoAware(.easeOut(duration: 0.2)))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                case .failure:
                    Color.clear.frame(height: 0)
                        .onAppear { failed = true }
                default:
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.fill.tertiary)
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityLabel("图片")
        }
    }
}
