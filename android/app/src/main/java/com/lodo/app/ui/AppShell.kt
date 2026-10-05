package com.lodo.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Article
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.outlined.AccountBalanceWallet
import androidx.compose.material.icons.outlined.Bookmarks
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.Checklist
import androidx.compose.material.icons.outlined.Dashboard
import androidx.compose.material.icons.outlined.FavoriteBorder
import androidx.compose.material.icons.outlined.Flight
import androidx.compose.material.icons.outlined.HourglassTop
import androidx.compose.material.icons.outlined.People
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import kotlin.math.abs
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.LodoApp
import com.lodo.app.PendingRoute
import com.lodo.app.ai.AgentFocus
import com.lodo.app.data.Settings
import com.lodo.app.ui.agent.AgentChat
import com.lodo.app.ui.agent.AgentViewModel
import com.lodo.app.ui.assets.AssetsScreen
import com.lodo.app.ui.calendar.CalendarScreen
import com.lodo.app.ui.contacts.ContactsScreen
import com.lodo.app.ui.countdown.CountdownScreen
import com.lodo.app.ui.health.HealthScreen
import com.lodo.app.ui.memory.MemoryListScreen
import com.lodo.app.ui.menu.MenuScreen
import com.lodo.app.ui.news.NewsScreen
import com.lodo.app.ui.overview.OverviewScreen
import com.lodo.app.ui.settings.SettingsScreen
import com.lodo.app.ui.todo.TodoListScreen
import com.lodo.app.ui.travel.TravelScreen
import kotlinx.coroutines.launch

/** 十二个完全平级的页面,同 iOS AppSection(名字是持久化/深链用的,别改)。 */
enum class AppSection(val zh: String, val en: String, val icon: ImageVector) {
    OVERVIEW("总览", "Overview", Icons.Outlined.Dashboard),
    TASKS("任务", "Tasks", Icons.Outlined.Checklist),
    CALENDAR("日历", "Calendar", Icons.Outlined.CalendarMonth),
    COUNTDOWN("倒数", "Countdown", Icons.Outlined.HourglassTop),
    MEMORY("记忆", "Memory", Icons.Outlined.Bookmarks),
    CONTACTS("人脉", "People", Icons.Outlined.People),
    ASSETS("资产", "Assets", Icons.Outlined.AccountBalanceWallet),
    HEALTH("健康", "Health", Icons.Outlined.FavoriteBorder),
    TRAVEL("旅行", "Travel", Icons.Outlined.Flight),
    MENU("菜单", "Menu", Icons.AutoMirrored.Outlined.MenuBook),
    NEWS("新闻", "News", Icons.AutoMirrored.Outlined.Article),
    AGENT("AI 助手", "AI Assistant", Icons.Filled.AutoAwesome);

    val title get() = L(zh, en)
}

/** 页面外壳下发给各页的能力:打开导航、跳页、问问 AI、设置(同 iOS SidebarChrome + ItemNavigator)。 */
class ShellActions(
    val showMenuButton: Boolean,
    val openNav: () -> Unit,
    val go: (AppSection) -> Unit,
    val askAi: (AgentFocus?) -> Unit,
    val openSettings: () -> Unit,
    /** 跳到某次旅行(AI 卡片下面的跳转小条)。 */
    val openTrip: (String) -> Unit,
)

val LocalShell = staticCompositionLocalOf<ShellActions> { error("no shell") }
val LocalSettings = staticCompositionLocalOf { Settings() }

/** 外部请求打开的旅行(跳转小条 / 深链),旅行页消费后清空。 */
object ShellRequests {
    val openTrip = kotlinx.coroutines.flow.MutableStateFlow<String?>(null)
}

