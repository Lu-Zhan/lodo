package com.lodo.app.ui.news

import android.app.Application
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.OpenInBrowser
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material.icons.outlined.StarBorder
import androidx.compose.material.icons.outlined.TextFields
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.LodoApp
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.core.ArticleBlock
import com.lodo.app.data.NewsArticleEntity
import com.lodo.app.data.NewsFeedEntity
import com.lodo.app.data.NewsRepository
import com.lodo.app.data.toLocalDateTime
import com.lodo.app.ui.FullEmpty
import com.lodo.app.ui.L
import com.lodo.app.ui.LocalSettings
import com.lodo.app.ui.LodoPage
import com.lodo.app.ui.LodoSubPage
import com.lodo.app.ui.SegmentedTabs
import com.lodo.app.ui.assets.SheetHeader
import com.lodo.app.ui.theme.LodoColor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.time.LocalDate
import java.time.format.DateTimeFormatter

class NewsViewModel(application: Application) : AndroidViewModel(application) {
    val app = application as LodoApp
    val feeds = app.news.observeFeeds().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val articles = app.news.observeArticles().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    var refreshing by mutableStateOf(false)
        private set
    var digest by mutableStateOf<NewsRepository.DigestCache?>(app.news.cachedDigest())
        private set
    var digesting by mutableStateOf(false)
        private set
    var message by mutableStateOf<String?>(null)

    fun refresh(force: Boolean) = viewModelScope.launch {
        refreshing = true
        runCatching { app.news.refresh(force) }
        refreshing = false
    }

    fun generateDigest() = viewModelScope.launch {
        digesting = true; message = null
        runCatching { app.news.generateDigest(app.settings.aiConfig()) }.onSuccess { digest = it }.onFailure { message = it.message }
        digesting = false
    }

    fun subscribe(url: String?, name: String?, kind: String, done: () -> Unit) = viewModelScope.launch {
        refreshing = true; message = null
        message = when (val r = app.news.subscribe(url, name, kind)) {
            is NewsRepository.SubscribeResult.Added -> { done(); null }
            is NewsRepository.SubscribeResult.AlreadySubscribed -> L("已经订过「${r.feed.title}」了", "Already subscribed to ${r.feed.title}")
            is NewsRepository.SubscribeResult.Failed -> r.reason
        }
        refreshing = false
    }

    fun updateFeed(f: NewsFeedEntity) = viewModelScope.launch { app.news.updateFeed(f) }
    fun deleteFeed(uuid: String) = viewModelScope.launch { app.news.deleteFeed(uuid) }
    fun setRead(uuid: String, read: Boolean) = viewModelScope.launch { app.news.setRead(uuid, read) }
    fun toggleStar(uuid: String) = viewModelScope.launch { app.news.toggleStar(uuid) }
    suspend fun content(a: NewsArticleEntity) = app.news.content(a)
    suspend fun summarize(a: NewsArticleEntity, force: Boolean) = app.news.summarize(app.settings.aiConfig(), a, force)
    fun setFont(v: Int) = viewModelScope.launch { app.settings.setNewsFontSize(v) }
    fun setMargin(v: Int) = viewModelScope.launch { app.settings.setNewsMargin(v) }
}

/**
 * 「新闻」页,对应 iOS NewsListView:订阅 RSS/Atom;顶部「今日/全部/未读/已收藏」切换;
 * 「今日」是 AI 总结的要闻(按天缓存,每条下面挂参考文章);打开文章是阅读模式,自动抓全文、
 * 没总结过时自动 AI 总结(默认收起)。AI 搜索走底部「问问 AI」(search_news),页面上不另摆搜索框。
 */
