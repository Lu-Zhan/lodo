package com.lodo.app.ui.travel

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.animateContentSize
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Bed
import androidx.compose.material.icons.outlined.CheckBox
import androidx.compose.material.icons.outlined.CheckBoxOutlineBlank
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.DirectionsBus
import androidx.compose.material.icons.outlined.Flight
import androidx.compose.material.icons.outlined.Map
import androidx.compose.material.icons.outlined.Person
import androidx.compose.material.icons.outlined.Place
import androidx.compose.material.icons.outlined.Train
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
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
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.TripPlanItem
import com.lodo.app.core.PackingPlan
import com.lodo.app.core.TransportDetails
import com.lodo.app.core.TravelEntry
import com.lodo.app.core.TravelItemKind
import com.lodo.app.core.TravelPlan
import com.lodo.app.core.TripTraveler
import com.lodo.app.data.ExchangeRates
import com.lodo.app.data.MemoryEntity
import com.lodo.app.data.TripEntity
import com.lodo.app.data.formatAmount
import com.lodo.app.data.toEpochMillis
import com.lodo.app.data.toLocalDateTime
import com.lodo.app.data.travelEntry
import com.lodo.app.ui.DateTimeField
import com.lodo.app.ui.GroupCard
import com.lodo.app.ui.L
import com.lodo.app.ui.LodoRow
import com.lodo.app.ui.LodoSubPage
import com.lodo.app.ui.assets.CurrencyChips
import com.lodo.app.ui.assets.SheetHeader
import com.lodo.app.ui.countdown.SwitchRow
import com.lodo.app.ui.theme.LodoColor
import com.lodo.app.ui.theme.dayColors
import kotlinx.coroutines.launch
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.util.UUID

fun kindIcon(kind: TravelItemKind): ImageVector = when (kind) {
    TravelItemKind.FLIGHT -> Icons.Outlined.Flight
    TravelItemKind.TRAIN -> Icons.Outlined.Train
    TravelItemKind.COACH -> Icons.Outlined.DirectionsBus
    TravelItemKind.LODGING -> Icons.Outlined.Bed
    TravelItemKind.PLACE -> Icons.Outlined.Place
}

fun kindName(kind: TravelItemKind) = when (kind) {
    TravelItemKind.FLIGHT -> L("航班", "Flight")
    TravelItemKind.TRAIN -> L("火车", "Train")
    TravelItemKind.COACH -> L("客车", "Coach")
    TravelItemKind.LODGING -> L("住宿", "Stay")
    TravelItemKind.PLACE -> L("地点", "Place")
}

private val timeFmt = DateTimeFormatter.ofPattern("HH:mm")

/** 行上的一行摘要:时间 · 地点 · 单号(备注、航站楼这些收进详情,同 iOS)。 */
fun entrySummary(e: TravelEntry): String = listOfNotNull(
    e.start?.let { s -> s.format(timeFmt) + (e.end?.takeIf { it.toLocalDate() == s.toLocalDate() }?.let { "–" + it.format(timeFmt) } ?: "") },
    if (!e.originName.isNullOrBlank() && !e.placeName.isNullOrBlank()) "${e.originName} → ${e.placeName}" else e.placeName?.takeIf { it.isNotBlank() },
    e.code?.takeIf { it.isNotBlank() },
    e.price?.takeIf { it != 0.0 }?.let { formatAmount(it, e.currency) },
).joinToString(" · ")

