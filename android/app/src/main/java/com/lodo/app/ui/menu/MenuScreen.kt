package com.lodo.app.ui.menu

import android.app.Application
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.LodoApp
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.core.MenuPlan
import com.lodo.app.data.MemoryEntity
import com.lodo.app.data.MenuDishEntity
import com.lodo.app.data.Ocr
import com.lodo.app.data.formatAmount
import com.lodo.app.ui.FullEmpty
import com.lodo.app.ui.GroupCard
import com.lodo.app.ui.L
import com.lodo.app.ui.LodoPage
import com.lodo.app.ui.LodoRow
import com.lodo.app.ui.LodoSubPage
import com.lodo.app.ui.assets.SheetHeader
import com.lodo.app.ui.theme.LodoColor
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File
import java.time.format.DateTimeFormatter

class MenuViewModel(application: Application) : AndroidViewModel(application) {
    val app = application as LodoApp
    val memories = app.memoryRepository.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val dishes = app.menus.observeAllDishes().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    var busy by mutableStateOf(false)
        private set
    var status by mutableStateOf<String?>(null)
        private set
    var error by mutableStateOf<String?>(null)

    /** 拍照/截图(端上 OCR)和贴的文字合在一起交给 AI,整理完直接落库(不给确认页,同 iOS)。 */
    fun create(text: String, images: List<Uri>, done: (String) -> Unit) = viewModelScope.launch {
        busy = true; error = null
        try {
            status = L("识别文字…", "Reading text…")
            val ocr = images.map { Ocr.recognize(app, it) }.filter { it.isNotBlank() }
            val all = (listOf(text) + ocr).filter { it.isNotBlank() }.joinToString("\n\n")
            if (all.isBlank()) throw IllegalStateException(L("没有读出文字", "No text recognized"))
            status = L("AI 整理菜单…", "Organizing menu…")
            done(app.menus.create(app.settings.aiConfig(), all).uuid)
        } catch (e: Exception) {
            error = e.message
        } finally { busy = false; status = null }
    }

    fun toggle(d: MenuDishEntity) = viewModelScope.launch { app.menus.setSelected(d.uuid, !d.selected) }
    fun clear(menuUuid: String) = viewModelScope.launch { app.menus.clearSelection(menuUuid) }
    fun delete(uuid: String) = viewModelScope.launch { app.memoryRepository.delete(uuid) }
}

/**
 * 「菜单」页,对应 iOS MenuListView:拍照/截图/贴文字 → 端上识别 → AI 整理成菜品清单并翻译;
 * 点菜的勾选持久化,底部悬浮条拉起「给服务员看」的点单页(原文名放大在上、译名小字在下)。
 */