/**
 * 导航外壳(对应 iOS AppShellView),侧边栏是 M3 标准的导航抽屉:
 * - 窄屏(手机):模态抽屉(ModalNavigationDrawer),点 ☰ 或在页面上右划唤出,在抽屉上左划收起;
 * - 宽屏(平板/折叠屏展开,≥ 600dp):常驻的同款抽屉,☰ 收起/展开。
 * 抽屉里:顶部「Lodo」、中间十二个页面(行高 48dp、行间不留空,一屏放得下)、
 * 最底下用分隔线隔开的「设置」(固定在底部,不跟着页面列表滚)。
 * 各页底部常驻一条「问问 AI」,点一下把 AI 助手从底部拉起(带页面焦点)。
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class, ExperimentalMaterial3Api::class)
@Composable
fun AppShell(settings: Settings) {
    val app = LocalContext.current.applicationContext as LodoApp
    val agentVm: AgentViewModel = viewModel()
    val wide = LocalConfiguration.current.screenWidthDp >= 600
    var section by rememberSaveable { mutableStateOf(if (settings.openAgentOnLaunch) AppSection.AGENT else AppSection.OVERVIEW) }
    var showSettings by rememberSaveable { mutableStateOf(false) }
    var askSheet by remember { mutableStateOf(false) }
    val visited = remember { mutableStateListOf(section) }
    val holder = androidx.compose.runtime.saveable.rememberSaveableStateHolder()
    val drawerState = androidx.compose.material3.rememberDrawerState(androidx.compose.material3.DrawerValue.Closed)
    var wideDrawerOpen by rememberSaveable { mutableStateOf(true) }
    val scope = rememberCoroutineScope()

    fun go(target: AppSection) {
        section = target
        if (target !in visited) visited += target
        askSheet = false
        if (!wide) scope.launch { drawerState.close() }
    }

    val pendingRoute by app.pendingRoute.collectAsStateWithLifecycle()
    LaunchedEffect(pendingRoute) {
        when (val r = pendingRoute) {
            is PendingRoute.Agent -> go(AppSection.AGENT)
            is PendingRoute.CreateTask -> { agentVm.draft = r.title; go(AppSection.AGENT) }
            is PendingRoute.Section -> AppSection.entries.firstOrNull { it.name.equals(r.name, true) }?.let { go(it) }
            is PendingRoute.Reschedule -> { go(AppSection.TASKS); return@LaunchedEffect }
            null -> return@LaunchedEffect
        }
        app.pendingRoute.value = null
    }

    val actions = ShellActions(
        showMenuButton = true,
        openNav = {
            if (wide) wideDrawerOpen = !wideDrawerOpen
            else scope.launch { if (drawerState.targetValue == androidx.compose.material3.DrawerValue.Open) drawerState.close() else drawerState.open() }
        },
        go = ::go,
        askAi = { focus ->
            agentVm.focus = focus
            agentVm.focusRequest++
            askSheet = true
        },
        openSettings = { showSettings = true },
        openTrip = { uuid -> ShellRequests.openTrip.value = uuid; go(AppSection.TRAVEL) },
    )

    if (showSettings) {
        BackHandler { showSettings = false }
        CompositionLocalProvider(LocalShell provides actions, LocalSettings provides settings) {
            SettingsScreen(onBack = { showSettings = false })
        }
        return
    }

    val drawerContent: @Composable () -> Unit = {
        DrawerBody(
            section = section,
            onSelect = ::go,
            onSettings = { showSettings = true; if (!wide) scope.launch { drawerState.close() } },
        )
    }

    val pages: @Composable () -> Unit = {
        Box(
            Modifier.fillMaxSize()
                .navSwipe(enabled = !wide) { scope.launch { drawerState.open() } },
        ) {
            // 切回来时筛选/滚动位置还在(SaveableStateHolder 按页面保留),没打开过的不构建(同 iOS)。
            AnimatedContent(
                targetState = section,
                // M3 的 fade through:旧页先淡出,新页稍后淡入并从 92% 放大,两个没有空间关系的平级页之间用它。
                transitionSpec = {
                    (fadeIn(androidx.compose.animation.core.tween(210, delayMillis = 90)) +
                        androidx.compose.animation.scaleIn(androidx.compose.animation.core.tween(210, delayMillis = 90), initialScale = 0.92f)) togetherWith
                        fadeOut(androidx.compose.animation.core.tween(90))
                },
                label = "section",
            ) { s ->
                holder.SaveableStateProvider(s.name) { PageFor(s, agentVm) }
            }
        }
    }

    CompositionLocalProvider(LocalShell provides actions, LocalSettings provides settings) {
        if (wide) {
            Row(Modifier.fillMaxSize()) {
                androidx.compose.animation.AnimatedVisibility(wideDrawerOpen,
                    enter = androidx.compose.animation.expandHorizontally(), exit = androidx.compose.animation.shrinkHorizontally()) {
                    androidx.compose.material3.PermanentDrawerSheet(Modifier.width(280.dp)) { drawerContent() }
                }
                Box(Modifier.weight(1f)) { pages() }
            }
        } else {
            // 抽屉自带的手势全关:关着时整页横拖都会被它当成"拉开"(和地图、左滑删除抢手势),
            // 打开时它的拖动收起又不灵、还吃掉我们的左划(实测)。代价是遮罩点击也跟着关了,
            // 所以页面上另垫一层透明点击层负责「点遮罩收起」(见 pages)。左划收起用 navSwipe(toLeft)。
            androidx.compose.material3.ModalNavigationDrawer(
                drawerState = drawerState,
                gesturesEnabled = false,
                drawerContent = {
                    androidx.compose.material3.ModalDrawerSheet(
                        drawerState = drawerState,
                        modifier = Modifier.width(DRAWER_WIDTH).navSwipe(enabled = true, toLeft = true) { scope.launch { drawerState.close() } },
                    ) { drawerContent() }
                },
            ) { pages() }
            // 「点遮罩收起」:抽屉手势关掉后它自己的遮罩会挡住点击又不收起,所以在整个抽屉上面、
            // 抽屉右边露出来的那块另盖一层透明点击层(实测垫在页面里收不到点击)。
            if (drawerState.targetValue == androidx.compose.material3.DrawerValue.Open) {
                Box(Modifier.fillMaxSize().padding(start = DRAWER_WIDTH).clickable(
                    interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                    indication = null,
                ) { scope.launch { drawerState.close() } })
            }
        }
        if (askSheet) {
            ModalBottomSheet(
                onDismissRequest = { askSheet = false },
                sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            ) {
                Box(Modifier.fillMaxWidth().fillMaxSize()) {
                    AgentChat(agentVm, inSheet = true, onClose = { askSheet = false })
                }
            }
        }
    }
}

/**
 * 抽屉内容:标题贴顶、页面列表紧凑(48dp 一行、行间不留空)、设置固定在最底下。
 * 中间的页面列表单独可滚(矮屏放不下时),设置不跟着滚。
 */
