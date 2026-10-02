import SwiftUI
import SwiftData
import LodoCore

/// 新闻页里可以 push 进去的两类页面。
enum NewsRoute: Hashable {
    case article(NewsArticle)
    case feeds
}

/// "新闻"页:订阅的新闻/博客按天排的文章流,顶上一张「今日简报」。
///
/// - 找文章 = 底下那条「问问 AI」(带 `.news` 页面焦点,模型用 `search_news` 在订阅里找),
///   和记忆/人脉页一样**不另摆搜索框**。
/// - 订阅管理、添加订阅、定时推送收在右上角菜单——AI 接不了订阅这一棒,
///   这几个入口必须留着(同旅行详情页的「从订单导入」)。
/// - 定时推送不是另一套机制:就是一条带「带上订阅的新闻」的定时任务
///   (`AIRoutine.includeNews`),触发、通知、补跑都走 `RoutineRunner`。
struct NewsListView: View {
    /// 顶上的切换。「今日」不是文章筛选,是今日总结(AI 简报 + 每条的参考新闻链接)。
    enum ReadFilter: String, CaseIterable, Identifiable {
        case today, all, unread, starred
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .today: return "今日"
            case .all: return "全部"
            case .unread: return "未读"
            case .starred: return "已收藏"
            }
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(\.sidebarChrome) private var sidebarChrome
    @Environment(\.sectionIsActive) private var sectionIsActive
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @AppStorage(AppSettings.accentPaletteKey) private var accentPaletteRaw =
        AccentPalette.terracotta.rawValue

    @Query(sort: [SortDescriptor(\NewsArticle.publishedAt, order: .reverse)])
    private var articles: [NewsArticle]
    @Query(sort: [SortDescriptor(\NewsFeed.createdAt)]) private var feeds: [NewsFeed]
    @Query(sort: [SortDescriptor(\AIRoutine.createdAt)]) private var routines: [AIRoutine]

    @State private var path: [NewsRoute] = []
    @State private var readFilter: ReadFilter = .all
    /// 来源筛选:nil = 全部;否则是某个类别或某个订阅源。
    @State private var kindFilter: NewsFeedKind?
    @State private var feedFilter: UUID?
    @State private var isRefreshing = false
    @State private var showAddFeed = false
    @State private var routineSheet: RoutineSheet?

    @AppStorage(AppSettings.newsFontSizeKey) private var fontSizeRaw = NewsFontSize.standard.rawValue
    @AppStorage(AppSettings.newsMarginKey) private var marginRaw = NewsMargin.standard.rawValue
    @State private var showReadingSettings = false

    @State private var digest: NewsDigest?
    @State private var digestGeneratedAt: Date?
    @State private var digestTask: Task<Void, Never>?
    @State private var digestError: String?

