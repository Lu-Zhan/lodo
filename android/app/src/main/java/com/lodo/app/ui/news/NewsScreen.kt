package com.lodo.app.ui.news

import android.app.Application
import android.app.TimePickerDialog
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
import androidx.compose.foundation.lazy.LazyRow
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
import androidx.compose.material3.AlertDialog
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.first
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
    var feedDigest by mutableStateOf<NewsRepository.DigestCache?>(null)
        private set
    private var selectedDigestFeedUuid: String? = null
    var categories by mutableStateOf(app.news.cachedCategories())
        private set
    var digesting by mutableStateOf(false)
        private set
    var message by mutableStateOf<String?>(null)

    fun refresh(force: Boolean) = viewModelScope.launch {
        refreshing = true
        runCatching { app.news.refresh(force) }
        refreshing = false
    }

    fun loadFeedDigest(uuid: String?) {
        selectedDigestFeedUuid = uuid
        feedDigest = uuid?.let(app.news::cachedDigest)
    }
    fun runDueDigest(force: Boolean = false) = viewModelScope.launch {
        val time = app.settings.snapshot().newsDigestTime
        val due = runCatching { java.time.LocalTime.parse(time) }.getOrDefault(java.time.LocalTime.of(9, 0))
        val shouldGenerate = force || (!java.time.LocalTime.now().isBefore(due) && !app.news.scheduledDoneToday())
        if (shouldGenerate) {
            digesting = true; message = null
            runCatching { app.news.runScheduledDigests(app.settings.aiConfig(), time, force) }
                .onFailure { message = it.message }
        }
        digest = app.news.cachedDigest()
        categories = app.news.cachedCategories()
        feedDigest = selectedDigestFeedUuid?.let(app.news::cachedDigest)
        digesting = false
    }
    fun renameCategory(old: String, new: String) {
        app.news.renameCategory(old, new)
        categories = app.news.cachedCategories()
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
    /**
     * 「定时推送」(同 iOS 新闻页菜单):定时推送不是另一套机制,就是一条提到新闻的定时任务——
     * 跑之前会刷订阅、带上最近 24 小时的文章。已有就如实说,没有就按预设每天 08:00 建一条。
     */
    fun ensureDigestRoutine(onResult: (String) -> Unit) = viewModelScope.launch {
        val existing = app.database.routineDao().observeAll().first().firstOrNull { NEWS_ROUTINE.containsMatchIn(it.prompt) }
        if (existing != null) {
            onResult(L("已经有定时推送:「${existing.prompt.take(20)}」,在设置 → 定时任务里可以改", "You already have a news routine; edit it in Settings → Routines"))
            return@launch
        }
        val now = java.time.LocalDateTime.now()
        val at = now.toLocalDate().atTime(8, 0).let { if (it.isAfter(now)) it else it.plusDays(1) }
        app.routineRepository.save(
            L("今日新闻简报:从最近 24 小时的订阅里挑最重要的几件事,每件一两句,写成一份简报。",
                "Daily news brief: pick the most important stories from the last 24 hours of my feeds, one or two sentences each."),
            at, com.lodo.app.core.RepeatType.DAILY, emptyList(), listOf("08:00"),
        )
        onResult(L("已建好「今日新闻简报」,每天 08:00 推送;在设置 → 定时任务里可以改", "Created a daily 08:00 news brief; edit it in Settings → Routines"))
    }

    fun setSummaryLanguage(v: String) = viewModelScope.launch { app.settings.setNewsSummaryLanguage(v) }
    fun setDigestTime(v: String) = viewModelScope.launch { app.settings.setNewsDigestTime(v) }
}

/**
 * 「新闻」页,对应 iOS NewsListView:订阅 RSS/Atom;顶部「今日/全部/未读/已收藏」切换;
 * 「今日」是 AI 总结的要闻(按天缓存,每条下面挂参考文章);打开文章是阅读模式,自动抓全文、
 * 没总结过时自动 AI 总结(默认收起)。AI 搜索走底部「问问 AI」(search_news),页面上不另摆搜索框。
 */