private val DRAWER_WIDTH = 300.dp

@Composable
private fun DrawerBody(section: AppSection, onSelect: (AppSection) -> Unit, onSettings: () -> Unit) {
    Column(Modifier.fillMaxSize()) {
        Text(
            "Lodo",
            style = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(start = 28.dp, top = 12.dp, bottom = 12.dp),
        )
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
            AppSection.entries.forEach { s ->
                DrawerItem(s.title, s.icon, selected = section == s) { onSelect(s) }
            }
        }
        androidx.compose.material3.HorizontalDivider(Modifier.padding(horizontal = 28.dp, vertical = 4.dp))
        DrawerItem(L("设置", "Settings"), Icons.Outlined.Settings, selected = false, onClick = onSettings)
        Spacer(Modifier.height(12.dp))
    }
}

@Composable
private fun DrawerItem(label: String, icon: androidx.compose.ui.graphics.vector.ImageVector, selected: Boolean, onClick: () -> Unit) {
    androidx.compose.material3.NavigationDrawerItem(
        label = { Text(label, maxLines = 1) },
        icon = { Icon(icon, contentDescription = null) },
        selected = selected,
        onClick = onClick,
        modifier = Modifier.padding(androidx.compose.material3.NavigationDrawerItemDefaults.ItemPadding).height(48.dp),
    )
}

@Composable
private fun PageFor(section: AppSection, agentVm: AgentViewModel) {
    when (section) {
        AppSection.OVERVIEW -> OverviewScreen()
        AppSection.TASKS -> TodoListScreen()
        AppSection.CALENDAR -> CalendarScreen()
        AppSection.COUNTDOWN -> CountdownScreen()
        AppSection.MEMORY -> MemoryListScreen()
        AppSection.CONTACTS -> ContactsScreen()
        AppSection.ASSETS -> AssetsScreen()
        AppSection.HEALTH -> HealthScreen()
        AppSection.TRAVEL -> TravelScreen()
        AppSection.MENU -> MenuScreen()
        AppSection.NEWS -> NewsScreen()
        AppSection.AGENT -> {
            agentVm.focus = null
            AgentChat(agentVm, inSheet = false, onClose = null)
        }
    }
}

/** 记下落在「不唤出导航栏」区域(地图这类自己吃横向拖动的原生 View)里的那根手指。 */
private object NavSwipe {
    @Volatile var blocked: androidx.compose.ui.input.pointer.PointerId? = null
}

/**
 * 挂在自己处理横向拖动、但不经 Compose 消费事件的区域上(osmdroid 地图是 AndroidView,
 * 拖地图时 Compose 这边看不到"已消费"),在这里按下的手指不触发右划唤出导航栏。
 * 走 Initial 阶段,比外壳的 Main 阶段先到;只做记录,不消费,地图照常收到事件。
 */
fun Modifier.noNavSwipe(): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        NavSwipe.blocked = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial).id
    }
}

/**
 * 窄屏:在页面上往右划(手指向右)唤出导航栏;`toLeft = true` 时反过来,挂在导航栏上往左划收起。
 * 走 Main 阶段,子控件先拿事件——横向滚动的东西(横排胶囊、左滑删除的行)一旦消费了这次拖动,
 * 这里就放手;竖向列表只消费竖向拖动,不受影响。屏幕边缘那一条是系统返回手势,系统先拿走,
 * 这里收不到,也不去抢。
 */
private fun Modifier.navSwipe(enabled: Boolean, toLeft: Boolean = false, onSwipe: () -> Unit): Modifier =
    if (!enabled) this else pointerInput(toLeft) {
        val threshold = 56.dp.toPx()
        val slop = viewConfiguration.touchSlop
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            if (!toLeft && NavSwipe.blocked == down.id) return@awaitEachGesture
            var dx = 0f
            var dy = 0f
            while (true) {
                val event = awaitPointerEvent()
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed || change.isConsumed) break
                val delta = change.positionChange()
                dx += if (toLeft) -delta.x else delta.x
                dy += delta.y
                if (abs(dy) > slop && abs(dy) > abs(dx)) break   // 竖着划,是在滚动
                if (dx < -slop) break                             // 方向反了
                if (dx > threshold && dx > abs(dy) * 2) {
                    change.consume()
                    onSwipe()
                    break
                }
            }
        }
    }
