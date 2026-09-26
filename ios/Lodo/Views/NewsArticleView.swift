import SwiftUI
import SwiftData
import LodoCore

/// 一篇文章:标题、来源、feed 里的摘要,「AI 总结」和「阅读原文」。
/// 打开即标为已读;AI 总结做过一次就存在文章上(`NewsArticle.aiSummary`),
/// 再打开不再花一次请求。
struct NewsArticleView: View {
    let article: NewsArticle

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue

    @State private var summarizeTask: Task<Void, Never>?
    @State private var summaryError: String?

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

            if !article.summary.isEmpty {
                Section("摘要") {
                    Text(article.summary)
                        .font(.body)
                        .textSelection(.enabled)
                }
            }

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
                Button {
                    summarize()
                } label: {
                    if summarizeTask != nil {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("正在读原文并总结…")
                        }
                    } else {
                        Label("AI 总结", systemImage: "sparkles")
                    }
                }
                .disabled(summarizeTask != nil)
                if let summaryError {
                    Text(summaryError)
                        .font(.subheadline)
                        .foregroundStyle(LodoColor.critical)
                }
            } footer: {
                Text("会先抓取原文网页,抓不到时只根据摘要总结。")
            }
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