@Composable
fun NewsScreen(vm: NewsViewModel = viewModel()) {
    val settings = LocalSettings.current
    val feeds by vm.feeds.collectAsStateWithLifecycle()
    val articles by vm.articles.collectAsStateWithLifecycle()
    var tab by rememberSaveable { mutableStateOf(1) }
    var openUuid by rememberSaveable { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    var manage by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var reading by remember { mutableStateOf(false) }
    var selectedFeed by rememberSaveable { mutableStateOf<String?>(null) }
    LaunchedEffect(feeds.size) { if (feeds.isNotEmpty()) vm.refresh(false) }
    LaunchedEffect(feeds.isNotEmpty(), settings.newsDigestTime) {
        while (feeds.isNotEmpty()) {
            vm.runDueDigest()
            delay(60_000)
        }
    }
    val feedById = feeds.associateBy { it.uuid }
    openUuid?.let { uuid ->
        articles.firstOrNull { it.uuid == uuid }?.let { a ->
            ArticleView(a, feedById[a.feedUuid]?.title ?: "", vm, onSettings = { reading = true }) { openUuid = null }
            if (reading) ReadingSettings(vm) { reading = false }
            return
        }
    }
    val toastContext = androidx.compose.ui.platform.LocalContext.current
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
                    DropdownMenuItem(text = { Text(L("新闻设置", "News settings")) }, onClick = { menu = false; reading = true })
                    DropdownMenuItem(text = { Text(L("定时推送", "Scheduled brief")) }, onClick = {
                        menu = false
                        vm.ensureDigestRoutine { msg -> android.widget.Toast.makeText(toastContext, msg, android.widget.Toast.LENGTH_LONG).show() }
                    })
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
            val tabs = listOf(L("总结", "Summary"), L("全部", "All"), L("未读", "Unread"), L("已收藏", "Starred"))
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = PaddingValues(horizontal = 16.dp)) {
                items(tabs.size) { index ->
                    val label = tabs[index]
                    FilterChip(selected = tab == index, onClick = { tab = index }, label = { Text(label) })
                }
            }
            if (tab == 1 || tab == 2) LazyRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                contentPadding = PaddingValues(horizontal = 16.dp),
            ) {
                item { FilterChip(selected = selectedFeed == null, onClick = { selectedFeed = null }, label = { Text(L("全部", "All")) }) }
                items(feeds, key = { it.uuid }) { feed ->
                    FilterChip(selected = selectedFeed == feed.uuid, onClick = { selectedFeed = feed.uuid },
                        label = { Text(shortNewsTag(feed.title)) })
                }
            }
            PullToRefreshBox(isRefreshing = vm.refreshing, onRefresh = { vm.refresh(true) }, modifier = Modifier.weight(1f)) {
                if (tab == 0) DigestView(vm, articles, feedById, onSettings = { reading = true }) { openUuid = it }
                else {
                    val list = articles.filter { feedById[it.feedUuid]?.enabled != false || it.starred }.filter {
                        (selectedFeed == null || tab == 3 || it.feedUuid == selectedFeed) &&
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
private fun DigestView(vm: NewsViewModel, articles: List<NewsArticleEntity>, feeds: Map<String, NewsFeedEntity>,
                       onSettings: () -> Unit, open: (String) -> Unit) {
    val settings = LocalSettings.current
    val byId = articles.associateBy { it.uuid }
    var selectedFeed by rememberSaveable { mutableStateOf<String?>(null) }
    var selectedCategory by rememberSaveable { mutableStateOf<String?>(null) }
    var rename by remember { mutableStateOf(false) }
    var renameText by remember { mutableStateOf("") }
    LaunchedEffect(feeds.keys) {
        if (selectedFeed !in feeds.keys) selectedFeed = feeds.values.firstOrNull { it.enabled }?.uuid
        vm.loadFeedDigest(selectedFeed)
    }
    val categories = vm.categories?.categories.orEmpty()
    val category = categories.firstOrNull { it.first == selectedCategory } ?: categories.firstOrNull()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = marginFor(settings.newsMargin), vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onSettings, modifier = Modifier.weight(1f)) {
                    Text(L("每日 ${settings.newsDigestTime} 统一总结", "Daily summary at ${settings.newsDigestTime}"))
                }
                if (vm.digesting) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                else TextButton(onClick = { vm.runDueDigest(force = true) }) { Text(L("立即更新全部", "Update all now")) }
            }
        }
        item { DigestBlock(L("一览", "Overview"), vm.digest, byId, feeds, open) }
        item { HorizontalDivider() }
        item { Text(L("分 RSS", "By RSS"), style = MaterialTheme.typography.titleMedium) }
        item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(feeds.values.filter { it.enabled }.toList(), key = { it.uuid }) { feed ->
                    FilterChip(selected = selectedFeed == feed.uuid, onClick = { selectedFeed = feed.uuid; vm.loadFeedDigest(feed.uuid) },
                        label = { Text(shortNewsTag(feed.title)) })
                }
            }
        }
        item {
            DigestBlock(selectedFeed?.let(feeds::get)?.title ?: L("选择来源", "Choose a feed"), vm.feedDigest,
                byId, feeds, open)
        }
        item { HorizontalDivider() }
        item { Text(L("按内容", "By topic"), style = MaterialTheme.typography.titleMedium) }
        if (categories.isNotEmpty()) item {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(categories, key = { it.first }) { entry ->
                    FilterChip(selected = category?.first == entry.first, onClick = { selectedCategory = entry.first },
                        label = { Text(shortNewsTag(entry.first)) })
                }
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(category?.first ?: L("分类总结", "Topic summary"), modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                if (category != null) TextButton(onClick = { renameText = category.first; rename = true }) { Text(L("改名", "Rename")) }
            }
            DigestBlock("", category?.second, byId, feeds, open)
        }
        vm.message?.let { item { Text(it, color = LodoColor.critical, style = MaterialTheme.typography.bodySmall) } }
    }
    if (rename) AlertDialog(onDismissRequest = { rename = false }, title = { Text(L("重命名分类", "Rename topic")) },
        text = { OutlinedTextField(renameText, { renameText = it }, label = { Text(L("分类名称", "Topic name")) }) },
        confirmButton = { TextButton(onClick = { category?.let { vm.renameCategory(it.first, renameText) }; selectedCategory = renameText.trim(); rename = false }) { Text(L("保存", "Save")) } },
        dismissButton = { TextButton(onClick = { rename = false }) { Text(L("取消", "Cancel")) } })
}

