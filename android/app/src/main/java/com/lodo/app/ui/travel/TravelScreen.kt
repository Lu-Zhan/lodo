package com.lodo.app.ui.travel

import android.app.Application
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.Flight
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
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
import com.lodo.app.data.MemoryEntity
import com.lodo.app.data.Ocr
import com.lodo.app.data.PackingEntity
import com.lodo.app.data.TripEntity
import com.lodo.app.data.toLocalDateTime
import com.lodo.app.ui.FullEmpty
import com.lodo.app.ui.L
import com.lodo.app.ui.LodoPage
import com.lodo.app.ui.ShellRequests
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

class TravelViewModel(application: Application) : AndroidViewModel(application) {
    val app = application as LodoApp
    val trips = app.travel.observeTrips().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val memories = app.memoryRepository.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun saveTrip(t: TripEntity) = viewModelScope.launch { app.travel.saveTrip(t) }
    fun deleteTrip(uuid: String) = viewModelScope.launch { app.travel.deleteTrip(uuid) }
    fun saveItem(m: MemoryEntity) = viewModelScope.launch { app.travel.saveItem(m) }
    fun deleteItem(uuid: String) = viewModelScope.launch { app.travel.deleteItem(uuid) }
    fun togglePacked(p: PackingEntity) = viewModelScope.launch { app.travel.togglePacked(p) }
    fun deletePacking(uuid: String) = viewModelScope.launch { app.travel.deletePacking(uuid) }
    fun addPacking(tripUuid: String, items: List<Pair<String, String>>) = viewModelScope.launch { app.travel.addPacking(tripUuid, items) }
    fun attachMemory(tripUuid: String, uuid: String) = viewModelScope.launch { app.travel.attachMemory(tripUuid, uuid) }
    fun detachFile(uuid: String) = viewModelScope.launch { app.travel.detachFile(uuid) }

    fun addFileText(tripUuid: String, text: String, done: () -> Unit) = viewModelScope.launch {
        val item = app.memoryRepository.saveText(app.settings.aiConfig(), text, listOf(MemoryEntity.travelTagName))
        app.travel.attachMemory(tripUuid, item.uuid)
        done()
    }

    suspend fun ocr(uri: Uri) = Ocr.recognize(app, uri)

    suspend fun parseImport(trip: TripEntity, text: String) = DeepSeekClient.parseTravelItems(
        app.settings.aiConfig(), text, trip.title, trip.startMillis.toLocalDateTime(), trip.endMillis.toLocalDateTime().plusHours(23),
    )

    suspend fun existing(trip: TripEntity, item: DeepSeekClient.ParsedTravelItem) = app.travel.existingTransport(trip.uuid, item)
    fun importItems(trip: TripEntity, items: List<DeepSeekClient.ParsedTravelItem>) = viewModelScope.launch { app.travel.importItems(trip.uuid, items) }

    suspend fun suggestPacking(trip: TripEntity, existing: List<String>) =
        DeepSeekClient.suggestPackingList(app.settings.aiConfig(), app.travel.aiSummary(trip), existing)

    suspend fun suggestNote(trip: TripEntity) = DeepSeekClient.suggestTripNote(app.settings.aiConfig(), app.travel.aiSummary(trip))
    suspend fun fillMissing(trip: TripEntity, progress: (Int, Int) -> Unit) = app.geocoder.fillMissing(trip, progress)
    suspend fun relocateAll(trip: TripEntity, progress: (com.lodo.app.data.TravelGeocoder.Progress) -> Unit) =
        app.geocoder.relocateAll(trip, app.settings.aiConfig(), progress)
    suspend fun locate(trip: TripEntity, uuid: String) = app.geocoder.locate(trip, uuid, app.settings.aiConfig())
    suspend fun setManual(uuid: String, p: com.lodo.app.core.GeoPoint) = app.geocoder.setManual(uuid, p)
    suspend fun leg(a: com.lodo.app.core.GeoPoint, b: com.lodo.app.core.GeoPoint) = app.geocoder.leg(a, b)
    fun cachedLeg(a: com.lodo.app.core.GeoPoint, b: com.lodo.app.core.GeoPoint) = app.geocoder.cachedLeg(a, b)
    suspend fun aiConfigured() = !app.settings.aiConfig().apiKey.isNullOrBlank()
}

private val dayFmt get() = com.lodo.app.ui.appFormatter(L("M月d日", "MMM d"))

fun tripDates(t: TripEntity): String {
    val s = t.startMillis.toLocalDateTime().toLocalDate()
    val e = t.endMillis.toLocalDateTime().toLocalDate()
    val days = ChronoUnit.DAYS.between(s, e).toInt() + 1
    return s.format(dayFmt) + " – " + e.format(dayFmt) + L(" · $days 天", " · $days days")
}