    private struct RoutineSheet: Identifiable {
        let routine: AIRoutine
        let isNew: Bool
        var id: UUID { routine.uuid }
    }

    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }
    private var accentPalette: AccentPalette {
        AccentPalette(rawValue: accentPaletteRaw) ?? .terracotta
    }

    private var filtered: [NewsArticle] {
        let kinds = Dictionary(uniqueKeysWithValues: feeds.map { ($0.uuid, $0.kind) })
        return articles.filter { article in
            switch readFilter {
            case .all, .today: break
            case .unread: if article.isRead { return false }
            case .starred: if !article.isStarred { return false }
            }
            if let feedFilter, article.feedUUID != feedFilter { return false }
            if let kindFilter, kinds[article.feedUUID] != kindFilter { return false }
            return true
        }
    }

    private var sections: [(day: Date, articles: [NewsArticle])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.publishedAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }

    private var newsRoutine: AIRoutine? { routines.first(where: \.includeNews) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if feeds.isEmpty {
                    emptyState
                } else {
                    Section {
                        Picker("筛选", selection: $readFilter) {
                            ForEach(ReadFilter.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowSeparator(.hidden)
                        // 「今日」的总结和切换条放在同一个 section 里:分成两个 section
                        // 中间会隔着一大截分区间距(用户要求尽量贴近)。
                        if readFilter == .today {
                            todaySections
                        }
                    }
                    if readFilter != .today {
                        articleSections
                    }
                }
            }
            // 筛选分段控件紧贴导航栏:List 默认给第一个 section 留的那截顶部空白
            // 让它看上去像飘在页面中间。
            .contentMargins(.top, 4, for: .scrollContent)
            .pageTitle("新闻")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sidebarToolbarButton()
            .toolbar {
                if !(sidebarChrome?.hidesChrome ?? false) {
                    ToolbarItem(placement: .primaryAction) { toolbarMenu }
                }
            }
            .refreshable { await refresh(force: true) }
            .askBar(focus: .news, isVisible: path.isEmpty)
            .navigationDestination(for: NewsRoute.self) { route in
                switch route {
                case .article(let article):
                    NewsArticleView(article: article)
                case .feeds:
                    NewsFeedsView()
                }
            }
            .sheet(isPresented: $showAddFeed) {
                NewsFeedAddView()
                    .tint(accentPalette.accent)
                    .environment(\.lodoAccent, accentPalette)
            }
            .sheet(isPresented: $showReadingSettings) {
                NewsReadingSettingsView()
                    .tint(accentPalette.accent)
                    .environment(\.lodoAccent, accentPalette)
            }
            .sheet(item: $routineSheet) { sheet in
                RoutineEditView(routine: sheet.routine, isNew: sheet.isNew)
                    .tint(accentPalette.accent)
                    .environment(\.lodoAccent, accentPalette)
            }
            .task(id: sectionIsActive) {
                // 页面每次切回来时按需刷一次(抓过不到半小时的源会被跳过)。
                guard sectionIsActive else { return }
                await refresh(force: false)
            }
            .onAppear {
                if digest == nil, let cached = NewsStore.cachedDigest() {
                    digest = cached.digest
                    digestGeneratedAt = cached.generatedAt
                }
                #if DEBUG
                applyDemoArgumentsIfNeeded()
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    // MARK: - 文章流

    @ViewBuilder
    private var articleSections: some View {
        if activeSourceTitle != nil { sourceFilterBanner }
        if filtered.isEmpty {
            Section {
                Text(emptyFilterText)
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(sections, id: \.day) { section in
            Section {
                ForEach(section.articles) { article in
                    NavigationLink(value: NewsRoute.article(article)) {
                        NewsArticleRow(article: article)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            NewsStore.setRead(article, !article.isRead, context: context)
                        } label: {
                            Label(LocalizedStringKey(article.isRead ? "标为未读" : "标为已读"),
                                  systemImage: article.isRead ? "circle" : "checkmark.circle")
                        }
                        .tint(LodoColor.neutralAction)
                        Button {
                            NewsStore.toggleStar(article, context: context)
                        } label: {
                            Label(LocalizedStringKey(article.isStarred ? "取消收藏" : "收藏"),
                                  systemImage: article.isStarred ? "star.slash" : "star")
                        }
                        .tint(.accentColor)
                    }
                }
            } header: {
                Text(dayTitle(section.day))
            }
        }
    }

    // MARK: - 空态与筛选

    private var emptyState: some View {
        Section {
            ContentUnavailableView {
                Label("还没有订阅", systemImage: "newspaper")
            } description: {
                Text("订阅新闻网站或博客的 RSS,文章会按天排在这里。AI 可以总结单篇、生成今日简报,也能在订阅里帮你找文章。")
            } actions: {
                Button("添加订阅") { showAddFeed = true }
                    .buttonStyle(.borderedProminent)
                Button("看看推荐订阅") { path = [.feeds] }
            }
        }
    }

    private var emptyFilterText: LocalizedStringKey {
        switch readFilter {
        case .unread: return "都读完了。"
        case .starred: return "还没有收藏的文章。左滑文章可以收藏。"
        case .all, .today: return articles.isEmpty ? "正在抓取订阅…下拉可以手动刷新。" : "这个来源下还没有文章。"
        }
    }

    private var activeSourceTitle: String? {
        if let feedFilter { return feeds.first { $0.uuid == feedFilter }?.title }
        return kindFilter?.title
    }

    private var sourceFilterBanner: some View {
        Section {
            Button {
                kindFilter = nil
                feedFilter = nil
            } label: {
                Label("清除筛选:\(activeSourceTitle ?? "")", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: - 今日简报

    /// 「今日」:今日总结(一句话概览 + 几条要闻),每条下面挂着它依据的那几篇
    /// 文章(参考新闻链接,点了进文章详情)。点了才生成、按天缓存(同原来的简报)。
    @ViewBuilder
    private var todaySections: some View {
        if !DeepSeekClient.isConfigured {
            Text("在设置里配置 AI 服务商后,这里会把最近 24 小时的文章整理成今日总结。")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            // 不分 section、不垫卡片底:整份总结就是一篇直接排在页面上的文字。
            VStack(alignment: .leading, spacing: 18) {
                todayHeader
                if let digest {
                    if !digest.overview.isEmpty {
                        Text(digest.overview)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(digest.items.enumerated()), id: \.offset) { index, item in
                        todayParagraph(index: index, item: item)
                    }
                } else if digestTask == nil {
                    Button {
                        generateDigest()
                    } label: {
                        Label("生成今日总结", systemImage: "sparkles")
                            .font(.body.weight(.semibold))
                    }
                    .pressable()
                    .disabled(articles.isEmpty)
                }
                if digestTask != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在整理今日总结…").foregroundStyle(.secondary)
                    }
                }
                if let digestError {
                    Text(digestError)
                        .font(.subheadline)
                        .foregroundStyle(LodoColor.critical)
                }
                if digest == nil, articles.isEmpty {
                    Text("还没有抓到文章,下拉可以手动刷新。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .dynamicTypeSize(readingFontSize.dynamicTypeSize)
            .padding(.horizontal, readingMargin.points - 20)
            .padding(.bottom, 6)
            // 顶部只留一点缝:紧贴在切换条下面。
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// 「今日总结 · 01:36 整理」+ 右边重新生成。
    private var todayHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今日总结")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let digestGeneratedAt, digest != nil {
                    Text("\(digestGeneratedAt, format: .dateTime.hour().minute()) 根据最近 24 小时的文章整理")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if digest != nil && digestTask == nil {
                Button {
                    generateDigest()
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tint)
                }
                .pressable()
            }
        }
    }

    /// 一段要闻:「1. 标题」加粗接说明,后面跟着「来自少数派 ›」这样的小按钮,
    /// 每篇参考文章一颗,点了进那篇文章。
    private func todayParagraph(index: Int, item: NewsDigest.Item) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Text(verbatim: "\(index + 1). \(item.title)").fontWeight(.semibold)) \(item.detail)")
                .font(.body)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            let refs = referencedArticles(item)
            if !refs.isEmpty {
                WrappingHStack(spacing: 6) {
                    ForEach(refs) { article in
                        Button {
                            path.append(.article(article))
                        } label: {
                            HStack(spacing: 2) {
                                Text("来自\(article.feedTitle)")
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                        .pressable()
                        .accessibilityLabel(Text("参考:\(article.feedTitle),\(article.title)"))
                    }
                }
            }
        }
    }

    private var readingFontSize: NewsFontSize { NewsFontSize.stored(fontSizeRaw) }
    private var readingMargin: NewsMargin { NewsMargin.stored(marginRaw) }

    /// 一条要闻依据的文章(按模型给的顺序;文章已被清理掉的跳过)。
    private func referencedArticles(_ item: NewsDigest.Item) -> [NewsArticle] {
        (item.articleIDs ?? []).compactMap { id in articles.first { $0.uuid == id } }
    }

    private func generateDigest() {
        digestError = nil
        digestTask = Task {
            do {
                if let result = try await NewsStore.generateDigest(language: language, context: context) {
                    digest = result
                    digestGeneratedAt = Date()
                } else {
                    digestError = LocalizedStrings.text(.ios_core_news_no_recent_articles,
                                                        language: language)
                }
            } catch is CancellationError {
            } catch {
                digestError = error.localizedDescription
            }
            digestTask = nil
        }
    }

    // MARK: - 右上角

    private var toolbarMenu: some View {
        Menu {
            Button {
                showAddFeed = true
            } label: {
                Label("添加订阅", systemImage: "plus")
            }
            Button {
                showReadingSettings = true
            } label: {
                Label("阅读设置", systemImage: "textformat.size")
            }
            Button {
                path = [.feeds]
            } label: {
                Label("管理订阅", systemImage: "list.bullet")
            }
            Button {
                openRoutine()
            } label: {
                if let newsRoutine {
                    Label(String(localized: "定时推送:\(LocalizedContent.routineCaption(newsRoutine))",
                                 bundle: .appLanguage(language), locale: language.locale), systemImage: "bell.badge")
                } else {
                    Label("定时推送", systemImage: "bell.badge")
                }
            }
            if !feeds.isEmpty {
                Menu {
                    Picker("来源", selection: sourceSelection) {
                        Text("全部来源").tag(SourceSelection.all)
                        ForEach(NewsFeedKind.allCases, id: \.self) { kind in
                            Label(LocalizedStringKey(kind.title), systemImage: kind.symbol)
                                .tag(SourceSelection.kind(kind))
                        }
                        ForEach(feeds) { feed in
                            Text(feed.title).tag(SourceSelection.feed(feed.uuid))
                        }
                    }
                } label: {
                    Label("按来源筛选", systemImage: "line.3.horizontal.decrease.circle")
                }
                Button {
                    NewsStore.markAllRead(filtered, context: context)
                } label: {
                    Label("全部标为已读", systemImage: "checkmark.circle")
                }
                .disabled(!filtered.contains { !$0.isRead })
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }

    private enum SourceSelection: Hashable {
        case all
        case kind(NewsFeedKind)
        case feed(UUID)
    }

    private var sourceSelection: Binding<SourceSelection> {
        Binding(
            get: {
                if let feedFilter { return .feed(feedFilter) }
                if let kindFilter { return .kind(kindFilter) }
                return .all
            },
            set: { value in
                switch value {
                case .all: kindFilter = nil; feedFilter = nil
                case .kind(let kind): kindFilter = kind; feedFilter = nil
                case .feed(let uuid): feedFilter = uuid; kindFilter = nil
                }
            }
        )
    }

    /// 已经有带新闻的定时任务就打开它,没有就用模板新建一条。
    private func openRoutine() {
        if let newsRoutine {
            routineSheet = RoutineSheet(routine: newsRoutine, isNew: false)
        } else {
            routineSheet = RoutineSheet(
                routine: AIRoutine(preset: AIRoutine.newsDigestPreset), isNew: true)
        }
    }

    // MARK: - 其他

    private func refresh(force: Bool) async {
        guard !isRefreshing, !feeds.isEmpty else { return }
        isRefreshing = true
        await NewsStore.refreshAll(context: context, force: force)
        isRefreshing = false
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "今天", bundle: .appLanguage(language), locale: language.locale) }
        if calendar.isDateInYesterday(day) { return String(localized: "昨天", bundle: .appLanguage(language), locale: language.locale) }
        return day.formatted(.dateTime.month().day().weekday().locale(language.locale))
    }

    #if DEBUG
    /// 截图验证用:不走网络,直接塞两个订阅源和几篇样板文章。
    private func applyDemoArgumentsIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo-news") else { return }
        if feeds.isEmpty { seedDemoNews() }
        if args.contains("--demo-news-digest"), digest == nil {
            // 参考文章按标题关键词找样板文章。
            let all = NewsStore.articles(in: context)
            // 库里是真实文章(没有样板标题)时,依次拿最新的几篇凑参考。
            var fallback = all.makeIterator()
            func refs(_ keywords: String...) -> [UUID] {
                keywords.compactMap { key in (all.first { $0.title.contains(key) } ?? fallback.next())?.uuid }
            }
            digest = NewsDigest(overview: "科技圈在等苹果发布会,电动车价格战继续。", items: [
                .init(title: "苹果秋季发布会定档", detail: "新 iPhone 与 Apple Watch 预计同场亮相,重点是端侧 AI。",
                      source: "", articleIDs: refs("苹果秋季", "AI 手机")),
                .init(title: "电动车降价潮蔓延到中型车", detail: "三家品牌一周内先后调价,供应链压力加大。",
                      source: "", articleIDs: refs("电动车")),
                .init(title: "科技爱好者周刊更新", detail: "本期聊到个人知识库的整理方法。",
                      source: "", articleIDs: refs("周刊")),
            ])
            digestGeneratedAt = Date()
            readFilter = .today
        }
        if args.contains("--demo-news-article"), let first = articles.first ?? NewsStore.articles(in: context).first {
            path = [.article(first)]
        }
        if args.contains("--demo-news-feeds") { path = [.feeds] }
        if args.contains("--demo-news-reading-settings") { showReadingSettings = true }
    }

    private func seedDemoNews() {
        let now = Date()
        let sspai = NewsFeed(title: "少数派", url: "https://sspai.com/feed",
                             siteURL: "https://sspai.com", kind: .news)
        let kr = NewsFeed(title: "36氪", url: "https://36kr.com/feed", siteURL: "https://36kr.com", kind: .news)
        let blog = NewsFeed(title: "阮一峰的网络日志", url: "https://www.ruanyifeng.com/blog/atom.xml",
                            siteURL: "https://www.ruanyifeng.com/blog/", kind: .blog)
        for feed in [sspai, kr, blog] {
            feed.lastFetchedAt = now
            context.insert(feed)
        }
        let samples: [(NewsFeed, String, String, TimeInterval, Bool)] = [
            (sspai, "苹果秋季发布会定档,这些新品值得期待", "新 iPhone、Apple Watch 与 AirPods 预计同场亮相,端侧 AI 是这次的重点。", 1800, false),
            (kr, "电动车降价潮蔓延到中型车市场", "三家品牌在一周内先后调价,分析认为供应链压力会继续向上游传导。", 5400, false),
            (sspai, "我的 2026 桌面改造:从键盘到显示器", "花了半年时间慢慢调整,最终留下的都是真正每天用得上的东西。", 20000, true),
            (blog, "科技爱好者周刊(第 380 期):个人知识库怎么整理", "这里记录每周值得分享的科技内容,周五发布。", 90000, false),
            (kr, "AI 手机渗透率首次超过三成", "端侧大模型成为中高端机型的标配卖点。", 100000, true),
        ]
        for (index, (feed, title, summary, ago, read)) in samples.enumerated() {
            // 第一篇挂一个真实文章链接,截图时能看到全文抓取的效果。
            let link = index == 0 ? "https://sspai.com/post/114958" : feed.siteURL
            let article = NewsArticle(feedUUID: feed.uuid, feedTitle: feed.title, guid: title,
                                      link: link, title: title, summary: summary,
                                      publishedAt: now.addingTimeInterval(-ago), fetchedAt: now)
            article.isRead = read
            context.insert(article)
        }
        try? context.save()
    }
    #endif
}

/// 放不下就换行的一排(「今日」每段后面那几颗「来自xx ›」)。系统 `Layout` 协议,
/// 只算位置、不画东西。
struct WrappingHStack: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// 文章流里的一行:来源 · 时间,标题(已读的变淡),两行摘要。
struct NewsArticleRow: View {
    let article: NewsArticle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if !article.isRead {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("未读")
                }
                Text(article.feedTitle)
                Text("·")
                Text(article.publishedAt, format: .dateTime.hour().minute())
                if article.isStarred {
                    Image(systemName: "star.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("已收藏")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Text(article.title)
                .font(.body.weight(.medium))
                .foregroundStyle(article.isRead ? .secondary : .primary)
                .lineLimit(3)
            if !article.summary.isEmpty {
                Text(article.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
