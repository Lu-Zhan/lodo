package com.lodo.app.ui.settings

import com.lodo.app.R
import androidx.compose.ui.res.stringResource
import android.app.AlarmManager
import android.content.Intent
import android.os.Build
import android.provider.Settings as SystemSettings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.core.TimeFormat
import com.lodo.app.data.aiProviderPresets
import com.lodo.app.data.personaPresets
import com.lodo.app.core.weekdayNames
import com.lodo.app.ui.FooterText
import com.lodo.app.ui.LodoTimePickerDialog
import com.lodo.app.ui.SectionHeader
import com.lodo.app.ui.StepperRow

/** 设置页,分节与文案对应 iOS SettingsView(钥匙串改为本机加密存储)。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SettingsScreen(
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    vm: SettingsViewModel = viewModel(),
) {
    val settings by vm.settings.collectAsStateWithLifecycle()
    val context = LocalContext.current

    var showAllDayPicker by remember { mutableStateOf(false) }
    var editingDigestIndex by remember { mutableStateOf<Int?>(null) }
    var showMemoryEditor by remember { mutableStateOf(false) }
    var confirmMemoryReset by remember { mutableStateOf(false) }

    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.shared_settings)) },
                navigationIcon = {
                    onBack?.let {
                        IconButton(onClick = it) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.android_ui_back))
                        }
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
        ) {
            SectionHeader(stringResource(R.string.shared_language))
            SingleChoiceSegmentedButtonRow(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            ) {
                // 语言名称本身不查生成表(和 iOS AppLanguage.displayName 同一个思路:
                // 这两个词本身就是"人类可读语言名",不是需要翻译的 UI 文案)。
                listOf("zh" to "中文", "en" to "English").forEachIndexed { index, (code, label) ->
                    SegmentedButton(
                        selected = settings.language == code,
                        onClick = { vm.setLanguage(code) },
                        shape = SegmentedButtonDefaults.itemShape(index = index, count = 2),
                    ) { Text(label) }
                }
            }
            FooterText(stringResource(R.string.shared_independent_of_the_system_language))

            SectionHeader(stringResource(R.string.shared_reminders))
            StepperRow(
                label = stringResource(R.string.android_ui_snooze_interval_0_min),
                onDecrement = { vm.setSnoozeMinutes(settings.snoozeMinutes - 5) },
                onIncrement = { vm.setSnoozeMinutes(settings.snoozeMinutes + 5) },
            )
            TimeRow("全天事项提醒时间", settings.allDayTime) { showAllDayPicker = true }
            FooterText("稍等或忽略提醒后,间隔多久再次提醒,直到完成。")
            FooterText("只有日期、没有时间的事项,当天几点提醒。")

            SectionHeader(stringResource(R.string.android_ui_daily_digest))
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "每日待办汇总",
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = settings.digestEnabled, onCheckedChange = vm::setDigestEnabled)
            }
            if (settings.digestEnabled) {
                SingleChoiceSegmentedButtonRow(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                ) {
                    listOf("daily" to "每天", "weekly" to "每周").forEachIndexed { index, (type, label) ->
                        SegmentedButton(
                            selected = settings.digestRepeatType == type,
                            onClick = { vm.setDigestRepeatType(type) },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 2),
                        ) { Text(label) }
                    }
                }
                if (settings.digestRepeatType == "weekly") {
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.padding(vertical = 4.dp),
                    ) {
                        for (i in 0..6) {
                            FilterChip(
                                selected = i in settings.digestDays,
                                onClick = {
                                    val days = if (i in settings.digestDays) {
                                        settings.digestDays - i
                                    } else {
                                        settings.digestDays + i
                                    }
                                    vm.setDigestDays(days)
                                },
                                label = { Text(weekdayNames[i].drop(1)) },
                            )
                        }
                    }
                }
                settings.digestTimes.forEachIndexed { i, hhmm ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Row(
                            modifier = Modifier
                                .weight(1f)
                                .clickable { editingDigestIndex = i }
                                .padding(vertical = 12.dp),
                        ) {
                            Text(stringResource(R.string.android_ui_time_0), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            Text(hhmm, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                        }
                        IconButton(onClick = {
                            vm.setDigestTimes(settings.digestTimes.filterIndexed { j, _ -> j != i })
                        }) {
                            Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.android_ui_remove_time))
                        }
                    }
                }
                TextButton(onClick = { vm.setDigestTimes(settings.digestTimes + "09:00") }) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(stringResource(R.string.shared_add_a_time))
                }
            }
            FooterText("在设定时间提醒今天开始或到期的事项。")

            SectionHeader(stringResource(R.string.shared_haptic_feedback))
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.shared_haptic_feedback),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = settings.hapticsEnabled, onCheckedChange = vm::setHapticsEnabled)
            }
            FooterText("滑动完成、删除等操作时轻微振动。")

            SectionHeader(stringResource(R.string.android_ui_start_voice_input_when_adding))
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.android_ui_start_voice_input_when_adding),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Switch(
                    checked = settings.agentAutoRecordOnOpen,
                    onCheckedChange = vm::setAgentAutoRecordOnOpen,
                )
            }
            FooterText("点击添加按钮弹出 AI 助手时自动开始语音输入;关闭则需手动点麦克风按钮。")
            StepperRow(
                label = stringResource(R.string.android_ui_auto_stop_after_silence_0_s),
                onDecrement = {
                    vm.setAgentSilenceTimeoutSeconds(settings.agentSilenceTimeoutSeconds - 1)
                },
                onIncrement = {
                    vm.setAgentSilenceTimeoutSeconds(settings.agentSilenceTimeoutSeconds + 1)
                },
            )
            FooterText("语音输入静音超过设定时长自动停止并提交;0 秒 = 关闭,不自动停止。")

            // ---- AI:服务 → 个性 → 洞察 → 记忆 ----
            SectionHeader(stringResource(R.string.shared_ai_service))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                (aiProviderPresets.map { it.name } + "自定义").forEach { name ->
                    FilterChip(
                        selected = settings.aiProvider == name,
                        onClick = { vm.setAiProvider(name) },
                        label = { Text(name) },
                    )
                }
            }
            if (settings.aiProvider == "自定义") {
                OutlinedTextField(
                    value = settings.aiCustomEndpoint,
                    onValueChange = vm::setAiCustomEndpoint,
                    placeholder = { Text(stringResource(R.string.shared_endpoint_chat_completions)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
            }
            OutlinedTextField(
                value = settings.aiModel,
                onValueChange = vm::setAiModel,
                placeholder = {
                    Text(
                        if (settings.aiProvider == "自定义") "模型名称"
                        else "模型(默认 ${aiProviderPresets.firstOrNull { it.name == settings.aiProvider }?.model ?: ""})"
                    )
                },
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            OutlinedTextField(
                value = vm.apiKey,
                onValueChange = vm::onApiKeyChange,
                placeholder = { Text("API Key") },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
            )
            Button(
                onClick = vm::saveApiKey,
                enabled = !vm.keySaved,
                modifier = Modifier.padding(top = 8.dp),
            ) {
                Text(if (vm.keySaved) "已保存" else "保存 API Key")
            }
            FooterText("默认 DeepSeek;各服务商均为 OpenAI 兼容接口,key 按服务商分别加密存储在本机。")

            SectionHeader(stringResource(R.string.shared_ai_thinking))
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                listOf("off" to "关闭", "low" to "低", "medium" to "中", "high" to "高")
                    .forEachIndexed { index, (level, label) ->
                        SegmentedButton(
                            selected = settings.thinkingLevel == level,
                            onClick = { vm.setThinkingLevel(level) },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 4),
                        ) { Text(label) }
                    }
            }
            FooterText("思考强度越高,回答通常越准确但等待更久;只有支持推理的服务商/模型才会真正生效,其余会忽略这个设置。")

            SectionHeader(stringResource(R.string.shared_web_search))
            OutlinedTextField(
                value = vm.tavilyKey,
                onValueChange = vm::onTavilyKeyChange,
                placeholder = { Text("Tavily API Key") },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = vm::saveTavilyKey,
                enabled = !vm.tavilyKeySaved,
                modifier = Modifier.padding(top = 8.dp),
            ) {
                Text(if (vm.tavilyKeySaved) "已保存" else "保存")
            }
            FooterText("配置后 AI 助手能在需要最新信息或回答一般问题时联网搜索;免费在 tavily.com 注册获取 API Key,不填则不启用联网搜索。")

            SectionHeader(stringResource(R.string.shared_ai_personality))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                (listOf("默认") + personaPresets.map { it.first } + "自定义").forEach { name ->
                    FilterChip(
                        selected = settings.personaStyle == name,
                        onClick = { vm.setPersonaStyle(name) },
                        label = { Text(name) },
                    )
                }
            }
            if (settings.personaStyle == "自定义") {
                OutlinedTextField(
                    value = settings.personaCustom,
                    onValueChange = vm::setPersonaCustom,
                    placeholder = { Text(stringResource(R.string.shared_describe_the_ai_s_tone_e_g_like_a_wuxia)) },
                    minLines = 1,
                    maxLines = 4,
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
            } else {
                personaPresets.firstOrNull { it.first == settings.personaStyle }?.let { preset ->
                    FooterText(preset.second)
                }
            }
            FooterText("影响反问、汇总和洞察的说话风格,不影响解析结果;默认为无个性。")

            SectionHeader(stringResource(R.string.android_ui_completion_insight))
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stringResource(R.string.android_ui_completion_insight),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = settings.insightEnabled, onCheckedChange = vm::setInsightEnabled)
            }
            FooterText("每周在已完成页生成一句正向回顾,不会推送通知。")


            SectionHeader(stringResource(R.string.shared_ai_memory))
            Text(
                "编辑记忆",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable {
                        vm.reloadMemory()
                        showMemoryEditor = true
                    }
                    .padding(vertical = 12.dp),
            )
            Text(stringResource(R.string.shared_reset_memory),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { confirmMemoryReset = true }
                    .padding(vertical = 12.dp),
            )
            FooterText("AI 会在事项完成后归纳\"类型 → 典型时长\",新建没说时长的事项时据此建议。")

            // Android 12/12L 上精确闹钟权限可被用户关闭,提供跳转入口
            if (Build.VERSION.SDK_INT in 31..32) {
                val alarmManager = context.getSystemService(AlarmManager::class.java)
                if (!alarmManager.canScheduleExactAlarms()) {
                    SectionHeader("权限")
                    Text(
                        "开启「闹钟和提醒」权限",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable {
                                context.startActivity(
                                    Intent(SystemSettings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM)
                                )
                            }
                            .padding(vertical = 12.dp),
                    )
                    FooterText("未开启时提醒可能延迟最多 10 分钟。")
                }
            }

            Spacer(Modifier.height(32.dp))
        }
    }

    if (showAllDayPicker) {
        LodoTimePickerDialog(
            initial = TimeFormat.localTime(settings.allDayTime),
            onConfirm = {
                vm.setAllDayTime(TimeFormat.hhmm(it))
                showAllDayPicker = false
            },
            onDismiss = { showAllDayPicker = false },
        )
    }
    editingDigestIndex?.let { index ->
        LodoTimePickerDialog(
            initial = TimeFormat.localTime(settings.digestTimes.getOrNull(index) ?: "09:00"),
            onConfirm = { picked ->
                vm.setDigestTimes(
                    settings.digestTimes.mapIndexed { j, old ->
                        if (j == index) TimeFormat.hhmm(picked) else old
                    }
                )
                editingDigestIndex = null
            },
            onDismiss = { editingDigestIndex = null },
        )
    }

    if (showMemoryEditor) {
        AlertDialog(
            onDismissRequest = { showMemoryEditor = false },
            title = { Text(stringResource(R.string.shared_ai_memory)) },
            text = {
                OutlinedTextField(
                    value = vm.memoryText,
                    onValueChange = { vm.memoryText = it },
                    placeholder = { Text(stringResource(R.string.shared_no_memory_yet_the_ai_fills_this_in)) },
                    minLines = 6,
                    maxLines = 12,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    vm.saveMemory()
                    showMemoryEditor = false
                }) { Text("保存") }
            },
            dismissButton = {
                TextButton(onClick = { showMemoryEditor = false }) { Text(stringResource(R.string.shared_cancel)) }
            },
        )
    }

    if (confirmMemoryReset) {
        AlertDialog(
            onDismissRequest = { confirmMemoryReset = false },
            title = { Text("确定清空 AI 记忆吗?") },
            confirmButton = {
                TextButton(onClick = {
                    vm.resetMemory()
                    confirmMemoryReset = false
                }) { Text(stringResource(R.string.shared_reset_memory)) }
            },
            dismissButton = {
                TextButton(onClick = { confirmMemoryReset = false }) { Text(stringResource(R.string.shared_cancel)) }
            },
        )
    }
}

/** 标签 + 可点时间值的行。 */
@Composable
private fun TimeRow(label: String, hhmm: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Text(hhmm, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
    }
}