@Composable
fun NewsScreen(vm: NewsViewModel = viewModel()) {
    val feeds by vm.feeds.collectAsStateWithLifecycle()
    val articles by vm.articles.collectAsStateWithLifecycle()
    var tab by rememberSaveable { mutableStateOf(1) }
    var openUuid by rememberSaveable { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    var manage by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var reading by remember { mutableStateOf(false) }
    LaunchedEffect(feeds.size) { if (feeds.isNotEmpty()) vm.refresh(false) }
    val feedById = feeds.associateBy { it.uuid }
    openUuid?.let { uuid ->
        articles.firstOrNull { it.uuid == uuid }?.let { a ->
            ArticleView(a, feedById[a.feedUuid]?.title ?: "", vm, onSettings = { reading = true }) { openUuid = null }
            if (reading) ReadingSettings(vm) { reading = false }
            return
        }
    }
    LodoPage(
        title = L("新闻", "News"),
        focus = AgentFocus(AgentPageFocus.NEWS),
        askPrompt = L("最近发生了什么?", "What's new?"),
        actions = {
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, L("更多", "More")) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(L("添加订阅", "Add feed")) }, onClick = { menu = false; adding = true })
                    DropdownMenuItem(text = { Text(L("管理订阅", "Manage feeds")) }, onClick = { menu = false; manage = true })
                    DropdownMenuItem(text = { Text(L("阅读设置", "Reading settings")) }, onClick = { menu = false; reading = true })
                }
            }
        },
    ) { padding ->
        if (feeds.isEmpty()) {
            FullEmpty(Icons.AutoMirrored.Outlined.Article, L("还没有订阅", "No feeds yet"),
                L("贴个博客链接说「订阅这个」,或者从推荐里挑几个。", "Paste a blog link and say \"subscribe\", or pick from suggestions."), padding) {
                Button(onClick = { adding = true }) { Text(L("添加订阅", "Add feed")) }
            }
        } else Column(Modifier.fillMaxSize().padding(padding)) {
            SegmentedTabs(listOf(L("今日", "Today"), L("全部", "All"), L("未读", "Unread"), L("已收藏", "Starred")), tab, { tab = it })
            PullToRefreshBox(isRefreshing = vm.refreshing, onRefresh = { vm.refresh(true) }, modifier = Modifier.weight(1f)) {
                if (tab == 0) DigestView(vm, articles, feedById) { openUuid = it }
                else {
                    val list = articles.filter { feedById[it.feedUuid]?.enabled != false || it.starred }.filter {
                        when (tab) { 2 -> !it.read; 3 -> it.starred; else -> true }
                    }
                    val groups = list.groupBy { it.publishedMillis.toLocalDateTime().toLocalDate() }.toSortedMap(compareByDescending { it }).toList()
                    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        if (list.isEmpty()) item { Text(L("这里还没有文章", "No articles here"), color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(8.dp)) }
                        groups.forEach { (day, items) ->
                            item("h$day") { Text(dayLabel(day), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp, start = 4.dp)) }
                            items(items, key = { it.uuid }) { a -> ArticleRow(a, feedById[a.feedUuid]?.title ?: "", vm) { openUuid = a.uuid } }
                        }
                    }
                }
            }
        }
    }
    if (adding) AddFeedSheet(vm, feeds) { adding = false }
    if (manage) ManageFeedsSheet(vm, feeds, onAdd = { manage = false; adding = true }) { manage = false }
    if (reading) ReadingSettings(vm) { reading = false }
}

private fun dayLabel(day: LocalDate): String {
    val today = LocalDate.now()
    return when (day) {
        today -> L("今天", "Today")
        today.minusDays(1) -> L("昨天", "Yesterday")
        else -> day.format(com.lodo.app.ui.appFormatter(L("M月d日 EEEE", "EEE, MMM d")))
    }
}