fun tripStatus(t: TripEntity, today: LocalDate = LocalDate.now()): String {
    val s = t.startMillis.toLocalDateTime().toLocalDate()
    val e = t.endMillis.toLocalDateTime().toLocalDate()
    return when {
        today.isBefore(s) -> ChronoUnit.DAYS.between(today, s).let { if (it == 1L) L("明天出发", "Leaving tomorrow") else L("$it 天后出发", "In $it days") }
        today.isAfter(e) -> L("已结束", "Ended")
        else -> L("进行中 · 第 ${ChronoUnit.DAYS.between(s, today) + 1} 天", "Day ${ChronoUnit.DAYS.between(s, today) + 1}")
    }
}

/**
 * 「旅行」页,对应 iOS TravelListView:顶部「最近旅行」大卡(进行中优先、其次最近出发、都没有退回最近结束),
 * 下面其余进行中/即将出发的,已结束的收在底部折叠栏;点进去是详情。
 */
@Composable
fun TravelScreen(vm: TravelViewModel = viewModel()) {
    val trips by vm.trips.collectAsStateWithLifecycle()
    var openUuid by rememberSaveable { mutableStateOf<String?>(null) }
    var creating by rememberSaveable { mutableStateOf(false) }
    var showPast by rememberSaveable { mutableStateOf(false) }
    val request by ShellRequests.openTrip.collectAsStateWithLifecycle()
    LaunchedEffect(request, trips.size) {
        val r = request ?: return@LaunchedEffect
        if (trips.any { it.uuid == r }) { openUuid = r; ShellRequests.openTrip.value = null }
    }
    openUuid?.let { uuid ->
        val trip = trips.firstOrNull { it.uuid == uuid }
        if (trip != null) {
            TravelDetail(trip, vm, onBack = { openUuid = null })
            return
        }
    }
    val today = LocalDate.now()
    val featured = vm.app.travel.featured(trips)
    val others = trips.filter { it.uuid != featured?.uuid && !it.endMillis.toLocalDateTime().toLocalDate().isBefore(today) }
        .sortedBy { it.startMillis }
    val past = trips.filter { it.uuid != featured?.uuid && it.endMillis.toLocalDateTime().toLocalDate().isBefore(today) }

    LodoPage(
        title = L("旅行", "Travel"),
        focus = AgentFocus(AgentPageFocus.TRAVEL),
        askPrompt = L("想去哪玩?", "Where to next?"),
        actions = { IconButton(onClick = { creating = true }) { Icon(Icons.Filled.Add, L("新建旅行", "New trip")) } },
    ) { padding ->
        if (trips.isEmpty()) {
            FullEmpty(Icons.Outlined.Flight, L("还没有旅行", "No trips yet"),
                L("说一句「帮我规划东京四天」,或「记一下:下周五去成都两天」。", "Try \"Plan 4 days in Tokyo\"."), padding)
            return@LodoPage
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp,
            top = padding.calculateTopPadding() + 4.dp, bottom = padding.calculateBottomPadding() + 16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            featured?.let { t ->
                item("featured") {
                    Card(onClick = { openUuid = t.uuid }, shape = RoundedCornerShape(28.dp),
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(t.displayEmoji, fontSize = 36.sp)
                            Text(t.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                                color = MaterialTheme.colorScheme.onPrimaryContainer)
                            Text(tripDates(t) + listOf(t.city, t.country).filter { it.isNotBlank() }.joinToString(" · ").let { if (it.isEmpty()) "" else " · $it" },
                                color = MaterialTheme.colorScheme.onPrimaryContainer)
                            Text(tripStatus(t), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                            if (t.notes.isNotBlank()) Text(t.notes, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        }
                    }
                }
            }
            if (others.isNotEmpty()) item("others-h") { Header(L("其他旅行", "Other trips")) }
            items(others, key = { it.uuid }) { TripRow(it) { openUuid = it.uuid } }
            if (past.isNotEmpty()) {
                item("past-h") {
                    TextButton(onClick = { showPast = !showPast }) {
                        Text(L("已结束(${past.size})", "Past (${past.size})"))
                        Icon(if (showPast) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore, null)
                    }
                }
                if (showPast) items(past, key = { it.uuid }) { TripRow(it) { openUuid = it.uuid } }
            }
        }
    }
    if (creating) TripEditSheet(null, vm, onSaved = { creating = false; openUuid = it }, onDismiss = { creating = false })
}

@Composable
private fun Header(text: String) =
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp, start = 4.dp))

@Composable
private fun TripRow(t: TripEntity, onClick: () -> Unit) {
    Card(onClick = onClick, shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(t.displayEmoji, fontSize = 26.sp)
            Spacer(Modifier.size(12.dp))
            Column(Modifier.weight(1f)) {
                Text(t.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(tripDates(t), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (t.notes.isNotBlank()) Text(t.notes, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
            Text(tripStatus(t), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
        }
    }
}
