package com.lodo.app.ui.settings

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.lodo.app.LodoApp
import com.lodo.app.ai.AgentSkillId
import com.lodo.app.ai.AgentSkillStore
import com.lodo.app.ai.CommandCapabilities
import com.lodo.app.ai.CommandContext
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ui.L
import com.lodo.app.ui.LodoSubPage
import com.lodo.app.ui.SectionHeader
import com.lodo.app.ui.FooterText
import com.lodo.app.ui.theme.AccentPalette
import kotlinx.coroutines.launch

/** 设置页里这一轮新增的几段:外观、AI(skill/偏好)、健康与日历、启动页。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ExtraSettingsSection(onOpenSkills: () -> Unit, onOpenPreferences: () -> Unit) {
    val app = LocalContext.current.applicationContext as LodoApp
    val settings = com.lodo.app.ui.LocalSettings.current
    val scope = rememberCoroutineScope()
    val calendarPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) scope.launch { app.settings.setCalendarEnabled(true) }
    }

    SectionHeader(L("外观", "Appearance"))
    Text(L("强调色", "Accent color"), style = MaterialTheme.typography.bodyLarge)
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(vertical = 6.dp)) {
        FilterChip(settings.accentPalette == "dynamic", { scope.launch { app.settings.setAccentPalette("dynamic") } },
            label = { Text(L("跟随壁纸", "Wallpaper")) })
        AccentPalette.entries.forEach { p ->
            FilterChip(settings.accentPalette == p.raw, { scope.launch { app.settings.setAccentPalette(p.raw) } },
                label = { Text(p.label) },
                leadingIcon = { Box(Modifier.size(16.dp).background(Color(p.lightPrimary), CircleShape)) })
        }
    }
    FooterText(L("「跟随壁纸」是 Android 12 起的 Material You 动态取色。", "\"Wallpaper\" uses Material You dynamic color."))

    SectionHeader(L("AI 助手", "AI Assistant"))
    SwitchLine(L("打开 app 时直接进入 AI 助手", "Open AI Assistant on launch"), settings.openAgentOnLaunch) {
        scope.launch { app.settings.setOpenAgentOnLaunch(it) }
    }
    NavLine(L("Skills 与最终 Prompt", "Skills & final prompt"), onOpenSkills)
    NavLine(L("AI 偏好(AI 记下的做事习惯)", "AI preferences"), onOpenPreferences)

    SectionHeader(L("健康与日历", "Health & calendar"))
    SwitchLine(L("健康分析", "Health insights"), settings.healthEnabled,
        L("只读 Health Connect,只把汇总发给 AI。去「健康」页授权。", "Read-only; only summaries go to AI. Grant access on the Health page.")) {
        scope.launch { app.settings.setHealthEnabled(it) }
    }
    SwitchLine(L("读取系统日历", "Read system calendar"), settings.calendarEnabled,
        L("在「日历」页和总览里显示系统日历的日程,只读不写。", "Shows your calendar events on Calendar and Overview. Read-only.")) { on ->
        if (on && !app.calendar.hasPermission()) calendarPermission.launch(Manifest.permission.READ_CALENDAR)
        else scope.launch { app.settings.setCalendarEnabled(on) }
    }
}

@Composable
private fun SwitchLine(title: String, checked: Boolean, subtitle: String? = null, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Switch(checked, onChange)
    }
}

@Composable
private fun NavLine(title: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Icon(Icons.Outlined.ChevronRight, null)
    }
}

/** Skill 管理(同 iOS AI 设置里的 skill 列表):按组列出,可开关、编辑、重置;看最终 Prompt。 */
@Composable
fun SkillsScreen(onBack: () -> Unit) {
    var editing by remember { mutableStateOf<AgentSkillId?>(null) }
    var showPrompt by remember { mutableStateOf(false) }
    var version by remember { mutableIntStateOf(0) }
    editing?.let { id -> SkillEditor(id, onBack = { editing = null; version++ }); return }
    if (showPrompt) { FinalPromptScreen { showPrompt = false }; return }
    LodoSubPage(L("Skills", "Skills"), onBack = onBack) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            NavLine(L("查看最终 Prompt", "View final prompt")) { showPrompt = true }
            FooterText(L("停用某个 skill 后,对应的 prompt 和操作都不生效(模型幻觉出来也不认)。", "Disabled skills are removed from the prompt and their actions are rejected."))
            @Suppress("UNUSED_VARIABLE") val v = version
            AgentSkillId.entries.groupBy { it.group }.forEach { (group, ids) ->
                SectionHeader(L("$group skills", "$group skills"))
                ids.forEach { id ->
                    var on by remember(id, version) { mutableStateOf(AgentSkillStore.isEnabled(id)) }
                    Row(Modifier.fillMaxWidth().clickable { editing = id }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(id.title + if (AgentSkillStore.isCustomized(id)) L(" · 已修改", " · edited") else "", style = MaterialTheme.typography.bodyLarge)
                            Text(id.subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        if (id.isTogglable) Switch(on, { on = it; AgentSkillStore.setEnabled(id, it) })
                    }
                    HorizontalDivider()
                }
            }
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun SkillEditor(id: AgentSkillId, onBack: () -> Unit) {
    var text by remember { mutableStateOf(AgentSkillStore.content(id)) }
    LodoSubPage(id.title, onBack = onBack, actions = {
        TextButton(onClick = { AgentSkillStore.reset(id); text = AgentSkillStore.content(id) }) { Text(L("重置", "Reset")) }
        TextButton(onClick = { AgentSkillStore.save(id, text); onBack() }) { Text(L("保存", "Save")) }
    }) { padding ->
        OutlinedTextField(text, { text = it }, textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace, fontSize = 13.sp),
            modifier = Modifier.fillMaxSize().padding(padding).imePadding().padding(12.dp))
    }
}

/** 「查看最终 Prompt」:和真实请求共用 commandSystemPrompt,不另拼一遍(同 iOS)。 */
@Composable
private fun FinalPromptScreen(onBack: () -> Unit) {
    val app = LocalContext.current.applicationContext as LodoApp
    var prompt by remember { mutableStateOf(L("生成中…", "Building…")) }
    LaunchedEffect(Unit) {
        val pending = app.database.taskDao().pending().sortedBy { it.nextRemindAtMillis }
        prompt = DeepSeekClient.commandSystemPrompt(app.settings.aiConfig(), CommandContext(
            tasks = pending.map { it.uuid to it.toParsedTask() },
            caps = CommandCapabilities(memory = true, webSearch = app.settings.webSearchConfigured(), health = app.settings.snapshot().healthEnabled,
                travel = app.travel.allTrips().isNotEmpty(), tripPlan = true, news = app.news.feeds().isNotEmpty(), countdown = true, assets = true, feeds = true),
            assets = app.library.assetEntries(),
            preferences = app.agent.preferences(), summary = app.agent.summary()?.text,
        ))
    }
    LodoSubPage(L("最终 Prompt", "Final prompt"), onBack = onBack) { padding ->
        Text(prompt, fontFamily = FontFamily.Monospace, fontSize = 12.sp,
            modifier = Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(12.dp))
    }
}

/** AI 偏好:查看/编辑/清空(agent-preferences.md,一行一条)。 */
@Composable
fun PreferencesScreen(onBack: () -> Unit) {
    val app = LocalContext.current.applicationContext as LodoApp
    var text by remember { mutableStateOf(app.agent.preferences() ?: "") }
    LodoSubPage(L("AI 偏好", "AI preferences"), onBack = onBack, actions = {
        TextButton(onClick = { app.agent.savePreferences(""); text = "" }) { Text(L("清空", "Clear")) }
        TextButton(onClick = { app.agent.savePreferences(text); onBack() }) { Icon(Icons.Filled.Check, L("保存", "Save")) }
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(12.dp)) {
            FooterText(L("AI 在对话里记下的「以后都这样办」的习惯,每次对话都会带上。一行一条。", "Long-term habits the AI noted in chats; one per line."))
            OutlinedTextField(text, { text = it }, modifier = Modifier.fillMaxSize().imePadding(), placeholder = { Text(L("还没有记下偏好", "No preferences yet")) })
        }
    }
}