@Composable
private fun ArticleRow(a: NewsArticleEntity, source: String, vm: NewsViewModel, onClick: () -> Unit) {
    Card(onClick = onClick, shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Row(Modifier.fillMaxWidth().padding(14.dp), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                Text(a.title, style = MaterialTheme.typography.bodyLarge, fontWeight = if (a.read) FontWeight.Normal else FontWeight.SemiBold,
                    color = if (a.read) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.onSurface, maxLines = 3)
                Text(source + " · " + a.publishedMillis.toLocalDateTime().format(com.lodo.app.ui.appFormatter("HH:mm")),
                    style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (a.summary.isNotBlank()) Text(a.summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
            }
            IconButton(onClick = { vm.toggleStar(a.uuid) }) {
                Icon(if (a.starred) Icons.Filled.Star else Icons.Outlined.StarBorder, L("收藏", "Star"),
                    tint = if (a.starred) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline)
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DigestView(vm: NewsViewModel, articles: List<NewsArticleEntity>, feeds: Map<String, NewsFeedEntity>, open: (String) -> Unit) {
    val d = vm.digest
    val settings = LocalSettings.current
    val byId = articles.associateBy { it.uuid }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = marginFor(settings.newsMargin), vertical = 12.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.AutoAwesome, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(L("今日总结", "Today's brief") + (d?.let { " · " + java.time.Instant.ofEpochMilli(it.generatedAt).atZone(java.time.ZoneId.systemDefault()).format(com.lodo.app.ui.appFormatter("HH:mm")) + L(" 整理", "") } ?: ""),
                    style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.weight(1f))
                if (vm.digesting) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                else TextButton(onClick = vm::generateDigest) { Text(if (d == null) L("生成", "Generate") else L("重新生成", "Regenerate")) }
            }
            vm.message?.let { Text(it, color = LodoColor.critical, style = MaterialTheme.typography.bodySmall) }
        }
        if (d == null) item {
            Text(L("让 AI 从最近 24 小时的订阅里挑出最重要的几件事。", "Let AI pick the most important stories from the last 24 hours."),
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 12.dp))
        } else {
            if (d.digest.overview.isNotBlank()) item { Text(d.digest.overview, style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(vertical = 10.dp)) }
            d.digest.items.forEachIndexed { i, item ->
                item("d$i") {
                    Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("${i + 1}. " + item.title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                        if (item.detail.isNotBlank()) Text(item.detail, style = MaterialTheme.typography.bodyMedium)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            d.refs.getOrNull(i).orEmpty().mapNotNull { byId[it] }.forEach { a ->
                                AssistChip(onClick = { open(a.uuid) }, label = { Text(L("来自", "From ") + (feeds[a.feedUuid]?.title ?: "") + " ›", maxLines = 1) })
                            }
                        }
                    }
                }
            }
        }
    }
}

fun marginFor(level: Int) = when (level) { 0 -> 12.dp; 2 -> 36.dp; else -> 20.dp }
fun fontScaleFor(level: Int) = listOf(0.85f, 0.93f, 1f, 1.12f, 1.25f).getOrElse(level) { 1f }

/** 极简的网络图片:OkHttp 拉、内存 LRU 缓存,加载失败整块不占位(同 iOS AsyncImage 的取舍)。 */
private object ImageCache {
    val client = OkHttpClient()
    val cache = LruCache<String, Bitmap>(40)
}

@Composable
private fun NetImage(url: String) {
    val bitmap by produceState<Bitmap?>(ImageCache.cache.get(url), url) {
        if (value == null) value = withContext(Dispatchers.IO) {
            runCatching {
                ImageCache.client.newCall(Request.Builder().url(url).build()).execute().use { r ->
                    r.body?.bytes()?.let { bytes ->
                        val opts = BitmapFactory.Options().apply { inSampleSize = 1 }
                        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
                    }
                }
            }.getOrNull()?.also { ImageCache.cache.put(url, it) }
        }
    }
    bitmap?.let {
        Image(it.asImageBitmap(), null, contentScale = ContentScale.FillWidth,
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp).background(MaterialTheme.colorScheme.surfaceContainer, RoundedCornerShape(12.dp)))
    }
}

