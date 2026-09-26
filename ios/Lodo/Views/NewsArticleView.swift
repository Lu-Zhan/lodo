import SwiftUI
import SwiftData
import LodoCore

/// 一篇文章:标题、来源、AI 总结、正文和「阅读原文」。
/// 打开即标为已读,并且**自动**做两件事:去原网页抓全文(很多 RSS 只给一两句
/// 摘要,见 `NewsStore.fullText`)、没总结过就总结一次。AI 总结做过一次就存在
/// 文章上(`NewsArticle.aiSummary`),再打开不再花一次请求;全文只在内存里缓存。
struct NewsArticleView: View {
    let article: NewsArticle

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue

    @State private var summarizeTask: Task<Void, Never>?
    @State private var summaryError: String?
    /// 抓到的全文;nil = 还在抓或没抓到(那时显示 feed 摘要)。
    @State private var fullText: String?
    @State private var isFetchingText = false
    @State private var showsWholeText = false

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }
    private var link: URL? {
        URL(string: article.link).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(article.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 4) {
                        Text(article.feedTitle)
                        Text("·")
                        Text(article.publishedAt, format: .dateTime.month().day().hour().minute())
                        if !article.author.isEmpty {
                            Text("·")
                            Text(article.author).lineLimit(1)
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            aiSection

            bodySection

            if let link {
                Section {
                    Button {
                        openURL(link)
                    } label: {
                        Label("阅读原文", systemImage: "safari")
                    }
                } footer: {
                    Text(link.host ?? link.absoluteString)
                }
            }
        }
        .navigationTitle(article.feedTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NewsStore.toggleStar(article, context: context)
                } label: {
                    Label(article.isStarred ? "取消收藏" : "收藏",
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

    @ViewBuilder
    private var aiSection: some View {
        if let summary = article.aiSummary {
            Section {
                Text(summary.summary)
                    .font(.body)
                    .textSelection(.enabled)
                ForEach(Array(summary.points.enumerated()), id: \.offset) { _, point in
                    Label {
                        Text(point).font(.subheadline)
                    } icon: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("AI 总结", systemImage: "sparkles")
            }
        } else if DeepSeekClient.isConfigured {
            Section {
                if summarizeTask != nil || summaryError == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(isFetchingText ? "正在读原文…" : "正在总结…")
                            .foregroundStyle(.secondary)
                    }
                }
                if let summaryError {
                    Text(summaryError)
                        .font(.subheadline)
                        .foregroundStyle(LodoColor.critical)
                    Button {
                        summarize()
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                }
            } header: {
                Label("AI 总结", systemImage: "sparkles")
            }
        }
    }

    /// 正文:抓到全文就显示全文(太长先折叠),没抓到显示 feed 摘要。
    @ViewBuilder
    private var bodySection: some View {
        let text = fullText ?? article.summary
        if !text.isEmpty || isFetchingText {
            Section {
                if !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .lineLimit(showsWholeText ? nil : 12)
                        .textSelection(.enabled)
                    if !showsWholeText, text.count > 400 {
                        Button("展开全文") {
                            withAnimation(.lodoAware(.snappy)) { showsWholeText = true }
                        }
                    }
                }
                if isFetchingText {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在抓取全文…").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(fullText == nil ? "摘要" : "正文")
            } footer: {
                if fullText == nil, !isFetchingText, !article.summary.isEmpty {
                    Text("这个订阅只提供了摘要,原网页也没能抓到全文。")
                }
            }
        }
    }

    /// 打开时:先抓全文,再用它总结(总结过的只抓全文)。
    private func loadOnOpen() async {
        if fullText == nil {
            isFetchingText = true
            fullText = await NewsStore.fullText(article)
            isFetchingText = false
        }
        if article.aiSummary == nil, DeepSeekClient.isConfigured, summarizeTask == nil {
            summarize()
        }
    }

    private func summarize() {
        summaryError = nil
        summarizeTask = Task {
            do {
                _ = try await NewsStore.summarize(article, language: language, context: context)
            } catch is CancellationError {
            } catch {
                summaryError = error.localizedDescription
            }
            summarizeTask = nil
        }
    }
}
