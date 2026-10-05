package com.lodo.app.ui.agent

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.filled.Undo
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Flight
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material.icons.outlined.HourglassTop
import androidx.compose.material.icons.outlined.AccountBalanceWallet
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.lodo.app.ai.AskOption
import com.lodo.app.ai.AskQuestion
import com.lodo.app.core.TravelPlan
import com.lodo.app.data.AgentKind
import com.lodo.app.data.AgentMessageEntity
import com.lodo.app.data.CountdownEditRecord
import com.lodo.app.data.LibraryEditRecord
import com.lodo.app.data.TripEditRecord
import com.lodo.app.data.TripPlanRecord
import com.lodo.app.data.taskFromJson
import com.lodo.app.data.toLocalDateTime
import com.lodo.app.data.tripPlanFromJson
import com.lodo.app.ui.L
import com.lodo.app.ui.LocalSettings
import com.lodo.app.ui.LocalShell
import com.lodo.app.ui.localizedDateTimeLabel
import com.lodo.app.ui.theme.LodoColor
import org.json.JSONObject
import java.time.format.DateTimeFormatter

/**
 * AI 助手对话页(对应 iOS AgentView):单一持续对话,AI 那侧的回复统一是一张卡片
 * (✨ 开头一句 + 条目),用户那侧是强调色实心气泡;卡片上的按钮是要做的决定(撤销/写入)。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentChat(vm: AgentViewModel, inSheet: Boolean, onClose: (() -> Unit)?) {
    val loaded by vm.messages.collectAsStateWithLifecycle()
    val messages = loaded ?: emptyList()
    val settings = LocalSettings.current
    val shell = LocalShell.current
    val listState = rememberLazyListState()
    var menuOpen by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    val latest = messages.lastOrNull()

    LaunchedEffect(messages.size, vm.busy) {
        if (messages.isNotEmpty()) listState.animateScrollToItem(messages.size + 1)
    }

    Column(Modifier.fillMaxSize().let { if (!inSheet) it else it }) {
        TopAppBar(
            title = {
                Column {
                    Text("Lodo☀️～", fontWeight = FontWeight.SemiBold)
                    Text(
                        settings.aiProvider + (vm.focus?.let { " · " + L("在「${it.page.pageName}」页", "from ${it.page.name.lowercase()}") } ?: ""),
                        style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            navigationIcon = {
                if (!inSheet) IconButton(onClick = shell.openNav) { Icon(Icons.Filled.Menu, L("导航", "Navigation")) }
            },
            actions = {
                if (onClose != null) IconButton(onClick = onClose) { Icon(Icons.Filled.Close, L("关闭", "Close")) }
                Box {
                    IconButton(onClick = { menuOpen = true }) { Icon(Icons.Filled.MoreVert, L("更多", "More")) }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(text = { Text(L("清空对话", "Clear conversation")) }, onClick = { menuOpen = false; confirmClear = true })
                        DropdownMenuItem(text = { Text(L("AI 设置", "AI settings")) }, onClick = { menuOpen = false; shell.openSettings() })
                    }
                }
            },
        )
        LazyColumn(
            state = listState,
            modifier = Modifier.weight(1f).fillMaxWidth(),
            contentPadding = PaddingValues(horizontal = 14.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (messages.size >= 60) item("earlier") {
                TextButton(onClick = vm::loadEarlier, modifier = Modifier.fillMaxWidth()) { Text(L("载入更早的对话", "Load earlier messages")) }
            }
            if (loaded != null && messages.isEmpty()) item("hello") { Greeting() }
            items(messages, key = { it.uuid }) { msg ->
                Box(Modifier.animateItem().widthIn(max = 760.dp)) {
                    MessageView(msg, vm, isLatest = msg.uuid == latest?.uuid)
                }
            }
            item("status") {
                AnimatedVisibility(vm.busy) {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(4.dp)) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.size(10.dp))
                        Text(vm.status ?: L("思考中…", "Thinking…"), style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        // 提问卡待答期间收起输入区(问题摆着等选、底下再留个输入框是两个并行入口,同 iOS)。
        val askPending = latest?.kind == AgentKind.ASK && JSONObject(latest.payloadJson ?: "{}").optString("state") == "pending"
        if (!askPending) InputBar(vm)
    }

    if (confirmClear) {
        AlertDialog(
            onDismissRequest = { confirmClear = false },
            title = { Text(L("清空对话?", "Clear conversation?")) },
            text = { Text(L("AI 助手是一条持续的对话,清空后之前的上下文就没了(已经建好的任务、收藏不受影响)。", "This removes the whole conversation history. Tasks and memories you created stay.")) },
            confirmButton = { TextButton(onClick = { confirmClear = false; vm.clearConversation() }) { Text(L("清空", "Clear"), color = LodoColor.critical) } },
            dismissButton = { TextButton(onClick = { confirmClear = false }) { Text(L("取消", "Cancel")) } },
        )
    }
}

@Composable
private fun Greeting() {
    Column(Modifier.fillMaxWidth().padding(vertical = 40.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(Icons.Filled.AutoAwesome, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(40.dp))
        Text(L("想做什么,直接说", "Just tell me what you need"), style = MaterialTheme.typography.titleMedium)
        Text(
            L("“明天下午三点开会”“记一下招行存款 32 万”“帮我规划东京四天”“订阅少数派”",
                "\"Meeting tomorrow 3pm\", \"Plan 4 days in Tokyo\", \"Subscribe to Hacker News\""),
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun InputBar(vm: AgentViewModel) {
    val context = LocalContext.current
    val focusRequester = remember { FocusRequester() }
    LaunchedEffect(vm.focusRequest) { if (vm.focusRequest > 0) runCatching { focusRequester.requestFocus() } }
    val speech = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()?.takeIf { it.isNotBlank() }?.let {
            vm.draft = vm.draft + it
            vm.send()
        }
    }
    Row(
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        TextField(
            value = vm.draft,
            onValueChange = { vm.draft = it },
            placeholder = { Text(L("说点什么…", "Say something…")) },
            shape = RoundedCornerShape(28.dp),
            colors = TextFieldDefaults.colors(
                focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
                unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
            ),
            maxLines = 6,
            modifier = Modifier.weight(1f).focusRequester(focusRequester),
            trailingIcon = {
                if (vm.draft.isBlank() && !vm.busy) IconButton(onClick = {
                    runCatching {
                        speech.launch(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM))
                    }
                }) { Icon(Icons.Filled.Mic, L("语音输入", "Voice input")) }
            },
        )
        if (vm.busy) {
            FilledIconButton(onClick = vm::cancel, modifier = Modifier.size(52.dp)) { Icon(Icons.Filled.Stop, L("取消", "Cancel")) }
        } else {
            FilledIconButton(onClick = { vm.send() }, enabled = vm.draft.isNotBlank(), modifier = Modifier.size(52.dp)) {
                Icon(Icons.AutoMirrored.Filled.Send, L("发送", "Send"))
            }
        }
    }
}

// ---------------------------------------------------------------------------

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageView(msg: AgentMessageEntity, vm: AgentViewModel, isLatest: Boolean) {
    val payload = remember(msg.payloadJson) { msg.payloadJson?.let { runCatching { JSONObject(it) }.getOrNull() } ?: JSONObject() }
    when (msg.kind) {
        AgentKind.USER -> UserBubble(msg, vm)
        AgentKind.ERROR -> AiCard(icon = Icons.Filled.ErrorOutline, tint = LodoColor.critical, header = msg.content)
        AgentKind.TEXT, AgentKind.ANSWER -> AiCard(header = msg.content, selectable = true)
        AgentKind.CONFIRM -> ConfirmCard(msg, payload, vm, isLatest)
        AgentKind.BATCH_RESULT -> {
            val lines = payload.optJSONArray("lines")
            AiCard(header = L("已完成执行", "Done") + if (payload.optInt("missing") > 0) L("(${payload.optInt("missing")} 项已不存在)", "") else "") {
                for (i in 0 until (lines?.length() ?: 0)) Text("• " + lines!!.optString(i), style = MaterialTheme.typography.bodyMedium)
                if (vm.canUndo(msg)) UndoButton { vm.undo(msg) }
                if (payload.optBoolean("undone")) Muted(L("已撤销", "Undone"))
            }
        }
        AgentKind.TASK_RESULT -> TaskResultCard(msg, payload, vm)
        AgentKind.MEMORY_RESULT -> {
            val removed = payload.optBoolean("removed")
            AiCard(
                icon = if (payload.optBoolean("auto")) Icons.Filled.AutoAwesome else Icons.Filled.Bookmark,
                header = when {
                    removed -> L("已取消收藏。", "Removed.")
                    payload.optBoolean("auto") -> L("顺带记下了", "Noted for later")
                    else -> L("已收藏", "Saved")
                },
            ) {
                if (!removed) ItemLine(payload.optString("title"), payload.optString("summary")) {
                    IconButton(onClick = { vm.removeMemory(msg) }) { Icon(Icons.Filled.Close, L("取消收藏", "Remove")) }
                }
            }
        }
        AgentKind.SUGGEST_MEMORIZE -> AiCard(header = L("这条以后可能用得上,要收藏吗?", "Worth saving for later?")) {
            Text(payload.optString("text"), style = MaterialTheme.typography.bodyMedium)
            if (payload.optBoolean("saved")) Muted(L("已收藏", "Saved"))
            else FilledTonalButton(onClick = { vm.saveSuggestion(msg) }) { Text(L("收藏这条", "Save this")) }
        }
        AgentKind.ASK -> AskCard(msg, payload, vm)
        AgentKind.COUNTDOWN_EDIT -> CountdownCard(msg, vm)
        AgentKind.LIBRARY_EDIT -> LibraryCard(msg, vm)
        AgentKind.TRIP_PLAN -> TripPlanCard(msg, payload, vm, isLatest)
        AgentKind.TRIP_EDIT -> TripEditCard(msg, vm)
        else -> AiCard(header = msg.content)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun UserBubble(msg: AgentMessageEntity, vm: AgentViewModel) {
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Surface(
            color = MaterialTheme.colorScheme.primary,
            contentColor = MaterialTheme.colorScheme.onPrimary,
            shape = RoundedCornerShape(topStart = 22.dp, topEnd = 22.dp, bottomStart = 22.dp, bottomEnd = 6.dp),
            modifier = Modifier.widthIn(max = 320.dp).combinedClickable(onClick = {}, onLongClick = { menu = true }),
        ) {
            Text(msg.content, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp))
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text(L("修改", "Edit")) }, onClick = { menu = false; vm.editFrom(msg) })
            DropdownMenuItem(text = { Text(L("复制", "Copy")) }, onClick = {
                menu = false
                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("lodo", msg.content))
            })
        }
    }
}

/** AI 那一侧的统一卡片:✨ 开头一句 + 下面的条目(同 iOS AgentResultReply)。 */
@Composable
private fun AiCard(
    icon: androidx.compose.ui.graphics.vector.ImageVector = Icons.Filled.AutoAwesome,
    tint: Color? = null,
    header: String,
    selectable: Boolean = false,
    content: (@Composable () -> Unit)? = null,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(topStart = 6.dp, topEnd = 22.dp, bottomStart = 22.dp, bottomEnd = 22.dp),
        modifier = Modifier.fillMaxWidth(0.94f).animateContentSize(),
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                Icon(icon, null, tint = tint ?: MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 2.dp).size(18.dp))
                Spacer(Modifier.size(8.dp))
                if (selectable) {
                    androidx.compose.foundation.text.selection.SelectionContainer {
                        Text(header, style = MaterialTheme.typography.bodyLarge)
                    }
                } else Text(header, style = MaterialTheme.typography.bodyLarge, fontWeight = if (content != null) FontWeight.Medium else null)
            }
            content?.invoke()
        }
    }
}