/** 阅读模式(同 iOS NewsArticleView):标题、时间、AI 总结(默认收起)、正文、阅读原文 + 来源信息。 */
@Composable
private fun ArticleView(a: NewsArticleEntity, source: String, vm: NewsViewModel, onSettings: () -> Unit, onBack: () -> Unit) {
    val context = LocalContext.current
    val settings = LocalSettings.current
    var blocks by remember(a.uuid) { mutableStateOf<List<ArticleBlock>?>(null) }
    var summary by remember(a.uuid) { mutableStateOf(DeepSeekClient.ArticleSummary.decode(a.aiSummaryJson)) }
    var summaryOpen by remember { mutableStateOf(false) }
    var summarizing by remember { mutableStateOf(false) }
    var summaryError by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(a.uuid) {
        vm.setRead(a.uuid, true)
        blocks = vm.content(a)
        if (summary == null) {
            summarizing = true
            runCatching { vm.summarize(a, false) }.onSuccess { summary = it }.onFailure { summaryError = it.message }
            summarizing = false
        }
    }
    val scale = fontScaleFor(settings.newsFontSize)
    LodoSubPage(
        title = "", onBack = onBack, focus = AgentFocus(AgentPageFocus.NEWS, a.title),
        actions = {
            IconButton(onClick = onSettings) { Icon(Icons.Outlined.TextFields, L("阅读设置", "Reading settings")) }
            IconButton(onClick = { vm.toggleStar(a.uuid) }) { Icon(if (a.starred) Icons.Filled.Star else Icons.Outlined.StarBorder, L("收藏", "Star")) }
            IconButton(onClick = {
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, a.title + "\n" + a.link), null))
            }) { Icon(Icons.Outlined.Share, L("分享", "Share")) }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
            Column(Modifier.widthIn(max = 680.dp).verticalScroll(rememberScrollState()).padding(horizontal = marginFor(settings.newsMargin), vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(a.title, fontSize = (26 * scale).sp, lineHeight = (34 * scale).sp, fontWeight = FontWeight.Bold)
                Text(source + " · " + a.publishedMillis.toLocalDateTime().format(com.lodo.app.ui.appFormatter("yyyy-MM-dd HH:mm")),
                    style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Card(onClick = { summaryOpen = !summaryOpen }, shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
                    Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.AutoAwesome, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer)
                            Spacer(Modifier.width(8.dp))
                            Text(when {
                                summarizing -> L("AI 总结中…", "Summarizing…")
                                summary != null -> if (summaryOpen) L("AI 总结", "AI summary") else summary!!.summary
                                else -> summaryError ?: L("AI 总结", "AI summary")
                            }, maxLines = if (summaryOpen) 3 else 2, color = MaterialTheme.colorScheme.onSecondaryContainer, modifier = Modifier.weight(1f))
                        }
                        if (summaryOpen) summary?.let { s ->
                            Text(s.summary, color = MaterialTheme.colorScheme.onSecondaryContainer)
                            s.points.forEach { Text("• $it", color = MaterialTheme.colorScheme.onSecondaryContainer) }
                            TextButton(onClick = {
                                summarizing = true
                                scope.launch { runCatching { vm.summarize(a, true) }.onSuccess { summary = it }; summarizing = false }
                            }) { Text(L("重新总结", "Summarize again")) }
                        }
                    }
                }
                val body = blocks
                if (body == null) Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
                else body.forEach { b ->
                    when (b) {
                        is ArticleBlock.Heading -> Text(b.text, fontSize = (20 * scale).sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 6.dp))
                        is ArticleBlock.Paragraph -> Text(b.text, fontSize = (17 * scale).sp, lineHeight = (27 * scale).sp)
                        is ArticleBlock.Quote -> Row {
                            Box(Modifier.width(3.dp).height(24.dp).background(MaterialTheme.colorScheme.primary))
                            Spacer(Modifier.width(10.dp))
                            Text(b.text, fontSize = (16 * scale).sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        is ArticleBlock.ListItem -> Text("• " + b.text, fontSize = (17 * scale).sp, lineHeight = (26 * scale).sp)
                        is ArticleBlock.Image -> NetImage(b.url)
                    }
                }
                HorizontalDivider()
                if (a.link.isNotBlank()) FilledTonalButton(onClick = { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(a.link))) } }) {
                    Icon(Icons.Outlined.OpenInBrowser, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(L("阅读原文", "Open original"))
                }
                Text(listOfNotNull(L("来源:", "Source: ") + source, a.author.takeIf { it.isNotBlank() }?.let { L("作者:", "Author: ") + it }, a.link)
                    .joinToString("\n"), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(32.dp))
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun AddFeedSheet(vm: NewsViewModel, feeds: List<NewsFeedEntity>, onDismiss: () -> Unit) {
    var url by remember { mutableStateOf("") }
    var blog by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SheetHeader(L("添加订阅", "Add feed"), url.isNotBlank() && !vm.refreshing, onDismiss) {
                vm.subscribe(url.trim(), null, if (blog) "blog" else "news", onDismiss)
            }
            OutlinedTextField(url, { url = it }, label = { Text(L("订阅地址或网站首页", "Feed or site URL")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(verticalAlignment = Alignment.CenterVertically) {
                FilterChip(!blog, { blog = false }, label = { Text(L("新闻", "News")) }); Spacer(Modifier.width(8.dp))
                FilterChip(blog, { blog = true }, label = { Text(L("博客", "Blog")) })
            }
            if (vm.refreshing) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            vm.message?.let { Text(it, color = LodoColor.critical) }
            Text(L("推荐", "Suggestions"), style = MaterialTheme.typography.titleSmall)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                NewsRepository.presets.filter { p -> feeds.none { it.url == p.url } }.forEach { p ->
                    AssistChip(onClick = { vm.subscribe(p.url, p.title, p.kind) {} }, label = { Text("+ " + p.title) })
                }
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ManageFeedsSheet(vm: NewsViewModel, feeds: List<NewsFeedEntity>, onAdd: () -> Unit, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(L("管理订阅", "Manage feeds"), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                TextButton(onClick = onAdd) { Text(L("添加", "Add")) }
            }
            feeds.forEach { f ->
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 6.dp)) {
                    Column(Modifier.weight(1f)) {
                        Text(f.title, fontWeight = FontWeight.Medium)
                        Text((if (f.kind == "blog") L("博客", "Blog") else L("新闻", "News")) + " · " + f.url, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                    }
                    Switch(f.enabled, { vm.updateFeed(f.copy(enabled = it)) })
                    IconButton(onClick = { vm.deleteFeed(f.uuid) }) { Icon(Icons.Filled.Close, L("删除订阅", "Unsubscribe")) }
                }
            }
            Text(L("删除订阅时收藏的文章会留下。", "Starred articles are kept when you unsubscribe."), style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(24.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun ReadingSettings(vm: NewsViewModel, onDismiss: () -> Unit) {
    val s = LocalSettings.current
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(L("阅读设置", "Reading settings"), style = MaterialTheme.typography.titleMedium)
            Text(L("字号", "Text size"), style = MaterialTheme.typography.titleSmall)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(L("很小", "XS"), L("小", "S"), L("标准", "M"), L("大", "L"), L("很大", "XL")).forEachIndexed { i, label ->
                    FilterChip(s.newsFontSize == i, { vm.setFont(i) }, label = { Text(label) })
                }
            }
            Text(L("边距", "Margins"), style = MaterialTheme.typography.titleSmall)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                listOf(L("窄", "Narrow"), L("标准", "Normal"), L("宽", "Wide")).forEachIndexed { i, label ->
                    FilterChip(s.newsMargin == i, { vm.setMargin(i) }, label = { Text(label) })
                }
            }
            Spacer(Modifier.height(32.dp))
        }
    }
}