/**
 * 旅行详情,对应 iOS TravelDetailView 的面板内容(安卓没有地图组件,地点点开可以跳到地图 app):
 * 总览 / 日程 / 清单 / 人员 / 消费 / 文件 六档;右上角菜单是手动添加、从订单导入、编辑旅行。
 * 底部「问问 AI」带上这次旅行的名字(含糊的"第二天改去奈良"默认就改这一次)。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TravelDetail(trip: TripEntity, vm: TravelViewModel, onBack: () -> Unit) {
    val items by remember(trip.uuid) { vm.app.travel.observeItems(trip.uuid) }.collectAsStateWithLifecycle(emptyList())
    val packing by remember(trip.uuid) { vm.app.travel.observePacking(trip.uuid) }.collectAsStateWithLifecycle(emptyList())
    val entries = items.mapNotNull { it.travelEntry() }
    val files = items.filter { !it.isTravelItem }
    var tab by rememberSaveable { mutableStateOf(1) }
    var menu by remember { mutableStateOf(false) }
    var editingItem by remember { mutableStateOf<MemoryEntity?>(null) }
    var addingItem by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }
    var editingTrip by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val byId = items.associateBy { it.uuid }
    val days = vm.app.travel.days(trip)

    LodoSubPage(
        title = trip.displayEmoji + " " + trip.title,
        onBack = onBack,
        focus = AgentFocus(AgentPageFocus.TRAVEL, trip.title),
        askPrompt = L("这趟还想去哪?", "Anything to change on this trip?"),
        actions = {
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, L("更多", "More")) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(L("手动添加", "Add item")) }, onClick = { menu = false; addingItem = true })
                    DropdownMenuItem(text = { Text(L("从订单导入", "Import from booking")) }, onClick = { menu = false; importing = true })
                    DropdownMenuItem(text = { Text(L("编辑旅行", "Edit trip")) }, onClick = { menu = false; editingTrip = true })
                    DropdownMenuItem(text = { Text(L("删除旅行", "Delete trip"), color = MaterialTheme.colorScheme.error) }, onClick = { menu = false; confirmDelete = true })
                }
            }
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Column(Modifier.padding(horizontal = 20.dp, vertical = 4.dp)) {
                Text(tripDates(trip) + listOf(trip.city, trip.country).filter { it.isNotBlank() }.joinToString(" · ").let { if (it.isEmpty()) "" else " · $it" },
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(tripStatus(trip), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            }
            val tabs = listOf(L("总览", "Overview"), L("日程", "Itinerary"), L("清单", "Packing"), L("人员", "People"), L("消费", "Costs"), L("文件", "Files"))
            PrimaryScrollableTabRow(selectedTabIndex = tab, edgePadding = 12.dp) {
                tabs.forEachIndexed { i, t -> Tab(selected = tab == i, onClick = { tab = i }, text = { Text(t) }) }
            }
            val open: (TravelEntry) -> Unit = { e -> editingItem = byId[e.id] }
            Box(Modifier.weight(1f)) {
                when (tab) {
                    0 -> OverviewTab(entries, open)
                    1 -> ItineraryTab(days, entries, open)
                    2 -> PackingTab(trip, packing, vm)
                    3 -> PeopleTab(trip, vm)
                    4 -> CostsTab(entries, open)
                    else -> FilesTab(trip, files, vm)
                }
            }
        }
    }
    if (addingItem || editingItem != null) ItemEditSheet(trip, editingItem, vm, onDismiss = { addingItem = false; editingItem = null })
    if (importing) ImportSheet(trip, vm, onDismiss = { importing = false })
    if (editingTrip) TripEditSheet(trip, vm, onSaved = { editingTrip = false }, onDismiss = { editingTrip = false })
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text(L("删除「${trip.title}」?", "Delete \"${trip.title}\"?")) },
        text = { Text(L("行程项和清单一起删除;旅行文件只摘下、留在记忆库。", "Items and packing list are deleted; files stay in Memory.")) },
        confirmButton = { TextButton(onClick = { vm.deleteTrip(trip.uuid); confirmDelete = false; onBack() }) { Text(L("删除", "Delete"), color = LodoColor.critical) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(L("取消", "Cancel")) } },
    )
}

@Composable
private fun EntryRow(e: TravelEntry, onClick: () -> Unit, tint: androidx.compose.ui.graphics.Color? = null) {
    LodoRow(e.title, subtitle = entrySummary(e).ifBlank { kindName(e.kind) }, icon = kindIcon(e.kind), iconTint = tint, onClick = onClick)
}

@Composable
private fun TabList(content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp), content = content)
}

@Composable
private fun OverviewTab(entries: List<TravelEntry>, open: (TravelEntry) -> Unit) {
    val transports = TravelPlan.transports(entries)
    val lodgings = TravelPlan.sorted(entries.filter { it.kind == TravelItemKind.LODGING })
    val pending = TravelPlan.unscheduled(entries).filter { !it.kind.isTransport }
    val dayFmt = DateTimeFormatter.ofPattern(L("M月d日 HH:mm", "MMM d HH:mm"))
    TabList {
        if (entries.isEmpty()) item { Text(L("还没有行程。说一句「第一天去浅草寺」或从右上角导入订单。", "No items yet. Ask AI or import a booking."), color = MaterialTheme.colorScheme.onSurfaceVariant) }
        if (transports.isNotEmpty()) item {
            GroupCard(title = L("交通", "Transport")) {
                transports.forEachIndexed { i, e ->
                    if (i > 0) HorizontalDivider(Modifier.padding(start = 52.dp))
                    LodoRow(e.title + (e.code?.let { " · $it" } ?: ""), icon = kindIcon(e.kind), onClick = { open(e) },
                        subtitle = listOfNotNull(e.start?.format(dayFmt), if (e.originName != null || e.placeName != null) "${e.originName ?: "?"} → ${e.placeName ?: "?"}" else null,
                            e.transport?.let { t -> listOfNotNull(t.gate?.let { L("登机口/检票口 $it", "Gate $it") }, t.seat?.let { L("座位 $it", "Seat $it") }).joinToString(" ") }?.takeIf { it.isNotBlank() }
                        ).joinToString(" · "))
                }
            }
        }
        if (lodgings.isNotEmpty()) item {
            GroupCard(title = L("住宿", "Stays")) {
                lodgings.forEachIndexed { i, e ->
                    if (i > 0) HorizontalDivider(Modifier.padding(start = 52.dp))
                    LodoRow(e.title, icon = kindIcon(e.kind), onClick = { open(e) },
                        subtitle = listOfNotNull(e.start?.let { L("入住 ", "In ") + it.format(dayFmt) }, e.end?.let { L("退房 ", "Out ") + it.format(dayFmt) },
                            TravelPlan.nights(e)?.let { L("共 $it 晚", "$it nights") }, e.note.takeIf { it.isNotBlank() }).joinToString("\n"), maxSubtitleLines = 4)
                }
            }
        }
        if (pending.isNotEmpty()) item {
            GroupCard(title = L("待安排", "Unscheduled")) {
                pending.forEachIndexed { i, e -> if (i > 0) HorizontalDivider(Modifier.padding(start = 52.dp)); EntryRow(e, { open(e) }) }
            }
        }
    }
}

@Composable
private fun ItineraryTab(days: List<java.time.LocalDate>, entries: List<TravelEntry>, open: (TravelEntry) -> Unit) {
    val groups = TravelPlan.group(entries, days)
    val outside = TravelPlan.outOfRange(entries, days)
    val unscheduled = TravelPlan.unscheduled(entries)
    val dayFmt = DateTimeFormatter.ofPattern(L("M月d日 EEEE", "EEE, MMM d"))
    TabList {
        groups.forEachIndexed { i, day ->
            // 当晚住的酒店排在每天的最后一行(同 iOS)。
            val rows = day.entries + TravelPlan.lodgings(day.date, entries)
            item("d$i") {
                GroupCard(title = L("第 ${i + 1} 天 · ", "Day ${i + 1} · ") + day.date.format(dayFmt)) {
                    if (rows.isEmpty()) Text(L("这天还没安排", "Nothing planned"), color = MaterialTheme.colorScheme.outline, modifier = Modifier.padding(16.dp))
                    rows.forEachIndexed { j, e ->
                        if (j > 0) HorizontalDivider(Modifier.padding(start = 52.dp))
                        EntryRow(e, { open(e) }, tint = dayColors[i % dayColors.size])
                    }
                }
            }
        }
        if (outside.isNotEmpty()) item("out") {
            GroupCard(title = L("行程日期之外", "Outside trip dates")) { outside.forEach { EntryRow(it, { open(it) }) } }
        }
        if (unscheduled.isNotEmpty()) item("un") {
            GroupCard(title = L("未排期", "Unscheduled")) { unscheduled.forEach { EntryRow(it, { open(it) }) } }
        }
    }
}

@Composable
private fun CostsTab(entries: List<TravelEntry>, open: (TravelEntry) -> Unit) {
    val rates by ExchangeRates.rates.collectAsStateWithLifecycle()
    @Suppress("UNUSED_VARIABLE") val key = rates
    val total = TravelPlan.total(entries, "CNY") { a, f, t -> ExchangeRates.convert(a, f, t) }
    val priced = TravelPlan.sorted(entries.filter { (it.price ?: 0.0) != 0.0 })
    TabList {
        item {
            Card(shape = RoundedCornerShape(24.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                Column(Modifier.fillMaxWidth().padding(20.dp)) {
                    Text(L("合计(折合人民币)", "Total (CNY)"), color = MaterialTheme.colorScheme.onPrimaryContainer)
                    Text(formatAmount(total.amount, "CNY"), fontSize = 30.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onPrimaryContainer)
                    TravelPlan.costs(entries).forEach { Text(formatAmount(it.amount, it.currency), color = MaterialTheme.colorScheme.onPrimaryContainer) }
                    if (total.missingCurrencies.isNotEmpty()) Text(L("换不出汇率,没计入:", "No rate, not counted: ") + total.missingCurrencies.joinToString("、"),
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimaryContainer)
                }
            }
        }
        if (priced.isEmpty()) item { Text(L("还没有带价格的行程项", "No priced items yet"), color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(8.dp)) }
        else TravelItemKind.entries.forEach { k ->
            val list = priced.filter { it.kind == k }
            if (list.isNotEmpty()) item(k.raw) {
                GroupCard(title = kindName(k)) {
                    list.forEach { e -> LodoRow(e.title, icon = kindIcon(k), onClick = { open(e) }, trailing = { Text(formatAmount(e.price ?: 0.0, e.currency), fontWeight = FontWeight.SemiBold) }) }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PackingTab(trip: TripEntity, packing: List<com.lodo.app.data.PackingEntity>, vm: TravelViewModel) {
    var newItem by remember { mutableStateOf("") }
    var suggesting by remember { mutableStateOf(false) }
    var suggestions by remember { mutableStateOf<List<DeepSeekClient.PackingSuggestion>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    TabList {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(newItem, { newItem = it }, placeholder = { Text(L("加一件…", "Add an item…")) }, singleLine = true, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                FilledTonalButton(onClick = { vm.addPacking(trip.uuid, listOf(newItem.trim() to "其他")); newItem = "" }, enabled = newItem.isNotBlank()) { Text(L("添加", "Add")) }
            }
        }
        item {
            OutlinedButton(onClick = {
                suggesting = true; error = null
                scope.launch {
                    runCatching { vm.suggestPacking(trip, packing.map { it.title }) }
                        .onSuccess { list ->
                            val fresh = PackingPlan.newSuggestions(list.map { it.title }, packing.map { it.title }).toSet()
                            suggestions = list.filter { it.title in fresh }
                        }.onFailure { error = it.message }
                    suggesting = false
                }
            }, enabled = !suggesting) {
                if (suggesting) CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp) else Icon(Icons.Filled.AutoAwesome, null, Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp)); Text(L("AI 建议清单", "AI suggestions"))
            }
            error?.let { Text(it, color = LodoColor.critical, style = MaterialTheme.typography.bodySmall) }
        }
        val packed = packing.count { it.packed }
        if (packing.isNotEmpty()) item { Text(L("已收拾 $packed / ${packing.size}", "Packed $packed / ${packing.size}"), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary) }
        PackingPlan.grouped(packing) { it.category }.forEach { (cat, list) ->
            item("c$cat") {
                GroupCard(title = cat) {
                    list.forEach { p ->
                        LodoRow(p.title, onClick = { vm.togglePacked(p) },
                            leading = { Icon(if (p.packed) Icons.Outlined.CheckBox else Icons.Outlined.CheckBoxOutlineBlank, null,
                                tint = if (p.packed) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline) },
                            trailing = { IconButton(onClick = { vm.deletePacking(p.uuid) }) { Icon(Icons.Filled.Close, L("删除", "Delete"), Modifier.size(18.dp)) } })
                    }
                }
            }
        }
    }
    suggestions?.let { list ->
        val chosen = remember(list) { mutableStateListOf<String>().apply { addAll(list.map { it.title }) } }
        ModalBottomSheet(onDismissRequest = { suggestions = null }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
                SheetHeader(L("AI 建议", "Suggestions"), chosen.isNotEmpty(), { suggestions = null }) {
                    vm.addPacking(trip.uuid, list.filter { it.title in chosen }.map { it.title to it.category }); suggestions = null
                }
                if (list.isEmpty()) Text(L("清单里已经都有了。", "You already have everything."), modifier = Modifier.padding(16.dp))
                list.forEach { s ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(s.title in chosen, { c -> if (c) chosen += s.title else chosen -= s.title })
                        Column(Modifier.weight(1f)) {
                            Text(s.title, fontWeight = FontWeight.Medium)
                            Text(s.category + if (s.reason.isNotBlank()) " · ${s.reason}" else "", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun PeopleTab(trip: TripEntity, vm: TravelViewModel) {
    val travelers = TripTraveler.decode(trip.travelersJson)
    val memories by vm.memories.collectAsStateWithLifecycle()
    val contacts = memories.filter { it.isContact }
    var name by remember { mutableStateOf("") }
    var pick by remember { mutableStateOf(false) }
    fun save(list: List<TripTraveler>) = vm.saveTrip(trip.copy(travelersJson = TripTraveler.encode(list)))
    TabList {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(name, { name = it }, placeholder = { Text(L("同行人名字", "Name")) }, singleLine = true, modifier = Modifier.weight(1f))
                Spacer(Modifier.width(8.dp))
                FilledTonalButton(onClick = { save(travelers + TripTraveler(UUID.randomUUID().toString(), name.trim())); name = "" }, enabled = name.isNotBlank()) { Text(L("添加", "Add")) }
            }
            if (contacts.isNotEmpty()) TextButton(onClick = { pick = true }) { Text(L("从人脉选择", "Pick from People")) }
        }
        if (travelers.isEmpty()) item { Text(L("还没有同行人", "No travelers yet"), color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(8.dp)) }
        else item {
            GroupCard {
                travelers.forEach { t ->
                    val linked = t.contactUuid?.let { id -> contacts.firstOrNull { it.uuid == id } }
                    LodoRow(linked?.title ?: t.name, icon = Icons.Outlined.Person, subtitle = listOfNotNull(if (t.contactUuid != null) L("人脉", "Contact") else null, t.note.takeIf { it.isNotBlank() }).joinToString(" · "),
                        trailing = { IconButton(onClick = { save(travelers - t) }) { Icon(Icons.Filled.Close, L("移除", "Remove")) } })
                }
            }
        }
    }
    if (pick) AlertDialog(
        onDismissRequest = { pick = false },
        title = { Text(L("从人脉选择", "Pick from People")) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                contacts.filter { c -> travelers.none { it.contactUuid == c.uuid } }.forEach { c ->
                    TextButton(onClick = { save(travelers + TripTraveler(UUID.randomUUID().toString(), c.title, contactUuid = c.uuid)); pick = false }) { Text(c.title) }
                }
            }
        },
        confirmButton = { TextButton(onClick = { pick = false }) { Text(L("关闭", "Close")) } },
    )
}

@Composable
private fun FilesTab(trip: TripEntity, files: List<MemoryEntity>, vm: TravelViewModel) {
    val memories by vm.memories.collectAsStateWithLifecycle()
    var text by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var pick by remember { mutableStateOf(false) }
    val context = LocalContext.current
    TabList {
        item {
            Text(L("和这次旅行相关的资料(订单、签证、攻略链接),和记忆库是同一份。", "Notes and links for this trip — they also live in Memory."),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedTextField(text, { text = it }, placeholder = { Text(L("贴一段文字或链接…", "Paste text or a link…")) }, modifier = Modifier.fillMaxWidth(), minLines = 2)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(onClick = { busy = true; vm.addFileText(trip.uuid, text) { busy = false; text = "" } }, enabled = text.isNotBlank() && !busy) {
                    Text(if (busy) L("整理中…", "Organizing…") else L("保存", "Save"))
                }
                OutlinedButton(onClick = { pick = true }) { Text(L("从记忆库选择", "From Memory")) }
            }
        }
        if (files.isEmpty()) item { Text(L("还没有文件", "No files yet"), color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(8.dp)) }
        else item {
            GroupCard {
                files.forEach { f ->
                    LodoRow(f.title.ifBlank { L("整理中…", "Organizing…") }, icon = Icons.Outlined.Description, subtitle = f.summary,
                        onClick = { f.urlString?.let { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) } } },
                        trailing = { TextButton(onClick = { vm.detachFile(f.uuid) }) { Text(L("移出", "Detach")) } })
                }
            }
        }
    }
    if (pick) AlertDialog(
        onDismissRequest = { pick = false },
        title = { Text(L("从记忆库选择", "From Memory")) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                memories.filter { it.travelTripUuid == null && !it.isContact && !it.isAsset }.take(80).forEach { m ->
                    TextButton(onClick = { vm.attachMemory(trip.uuid, m.uuid); pick = false }) { Text(m.title, maxLines = 1) }
                }
            }
        },
        confirmButton = { TextButton(onClick = { pick = false }) { Text(L("关闭", "Close")) } },
    )
}

// ---------------------------------------------------------------------------

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun ItemEditSheet(trip: TripEntity, existing: MemoryEntity?, vm: TravelViewModel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val tripStart = trip.startMillis.toLocalDateTime().toLocalDate().atTime(LocalTime.of(10, 0))
    var kind by remember { mutableStateOf(TravelItemKind.from(existing?.travelKind) ?: TravelItemKind.PLACE) }
    var title by remember { mutableStateOf(existing?.title ?: "") }
    var hasStart by remember { mutableStateOf(existing == null || existing.travelStartMillis != null) }
    var start by remember { mutableStateOf(existing?.travelStartMillis?.toLocalDateTime() ?: tripStart) }
    var hasEnd by remember { mutableStateOf(existing?.travelEndMillis != null) }
    var end by remember { mutableStateOf(existing?.travelEndMillis?.toLocalDateTime() ?: tripStart.plusHours(2)) }
    var place by remember { mutableStateOf(existing?.travelPlaceName ?: "") }
    var origin by remember { mutableStateOf(existing?.travelOriginName ?: "") }
    var code by remember { mutableStateOf(existing?.travelCode ?: "") }
    var price by remember { mutableStateOf(existing?.travelPrice?.toString() ?: "") }
    var currency by remember { mutableStateOf(existing?.travelCurrency ?: "CNY") }
    var note by remember { mutableStateOf(existing?.travelNote ?: existing?.summary ?: "") }
    val details = remember { TransportDetails.decode(existing?.travelFlightData) ?: TransportDetails() }
    var terminal by remember { mutableStateOf(details.departureTerminal ?: "") }
    var gate by remember { mutableStateOf(details.gate ?: "") }
    var seat by remember { mutableStateOf(details.seat ?: "") }
    var platform by remember { mutableStateOf(details.platform ?: "") }
    var carriage by remember { mutableStateOf(details.carriage ?: "") }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 20.dp).animateContentSize(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SheetHeader(if (existing == null) L("添加行程", "Add item") else L("行程详情", "Item"), title.isNotBlank(), onDismiss) {
                val base = existing ?: vm.app.travel.newItem(trip.uuid, TripPlanItem(kind, title))
                val newDetails = if (kind.isTransport) details.copy(
                    departureTerminal = terminal.ifBlank { null }, gate = gate.ifBlank { null }, seat = seat.ifBlank { null },
                    platform = platform.ifBlank { null }, carriage = carriage.ifBlank { null },
                ) else null
                vm.saveItem(base.copy(
                    title = title.trim(), travelKind = kind.raw, travelStartMillis = if (hasStart) start.toEpochMillis() else null,
                    travelEndMillis = if (hasEnd) end.takeIf { !hasStart || !it.isBefore(start) }?.toEpochMillis() else null,
                    travelPlaceName = place.ifBlank { null }, travelOriginName = if (kind.isTransport) origin.ifBlank { null } else null,
                    travelCode = code.ifBlank { null }, travelPrice = price.replace(",", "").toDoubleOrNull(), travelCurrency = currency,
                    travelNote = note, summary = note, travelFlightData = newDetails?.takeIf { !it.isEmpty() }?.toJson(),
                    travelLatitude = if (place != existing?.travelPlaceName) null else existing?.travelLatitude,
                    travelLongitude = if (place != existing?.travelPlaceName) null else existing?.travelLongitude,
                ))
                onDismiss()
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                TravelItemKind.entries.forEach { k -> FilterChip(kind == k, { kind = k }, label = { Text(kindName(k)) }, leadingIcon = { Icon(kindIcon(k), null, Modifier.size(18.dp)) }) }
            }
            OutlinedTextField(title, { title = it }, label = { Text(L("名称", "Title")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            if (kind.isTransport) OutlinedTextField(origin, { origin = it }, label = { Text(L("出发地", "From")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(place, { place = it }, label = { Text(if (kind.isTransport) L("到达地", "To") else L("地点", "Place")) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                trailingIcon = {
                    if (place.isNotBlank()) IconButton(onClick = {
                        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" + Uri.encode(place + " " + trip.city)))) }
                    }) { Icon(Icons.Outlined.Map, L("在地图中打开", "Open in Maps")) }
                })
            SwitchRow(if (kind == TravelItemKind.LODGING) L("入住时间", "Check-in") else L("开始时间", "Start"), hasStart) { hasStart = it }
            if (hasStart) DateTimeField("", start, true, { start = it })
            SwitchRow(if (kind == TravelItemKind.LODGING) L("退房时间", "Check-out") else L("结束时间", "End"), hasEnd) { hasEnd = it }
            if (hasEnd) DateTimeField("", end, true, { end = it })
            if (kind.isTransport) {
                OutlinedTextField(code, { code = it }, label = { Text(L("航班号/车次", "Flight/train no.")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (kind == TravelItemKind.FLIGHT) OutlinedTextField(terminal, { terminal = it }, label = { Text(L("航站楼", "Terminal")) }, singleLine = true, modifier = Modifier.weight(1f))
                    OutlinedTextField(gate, { gate = it }, label = { Text(if (kind == TravelItemKind.FLIGHT) L("登机口", "Gate") else L("检票口", "Gate")) }, singleLine = true, modifier = Modifier.weight(1f))
                }
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (kind != TravelItemKind.FLIGHT) OutlinedTextField(platform, { platform = it }, label = { Text(if (kind == TravelItemKind.TRAIN) L("站台", "Platform") else L("上车点", "Pickup")) }, singleLine = true, modifier = Modifier.weight(1f))
                    if (kind == TravelItemKind.TRAIN) OutlinedTextField(carriage, { carriage = it }, label = { Text(L("车厢", "Car")) }, singleLine = true, modifier = Modifier.weight(1f))
                    OutlinedTextField(seat, { seat = it }, label = { Text(L("座位", "Seat")) }, singleLine = true, modifier = Modifier.weight(1f))
                }
                details.status?.let { Text(L("状态:", "Status: ") + it, color = MaterialTheme.colorScheme.primary) }
            } else {
                OutlinedTextField(code, { code = it }, label = { Text(L("订单号(可选)", "Booking no. (optional)")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            }
            OutlinedTextField(price, { price = it }, label = { Text(L("价格", "Price")) }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
            CurrencyChips(currency) { currency = it }
            OutlinedTextField(note, { note = it }, label = { Text(L("备注", "Notes")) }, modifier = Modifier.fillMaxWidth(), minLines = 2)
            if (existing != null) TextButton(onClick = { vm.deleteItem(existing.uuid); onDismiss() }) { Text(L("删除这一项", "Delete item"), color = MaterialTheme.colorScheme.error) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

/** 从订单导入:贴文字/选截图(端上 OCR,不上传图片)→ AI 拆成行程项 → 确认后才写入(同 iOS,保留确认页)。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ImportSheet(trip: TripEntity, vm: TravelViewModel, onDismiss: () -> Unit) {
    var text by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var parsed by remember { mutableStateOf<List<Pair<DeepSeekClient.ParsedTravelItem, Boolean>>?>(null) }
    val scope = rememberCoroutineScope()
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(5)) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            val ocr = uris.map { vm.ocr(it) }.filter { it.isNotBlank() }.joinToString("\n\n")
            text = listOf(text, ocr).filter { it.isNotBlank() }.joinToString("\n\n")
            if (ocr.isBlank()) error = L("截图里没认出文字", "No text recognized")
            busy = false
        }
    }
    val fmt = DateTimeFormatter.ofPattern(L("M月d日 HH:mm", "MMM d HH:mm"))
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            val list = parsed
            if (list == null) {
                SheetHeader(L("从订单导入", "Import booking"), text.isNotBlank() && !busy, onDismiss) {
                    busy = true; error = null
                    scope.launch {
                        runCatching { vm.parseImport(trip, text) }.onSuccess { items ->
                            if (items.isEmpty()) error = L("没有读出行程信息", "No itinerary found") else parsed = items.map { it to (vm.existing(trip, it) != null) }
                        }.onFailure { error = it.message }
                        busy = false
                    }
                }
                Text(L("贴订票邮件、酒店确认信,或选订单/登机牌截图(在手机上识别文字,图片不上传)。", "Paste a booking email or pick screenshots (OCR runs on device)."),
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(text, { text = it }, modifier = Modifier.fillMaxWidth(), minLines = 6, placeholder = { Text(L("订单内容…", "Booking text…")) })
                OutlinedButton(onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, enabled = !busy) { Text(L("选截图", "Pick screenshots")) }
                if (busy) Row(verticalAlignment = Alignment.CenterVertically) { CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)); Text(L("处理中…", "Working…")) }
            } else {
                SheetHeader(L("确认导入", "Confirm import"), true, onDismiss) { vm.importItems(trip, list.map { it.first }); onDismiss() }
                list.forEach { (p, merge) ->
                    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow), shape = RoundedCornerShape(16.dp)) {
                        Column(Modifier.fillMaxWidth().padding(12.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(kindIcon(p.kind), null, tint = MaterialTheme.colorScheme.primary)
                                Spacer(Modifier.width(8.dp))
                                Text(p.title + (p.code?.let { " · $it" } ?: ""), fontWeight = FontWeight.Medium)
                            }
                            Text(listOfNotNull(p.start?.format(fmt), p.end?.format(fmt)).joinToString(" – ") +
                                listOfNotNull(p.originName, p.placeName).joinToString(" → ").let { if (it.isEmpty()) "" else " · $it" } +
                                (p.price?.let { " · " + formatAmount(it, p.currency ?: "CNY") } ?: ""), style = MaterialTheme.typography.bodySmall)
                            p.transport?.promptLine()?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            if (merge) Text(L("更新行程里已有的这一班", "Updates the existing one"), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                        }
                    }
                }
            }
            error?.let { Text(it, color = LodoColor.critical) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

/** 新建/编辑旅行:标题前的 emoji、日期、目的地、备注(备注那栏有「重新生成」)。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TripEditSheet(existing: TripEntity?, vm: TravelViewModel, onSaved: (String) -> Unit, onDismiss: () -> Unit) {
    var title by remember { mutableStateOf(existing?.title ?: "") }
    var emoji by remember { mutableStateOf(existing?.emoji ?: "") }
    var start by remember { mutableStateOf(existing?.startMillis?.toLocalDateTime() ?: LocalDateTime.now().plusDays(14).withHour(0).withMinute(0)) }
    var end by remember { mutableStateOf(existing?.endMillis?.toLocalDateTime() ?: start.plusDays(3)) }
    var city by remember { mutableStateOf(existing?.city ?: "") }
    var country by remember { mutableStateOf(existing?.country ?: "") }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    var generating by remember { mutableStateOf(false) }
    var noteError by remember { mutableStateOf<String?>(null) }
    var aiOn by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { aiOn = vm.aiConfigured() }
    val scope = rememberCoroutineScope()
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SheetHeader(if (existing == null) L("新建旅行", "New trip") else L("编辑旅行", "Edit trip"), title.isNotBlank(), onDismiss) {
                val trip = (existing ?: TripEntity(title = "", startMillis = 0, endMillis = 0)).copy(
                    title = title.trim(), emoji = emoji.trim(), startMillis = start.toLocalDate().atStartOfDay().toEpochMillis(),
                    endMillis = maxOf(end, start).toLocalDate().atStartOfDay().toEpochMillis(), city = city.trim(), country = country.trim(), notes = notes.trim(),
                )
                vm.saveTrip(trip)
                onSaved(trip.uuid)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(emoji, { emoji = it.take(8) }, label = { Text("Emoji") }, singleLine = true, modifier = Modifier.width(88.dp))
                OutlinedTextField(title, { title = it }, label = { Text(L("旅行名称", "Trip name")) }, singleLine = true, modifier = Modifier.weight(1f))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf("✈️", "🏖️", "🏔️", "🗼", "🌸", "🍜", "🚄", "🎢").forEach { e -> AssistChip(onClick = { emoji = e }, label = { Text(e) }) }
            }
            DateTimeField(L("出发", "From"), start, false, { start = it })
            DateTimeField(L("返回", "To"), end, false, { end = it })
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(city, { city = it }, label = { Text(L("城市", "City")) }, singleLine = true, modifier = Modifier.weight(1f))
                OutlinedTextField(country, { country = it }, label = { Text(L("国家/地区", "Country")) }, singleLine = true, modifier = Modifier.weight(1f))
            }
            OutlinedTextField(notes, { notes = it }, label = { Text(L("备注", "Note")) }, modifier = Modifier.fillMaxWidth(),
                trailingIcon = {
                    if (existing != null && aiOn) IconButton(onClick = {
                        generating = true; noteError = null
                        scope.launch {
                            runCatching { vm.suggestNote(existing) }.onSuccess { notes = it }.onFailure { noteError = it.message }
                            generating = false
                        }
                    }, enabled = !generating) {
                        if (generating) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp) else Icon(Icons.Filled.AutoAwesome, L("重新生成", "Regenerate"))
                    }
                })
            noteError?.let { Text(it, color = LodoColor.critical, style = MaterialTheme.typography.bodySmall) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