@Composable
fun MenuScreen(vm: MenuViewModel = viewModel()) {
    val memories by vm.memories.collectAsStateWithLifecycle()
    val dishes by vm.dishes.collectAsStateWithLifecycle()
    val menus = memories.filter { it.isMenu }
    var openUuid by rememberSaveable { mutableStateOf<String?>(null) }
    var importing by remember { mutableStateOf(false) }
    openUuid?.let { uuid ->
        menus.firstOrNull { it.uuid == uuid }?.let { menu ->
            MenuDetail(menu, dishes.filter { it.menuUuid == uuid }.sortedBy { it.sortIndex }, vm) { openUuid = null }
            return
        }
    }
    LodoPage(
        title = L("菜单", "Menu"),
        focus = AgentFocus(AgentPageFocus.MENU),
        askPrompt = L("在吃什么呀?", "What are we eating?"),
        actions = { IconButton(onClick = { importing = true }) { Icon(Icons.Filled.Add, L("新菜单", "New menu")) } },
    ) { padding ->
        if (menus.isEmpty()) {
            FullEmpty(Icons.AutoMirrored.Outlined.MenuBook, L("还没有菜单", "No menus yet"),
                L("在餐厅拍一张菜单,lodo 帮你翻译、介绍每道菜,点好了给服务员看。", "Snap a menu — Lodo translates and explains each dish."), padding) {
                androidx.compose.material3.Button(onClick = { importing = true }) { Text(L("拍菜单", "Scan a menu")) }
            }
        } else LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp,
            top = padding.calculateTopPadding() + 4.dp, bottom = padding.calculateBottomPadding() + 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(menus, key = { it.uuid }) { m ->
                val count = dishes.count { it.menuUuid == m.uuid }
                Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    LodoRow(m.title, icon = Icons.AutoMirrored.Outlined.MenuBook, onClick = { openUuid = m.uuid },
                        subtitle = listOfNotNull(L("$count 道菜", "$count dishes"), m.menuSourceLanguage?.takeIf { it.isNotBlank() },
                            m.createdAt.format(com.lodo.app.ui.appFormatter("yyyy-MM-dd"))).joinToString(" · "))
                }
            }
        }
    }
    if (importing) ImportMenuSheet(vm, onDone = { importing = false; openUuid = it }, onDismiss = { importing = false })
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ImportMenuSheet(vm: MenuViewModel, onDone: (String) -> Unit, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var text by remember { mutableStateOf("") }
    var images by remember { mutableStateOf(listOf<Uri>()) }
    var pendingCamera by remember { mutableStateOf<Uri?>(null) }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
        if (ok) pendingCamera?.let { images = images + it }
    }
    val gallery = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(6)) { uris -> images = images + uris }
    ModalBottomSheet(onDismissRequest = { if (!vm.busy) onDismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            SheetHeader(L("新菜单", "New menu"), (text.isNotBlank() || images.isNotEmpty()) && !vm.busy, onDismiss) {
                vm.create(text, images, onDone)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = {
                    val dir = File(context.cacheDir, "camera").apply { mkdirs() }
                    val file = File(dir, "menu-${System.currentTimeMillis()}.jpg")
                    val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
                    pendingCamera = uri
                    runCatching { camera.launch(uri) }
                }) { Icon(Icons.Outlined.CameraAlt, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(L("拍照", "Camera")) }
                OutlinedButton(onClick = { gallery.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                    Icon(Icons.Outlined.Image, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)); Text(L("相册", "Photos"))
                }
            }
            if (images.isNotEmpty()) Text(L("已选 ${images.size} 张图片(在手机上识别文字,图片不上传)", "${images.size} image(s) selected (OCR on device)"),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
            OutlinedTextField(text, { text = it }, placeholder = { Text(L("也可以直接贴菜单文字…", "Or paste menu text…")) }, modifier = Modifier.fillMaxWidth(), minLines = 4)
            if (vm.busy) Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp); Spacer(Modifier.width(8.dp)); Text(vm.status ?: "")
            }
            vm.error?.let { Text(it, color = LodoColor.critical) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun MenuDetail(menu: MemoryEntity, dishes: List<MenuDishEntity>, vm: MenuViewModel, onBack: () -> Unit) {
    val selected = dishes.filter { it.selected }
    val currency = menu.menuCurrency ?: ""
    var order by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    LodoSubPage(
        title = menu.title, onBack = onBack,
        focus = AgentFocus(AgentPageFocus.MENU, menu.title),
        actions = { TextButton(onClick = { confirmDelete = true }) { Text(L("删除", "Delete"), color = MaterialTheme.colorScheme.error) } },
        floatingActionButton = {
            if (selected.isNotEmpty()) {
                val total = MenuPlan.total(selected.map { it.price })
                ExtendedFloatingActionButton(onClick = { order = true }, icon = { Icon(Icons.Filled.CheckCircle, null) },
                    text = { Text(L("已点 ${selected.size} 道", "${selected.size} picked") + (total.amount?.let { " · " + formatAmount(it, currency).trim() } ?: "")) })
            }
        },
    ) { padding ->
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp,
            top = padding.calculateTopPadding(), bottom = padding.calculateBottomPadding() + 96.dp)) {
            MenuPlan.grouped(dishes) { it.category }.forEach { (cat, list) ->
                item(cat.ifBlank { "_other" }) {
                    GroupCard(title = cat.ifBlank { L("其他", "Other") }) {
                        list.forEachIndexed { i, d ->
                            if (i > 0) HorizontalDivider(Modifier.padding(start = 52.dp))
                            LodoRow(
                                d.translatedName.ifBlank { d.originalName }, onClick = { vm.toggle(d) }, maxSubtitleLines = 3,
                                subtitle = listOfNotNull(d.originalName.takeIf { it != d.translatedName && d.translatedName.isNotBlank() }, d.intro.takeIf { it.isNotBlank() }).joinToString("\n"),
                                leading = { Icon(if (d.selected) Icons.Filled.CheckCircle else Icons.Outlined.Circle, null,
                                    tint = if (d.selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline) },
                                trailing = { d.price?.let { Text(formatAmount(it, currency).trim(), fontWeight = FontWeight.SemiBold) } },
                            )
                        }
                    }
                }
            }
        }
    }
    if (order) OrderSheet(selected, currency, onClear = { vm.clear(menu.uuid); order = false }, onDismiss = { order = false })
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        title = { Text(L("删除这张菜单?", "Delete this menu?")) },
        confirmButton = { TextButton(onClick = { vm.delete(menu.uuid); confirmDelete = false; onBack() }) { Text(L("删除", "Delete"), color = LodoColor.critical) } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(L("取消", "Cancel")) } },
    )
}

/** 给服务员看的那张:原文名放大在上,译名小字在下。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun OrderSheet(selected: List<MenuDishEntity>, currency: String, onClear: () -> Unit, onDismiss: () -> Unit) {
    val total = MenuPlan.total(selected.map { it.price })
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.verticalScroll(rememberScrollState()).navigationBarsPadding().padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(L("给服务员看", "Show to staff"), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                TextButton(onClick = onClear) { Text(L("清空", "Clear")) }
            }
            selected.forEach { d ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(d.originalName, fontSize = 26.sp, fontWeight = FontWeight.Bold)
                        if (d.translatedName.isNotBlank() && d.translatedName != d.originalName) Text(d.translatedName, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    d.price?.let { Text(formatAmount(it, currency).trim(), style = MaterialTheme.typography.titleMedium) }
                }
            }
            HorizontalDivider()
            Box(Modifier.fillMaxWidth()) {
                Text(total.amount?.let { L("合计 ", "Total ") + formatAmount(it, currency).trim() } ?: L("没有标价", "No prices"), style = MaterialTheme.typography.titleMedium)
            }
            if (total.unpricedCount > 0 && total.amount != null) Text(L("另有 ${total.unpricedCount} 道没标价", "${total.unpricedCount} without price"), style = MaterialTheme.typography.bodySmall)
            Spacer(Modifier.height(24.dp))
        }
    }
}