@Composable
private fun Muted(text: String) = Text(text, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun UndoButton(label: String = L("撤销", "Undo"), onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp)) {
        Icon(Icons.AutoMirrored.Filled.Undo, null, modifier = Modifier.size(16.dp))
        Spacer(Modifier.size(6.dp))
        Text(label)
    }
}

@Composable
private fun ItemLine(title: String, subtitle: String?, leading: (@Composable () -> Unit)? = null, trailing: (@Composable () -> Unit)? = null) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        leading?.invoke()
        Column(Modifier.weight(1f).padding(start = if (leading != null) 8.dp else 0.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.Medium)
            if (!subtitle.isNullOrBlank()) Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 3)
        }
        trailing?.invoke()
    }
}

@Composable
private fun JumpLink(text: String, onClick: () -> Unit) {
    TextButton(onClick = onClick, contentPadding = PaddingValues(horizontal = 4.dp)) {
        Text(text, style = MaterialTheme.typography.labelLarge)
        Icon(Icons.Outlined.ChevronRight, null, modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun ConfirmCard(msg: AgentMessageEntity, payload: JSONObject, vm: AgentViewModel, isLatest: Boolean) {
    val lines = payload.optJSONArray("lines")
    val state = payload.optString("state")
    AiCard(icon = Icons.Outlined.HelpOutline, header = L("确认执行这些操作?", "Run these actions?")) {
        for (i in 0 until (lines?.length() ?: 0)) Text("• " + lines!!.optString(i), style = MaterialTheme.typography.bodyMedium)
        when {
            state == "done" -> Muted(L("已确认执行", "Confirmed"))
            state == "cancelled" -> Muted(L("已取消", "Cancelled"))
            vm.canConfirm(msg) && isLatest -> Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { vm.cancelConfirm(msg) }) { Text(L("取消", "Cancel")) }
                Button(onClick = { vm.confirm(msg) }) { Text(L("确认执行", "Confirm")) }
            }
            else -> Muted(L("已过期", "Expired"))
        }
    }
}

@Composable
private fun TaskResultCard(msg: AgentMessageEntity, payload: JSONObject, vm: AgentViewModel) {
    val task = remember(msg.payloadJson) { runCatching { taskFromJson(payload.getJSONObject("task")) }.getOrNull() } ?: return
    val created = payload.optString("mode") == "created"
    val removed = payload.optBoolean("removed")
    val caption = localizedDateTimeLabel(task.nextRemindAt) + if (task.project.isNotBlank()) " · ${task.project}" else ""
    val shell = LocalShell.current
    Column {
        AiCard(header = when {
            removed -> L("已取消新建", "Creation cancelled")
            created -> L("已新建", "Created")
            else -> L("已修改", "Updated")
        }) {
            ItemLine(
                task.title, caption,
                leading = if (created) ({
                    IconButton(onClick = { vm.toggleCreated(msg) }) {
                        if (removed) Icon(Icons.Outlined.Cancel, L("重新新建", "Re-create"), tint = MaterialTheme.colorScheme.outline)
                        else Icon(Icons.Filled.CheckCircle, L("取消新建", "Cancel"), tint = MaterialTheme.colorScheme.primary)
                    }
                }) else null,
                trailing = if (!created && vm.canUndo(msg)) ({
                    IconButton(onClick = { vm.undo(msg) }) { Icon(Icons.AutoMirrored.Filled.Undo, L("改回原样", "Revert")) }
                }) else null,
            )
            if (!created && payload.optBoolean("undone")) Muted(L("已改回原样", "Reverted"))
        }
        if (!removed) JumpLink(L("任务", "Tasks") + " · " + task.title) { shell.go(com.lodo.app.ui.AppSection.TASKS) }
    }
}

@Composable
private fun CountdownCard(msg: AgentMessageEntity, vm: AgentViewModel) {
    val r = remember(msg.payloadJson) { CountdownEditRecord.decode(msg.payloadJson) } ?: return
    val shell = LocalShell.current
    val fmt = DateTimeFormatter.ofPattern("yyyy-MM-dd")
    Column {
        AiCard(icon = Icons.Outlined.HourglassTop, header = if (r.reverted) L("已撤销倒数日的改动", "Countdown changes undone") else L("倒数日已更新", "Countdowns updated")) {
            r.created.forEach { ItemLine(L("新建 · ", "New · ") + it.title, it.startMillis.toLocalDateTime().format(fmt)) }
            r.updatedAfter.forEach { ItemLine(L("修改 · ", "Edited · ") + it.title, it.startMillis.toLocalDateTime().format(fmt) + if (it.archived) L(" · 已归档", " · archived") else "") }
            r.deleted.forEach { ItemLine(L("删除 · ", "Deleted · ") + it.title, null) }
            r.skipped.forEach { Muted("· $it") }
            if (r.hasChanges) UndoButton(if (r.reverted) L("重新执行", "Redo") else L("撤销", "Undo")) { vm.toggleCountdown(msg) }
        }
        if (r.hasChanges && !r.reverted) JumpLink(L("倒数", "Countdown")) { shell.go(com.lodo.app.ui.AppSection.COUNTDOWN) }
    }
}

@Composable
private fun LibraryCard(msg: AgentMessageEntity, vm: AgentViewModel) {
    val r = remember(msg.payloadJson) { LibraryEditRecord.decode(msg.payloadJson) } ?: return
    val shell = LocalShell.current
    Column {
        AiCard(icon = Icons.Outlined.AccountBalanceWallet, header = when {
            r.reverted -> L("已撤销", "Undone")
            r.hasChanges -> L("已更新", "Updated")
            else -> L("没有改动", "Nothing changed")
        }) {
            r.lines.forEach {
                ItemLine((if (it.created) L("新增 · ", "New · ") else L("修改 · ", "Edited · ")) + it.title, it.detail.trim())
            }
            r.skipped.forEach { Muted("· $it") }
            if (r.hasChanges && !r.reverted) UndoButton { vm.toggleLibrary(msg) }
        }
        if (r.hasChanges && !r.reverted) {
            val domain = r.lines.first().domain
            JumpLink(if (domain == "asset") L("资产", "Assets") else L("新闻", "News")) {
                shell.go(if (domain == "asset") com.lodo.app.ui.AppSection.ASSETS else com.lodo.app.ui.AppSection.NEWS)
            }
        }
    }
}

@Composable
private fun TripEditCard(msg: AgentMessageEntity, vm: AgentViewModel) {
    val r = remember(msg.payloadJson) { TripEditRecord.decode(msg.payloadJson) } ?: return
    val shell = LocalShell.current
    Column {
        AiCard(icon = Icons.Outlined.Flight, header = (if (r.reverted) L("已撤销对「${r.tripTitle}」的调整", "Changes to \"${r.tripTitle}\" undone")
        else L("已调整「${r.tripTitle}」", "Adjusted \"${r.tripTitle}\"")) + if (r.summary.isNotBlank()) ":${r.summary}" else "") {
            r.removed.forEach { ItemLine(L("删掉 · ", "Removed · ") + it.title, null) }
            r.addedTitles.forEach { ItemLine(L("新增 · ", "Added · ") + it, null) }
            r.updatedTitles.forEach { ItemLine(L("修改 · ", "Edited · ") + it, null) }
            r.skipped.forEach { Muted("· $it") }
            if (!r.reverted) UndoButton { vm.toggleTripEdit(msg) }
        }
        if (!r.reverted) JumpLink(L("旅行已更新:", "Trip updated: ") + r.tripTitle) { shell.openTrip(r.tripUuid) }
    }
}

@Composable
private fun TripPlanCard(msg: AgentMessageEntity, payload: JSONObject, vm: AgentViewModel, isLatest: Boolean) {
    val plan = remember(msg.payloadJson) { runCatching { tripPlanFromJson(payload.getJSONObject("plan")) }.getOrNull() } ?: return
    val record = TripPlanRecord.from(payload.optJSONObject("record"))
    val reverted = payload.optBoolean("reverted")
    val shell = LocalShell.current
    val days = remember(plan) { TravelPlan.days(plan.startDate, plan.endDate) }
    val entries = remember(plan) {
        plan.items.mapIndexed { i, it ->
            com.lodo.app.core.TravelEntry("$i", it.kind, it.title, it.note, it.start, it.end, it.price, it.currency ?: "CNY", it.placeName, code = it.code)
        }
    }
    var expanded by remember { mutableStateOf(setOf(0)) }
    val dayFmt = DateTimeFormatter.ofPattern(L("M月d日 E", "MMM d, E"))
    val timeFmt = DateTimeFormatter.ofPattern("HH:mm")
    Column {
        AiCard(icon = Icons.Outlined.Flight, header = (if (plan.recorded) L("已记下「${plan.tripTitle}」", "Recorded \"${plan.tripTitle}\"") else L("规划了「${plan.tripTitle}」", "Planned \"${plan.tripTitle}\"")) +
            (if (plan.summary.isNotBlank()) "\n" + plan.summary else "")) {
            Muted("${plan.startDate} – ${plan.endDate}" + listOfNotNull(plan.city, plan.country).joinToString(" · ").let { if (it.isNotEmpty()) " · $it" else "" })
            val grouped = TravelPlan.group(entries, days)
            grouped.forEachIndexed { i, day ->
                val all = day.entries + TravelPlan.lodgings(day.date, entries)
                if (all.isEmpty()) return@forEachIndexed
                Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(16.dp)).padding(10.dp)) {
                    TextButton(onClick = { expanded = if (i in expanded) expanded - i else expanded + i }, contentPadding = PaddingValues(0.dp)) {
                        Text(L("第 ${i + 1} 天 · ", "Day ${i + 1} · ") + day.date.format(dayFmt) + L(" · ${all.size} 项", " · ${all.size} items"),
                            fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f))
                    }
                    if (i in expanded) all.forEach { e ->
                        Text((e.start?.format(timeFmt)?.let { "$it  " } ?: "") + e.title + (e.placeName?.let { " · $it" } ?: ""),
                            style = MaterialTheme.typography.bodyMedium)
                        if (e.note.isNotBlank()) Text(e.note, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
            TravelPlan.unscheduled(entries).takeIf { it.isNotEmpty() }?.let { list ->
                Muted(L("待安排:", "Unscheduled: ") + list.joinToString("、") { it.title })
            }
            when {
                record != null -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Muted(L("已写入行程", "Saved to Travel"))
                    UndoButton { vm.toggleTripPlan(msg) }
                }
                reverted -> FilledTonalButton(onClick = { vm.toggleTripPlan(msg) }) { Text(L("重新写入", "Save again")) }
                isLatest -> Button(onClick = { vm.toggleTripPlan(msg) }) { Text(L("写入行程", "Save to Travel")) }
                else -> Muted(L("这份规划已被后面的修改取代", "Superseded by a later plan"))
            }
        }
        if (record != null) JumpLink(L("旅行:", "Trip: ") + plan.tripTitle) { shell.openTrip(record.tripUuid) }
    }
}

/** 提问卡:可翻页、单选/多选、推荐项、「其他」自由输入;答完原地变成只读记录(同 iOS AgentAskCard)。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AskCard(msg: AgentMessageEntity, payload: JSONObject, vm: AgentViewModel) {
    val questions = remember(msg.payloadJson) {
        val arr = payload.optJSONArray("questions")
        (0 until (arr?.length() ?: 0)).map { i ->
            val q = arr!!.getJSONObject(i)
            val opts = q.optJSONArray("options")
            AskQuestion(q.optString("header"), q.optString("question"), q.optBoolean("multi_select"),
                (0 until (opts?.length() ?: 0)).map { j ->
                    val o = opts!!.getJSONObject(j)
                    AskOption(o.optString("label"), o.optString("description"), o.optBoolean("recommended"))
                })
        }
    }
    val state = payload.optString("state")
    if (state != "pending") {
        AiCard(icon = Icons.Outlined.HelpOutline, header = questions.joinToString("\n") { it.question }) {
            val answers = payload.optJSONArray("answers")
            if (state == "cancelled") Muted(L("已取消", "Cancelled"))
            for (i in 0 until (answers?.length() ?: 0)) {
                val a = answers!!.getJSONObject(i)
                Text("✓ " + a.optString("a"), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
            }
        }
        return
    }
    var page by remember { mutableStateOf(0) }
    val selections = remember { mutableStateMapOf<Int, Set<String>>() }
    val others = remember { mutableStateMapOf<Int, String>() }
    val q = questions.getOrNull(page) ?: return
    AiCard(icon = Icons.Outlined.HelpOutline, header = (if (q.header.isNotBlank()) q.header + " · " else "") +
        (if (questions.size > 1) "${page + 1}/${questions.size}" else "")) {
        Text(q.question, style = MaterialTheme.typography.titleMedium)
        q.options.forEach { o ->
            val chosen = selections[page].orEmpty().contains(o.label)
            Surface(
                onClick = {
                    val cur = selections[page].orEmpty()
                    selections[page] = if (q.multiSelect) (if (chosen) cur - o.label else cur + o.label) else setOf(o.label)
                    others.remove(page)
                },
                shape = RoundedCornerShape(16.dp),
                color = if (chosen) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerHighest,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp)) {
                    if (q.multiSelect) Checkbox(checked = chosen, onCheckedChange = null) else RadioButton(selected = chosen, onClick = null)
                    Column(Modifier.weight(1f).padding(start = 8.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(o.label, fontWeight = FontWeight.Medium)
                            if (o.recommended) Text(L(" · 推荐", " · Recommended"), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                        }
                        if (o.description.isNotBlank()) Text(o.description, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
        OutlinedTextField(
            value = others[page] ?: "", onValueChange = { others[page] = it; if (it.isNotBlank() && !q.multiSelect) selections.remove(page) },
            placeholder = { Text(L("其他…", "Other…")) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
        )
        val answered = selections[page].orEmpty().isNotEmpty() || !others[page].isNullOrBlank()
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { vm.cancelAsk(msg) }) { Text(L("取消", "Cancel")) }
            Spacer(Modifier.weight(1f))
            if (page > 0) OutlinedButton(onClick = { page-- }) { Text(L("上一题", "Back")) }
            if (page < questions.size - 1) {
                Button(onClick = { page++ }, enabled = answered) { Text(L("下一题", "Next")) }
            } else {
                Button(enabled = answered && questions.indices.all { selections[it].orEmpty().isNotEmpty() || !others[it].isNullOrBlank() }, onClick = {
                    val answers = questions.mapIndexed { i, qq ->
                        val parts = selections[i].orEmpty().toList() + listOfNotNull(others[i]?.takeIf { it.isNotBlank() })
                        (qq.header.ifBlank { qq.question }) to parts.joinToString("、")
                    }
                    vm.answerAsk(msg, answers)
                }) { Text(L("提交", "Submit")) }
            }
        }
    }
}