private fun shortNewsTag(name: String): String = name.trim().removeSuffix("的 RSS 订阅").removeSuffix(" RSS")
    .let { if (it.length > 12) it.take(11) + "…" else it }

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun DigestBlock(title: String, cache: NewsRepository.DigestCache?,
                        byId: Map<String, NewsArticleEntity>, feeds: Map<String, NewsFeedEntity>, open: (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (title.isNotEmpty()) Text(title, style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary)
        if (cache == null) Text(L("到每日总结时间后自动生成。", "Generated after the daily summary time."),
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        else {
            if (cache.digest.overview.isNotBlank()) Text(cache.digest.overview, style = MaterialTheme.typography.titleMedium)
            cache.digest.items.forEachIndexed { i, item ->
                Text("${i + 1}. ${item.title}", style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold)
                if (item.detail.isNotBlank()) Text(item.detail, style = MaterialTheme.typography.bodyMedium)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    cache.refs.getOrNull(i).orEmpty().mapNotNull { byId[it] }.forEach { article ->
                        AssistChip(onClick = { open(article.uuid) }, label = {
                            Text(L("来自", "From ") + (feeds[article.feedUuid]?.title ?: "") + " ›", maxLines = 1)
                        })
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
    val context = LocalContext.current
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(L("新闻设置", "News settings"), style = MaterialTheme.typography.titleMedium)
            // 总结语言:已总结过的文章不自动重写,展开的 AI 总结下有「重新总结」(同 iOS)。
            Text(L("总结语言", "Summary language"), style = MaterialTheme.typography.titleSmall)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                com.lodo.app.core.NewsSummaryLanguage.entries.forEach { lang ->
                    FilterChip(s.newsSummaryLanguage == lang.raw, { vm.setSummaryLanguage(lang.raw) },
                        label = { Text(lang.displayName(com.lodo.app.ui.UiLang.current == com.lodo.app.core.Lang.EN)) })
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(L("每日总结时间", "Daily summary time"), style = MaterialTheme.typography.titleSmall,
                    modifier = Modifier.weight(1f))
                TextButton(onClick = {
                    val parts = s.newsDigestTime.split(':').mapNotNull(String::toIntOrNull)
                    TimePickerDialog(context, { _, hour, minute ->
                        vm.setDigestTime("%02d:%02d".format(hour, minute))
                    }, parts.getOrElse(0) { 9 }, parts.getOrElse(1) { 0 }, true).show()
                }) { Text(s.newsDigestTime) }
            }
            Text(L("每天到这个时间统一整理一览、各 RSS 来源和内容分类。系统若延迟后台运行,下次打开应用会补做。",
                "Summaries run daily at this time; missed background work runs when you reopen the app."),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
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

/** 认得出是新闻类定时任务的指令(和 RoutineRepository 带新闻上下文的判据同一个)。 */
private val NEWS_ROUTINE = Regex("新闻|订阅|简报|博客|news|feed", RegexOption.IGNORE_CASE)
