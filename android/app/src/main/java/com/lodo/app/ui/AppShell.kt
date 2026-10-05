package com.lodo.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material3.ModalWideNavigationRail
import androidx.compose.material3.Text
import androidx.compose.material3.WideNavigationRail
import androidx.compose.material3.WideNavigationRailItem
import androidx.compose.material3.WideNavigationRailValue
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberWideNavigationRailState
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
 * 导航外壳(对应 iOS AppShellView)。Material 3 Expressive 的做法:
 * - 窄屏(手机):模态宽导航栏(ModalWideNavigationRail,从左边滑出,取代旧的抽屉),
 *   只能点左上角 ☰ 唤出;
 * - 宽屏(平板/折叠屏展开,≥ 600dp):常驻的宽导航栏(WideNavigationRail),☰ 收起/展开成图标栏。
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
    val railState = rememberWideNavigationRailState(if (wide) WideNavigationRailValue.Expanded else WideNavigationRailValue.Collapsed)
    val scope = rememberCoroutineScope()

    fun go(target: AppSection) {
        section = target
        if (target !in visited) visited += target
        askSheet = false
        if (!wide) scope.launch { railState.collapse() }
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
        openNav = { scope.launch { if (railState.targetValue == WideNavigationRailValue.Expanded) railState.collapse() else railState.expand() } },
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

    val railContent: @Composable () -> Unit = {
        AppSection.entries.forEach { s ->
            WideNavigationRailItem(
                selected = section == s,
                onClick = { go(s) },
                icon = { Icon(s.icon, contentDescription = null) },
                label = { Text(s.title, maxLines = 1) },
                railExpanded = railState.targetValue == WideNavigationRailValue.Expanded,
            )
        }
        WideNavigationRailItem(
            selected = false,
            onClick = { showSettings = true; if (!wide) scope.launch { railState.collapse() } },
            icon = { Icon(Icons.Outlined.Settings, contentDescription = null) },
            label = { Text(L("设置", "Settings")) },
            railExpanded = railState.targetValue == WideNavigationRailValue.Expanded,
        )
    }
    val railHeader: @Composable () -> Unit = {
        Text(
            "Lodo",
            style = MaterialTheme.typography.headlineSmall.copy(fontWeight = FontWeight.SemiBold),
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.padding(start = 20.dp, top = 8.dp, bottom = 8.dp),
        )
    }

    CompositionLocalProvider(LocalShell provides actions, LocalSettings provides settings) {
        Row(Modifier.fillMaxSize()) {
            if (wide) {
                WideNavigationRail(
                    state = railState,
                    header = { if (railState.targetValue == WideNavigationRailValue.Expanded) railHeader() },
                ) {
                    // 滚动放在栏内的内容上(给栏本身加 verticalScroll 会让它按无限高测量,直接崩)。
                    Column(Modifier.verticalScroll(rememberScrollState())) { railContent() }
                }
            }
            Box(
                Modifier.weight(1f).fillMaxSize()
                    .navSwipe(enabled = !wide) { scope.launch { railState.expand() } },
            ) {
                // 切回来时筛选/滚动位置还在(SaveableStateHolder 按页面保留),没打开过的不构建(同 iOS)。
                AnimatedContent(
                    targetState = section,
                    transitionSpec = { fadeIn() togetherWith fadeOut() },
                    label = "section",
                ) { s ->
                    holder.SaveableStateProvider(s.name) { PageFor(s, agentVm) }
                }
            }
        }
        if (!wide) {
            ModalWideNavigationRail(
                state = railState,
                hideOnCollapse = true,
                header = { railHeader() },
            ) {
                Column(
                    Modifier.verticalScroll(rememberScrollState())
                        .navSwipe(enabled = true, toLeft = true) { scope.launch { railState.collapse() } },
                ) {
                    railContent()
                    Spacer(Modifier.height(16.dp))
                }
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
