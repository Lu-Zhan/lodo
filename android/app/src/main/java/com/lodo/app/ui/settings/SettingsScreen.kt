package com.lodo.app.ui.settings

import com.lodo.app.R
import androidx.compose.ui.res.stringResource
import android.app.AlarmManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings as SystemSettings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.core.Lang
import com.lodo.app.core.Strings
import com.lodo.app.core.TimeFormat
import com.lodo.app.data.aiProviderPresets
import com.lodo.app.data.personaPresets
import com.lodo.app.ui.FooterText
import com.lodo.app.ui.LodoTimePickerDialog
import com.lodo.app.ui.SectionHeader
import com.lodo.app.ui.StepperRow
import com.lodo.app.ui.localizedWeekdayChipLabel
import com.lodo.app.ui.routine.RoutineListScreen

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
    var showQuietStartPicker by remember { mutableStateOf(false) }
    var showQuietEndPicker by remember { mutableStateOf(false) }
    var editingDigestIndex by remember { mutableStateOf<Int?>(null) }
    var showMemoryEditor by remember { mutableStateOf(false) }
    var confirmMemoryReset by remember { mutableStateOf(false) }
    var showRoutines by remember { mutableStateOf(false) }

    if (showRoutines) {
        RoutineListScreen(onBack = { showRoutines = false })
        return
    }

    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/zip")
    ) { uri: Uri? -> uri?.let { vm.exportBackup(it) } }
    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? -> uri?.let { vm.importBackup(it) } }

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
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(R.string.android_ui_repeat_reminder),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Switch(
                    checked = settings.repeatReminderEnabled,
                    onCheckedChange = vm::setRepeatReminderEnabled,
                )
            }
            // 关掉反复提醒也不 disable 稍等间隔:用户主动点「稍等」用的就是它。
            StepperRow(
                label = stringResource(R.string.android_ui_snooze_interval_0_min, settings.snoozeMinutes),
                onDecrement = { vm.setSnoozeMinutes(settings.snoozeMinutes - 5) },
                onIncrement = { vm.setSnoozeMinutes(settings.snoozeMinutes + 5) },
            )
            TimeRow(stringResource(R.string.android_ui_all_day_reminder_time), settings.allDayTime) { showAllDayPicker = true }
            FooterText(stringResource(R.string.android_ui_repeat_reminder_footer))
            FooterText(stringResource(R.string.android_ui_repeat_reminder_off_footer))
            FooterText(stringResource(R.string.android_ui_date_only_reminder_hint))

            SectionHeader(stringResource(R.string.android_ui_quiet_hours))
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(R.string.android_ui_quiet_hours),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = settings.quietHoursEnabled, onCheckedChange = vm::setQuietHoursEnabled)
            }
            if (settings.quietHoursEnabled) {
                TimeRow(
                    stringResource(R.string.android_ui_quiet_hours_start), settings.quietHoursStart,
                ) { showQuietStartPicker = true }
                TimeRow(
                    stringResource(R.string.android_ui_quiet_hours_end), settings.quietHoursEnd,
                ) { showQuietEndPicker = true }
            }
            FooterText(stringResource(R.string.android_ui_quiet_hours_footer))

            SectionHeader(stringResource(R.string.android_ui_daily_digest))
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    stringResource(R.string.android_ui_daily_task_summary),
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = settings.digestEnabled, onCheckedChange = vm::setDigestEnabled)
            }
            if (settings.digestEnabled) {
                SingleChoiceSegmentedButtonRow(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                ) {
                    listOf(
                        "daily" to stringResource(R.string.shared_daily),
                        "weekly" to stringResource(R.string.shared_weekly),
                    ).forEachIndexed { index, (type, label) ->
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
                                label = { Text(localizedWeekdayChipLabel(i)) },
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
                            Text(stringResource(R.string.android_ui_time_0, i + 1), style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
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
            FooterText(stringResource(R.string.android_ui_scheduled_reminder_footer))

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
            FooterText(stringResource(R.string.android_ui_haptic_footer))

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
            FooterText(stringResource(R.string.android_ui_auto_voice_input_footer))
            StepperRow(
                label = stringResource(
                    R.string.android_ui_auto_stop_after_silence_0_s, settings.agentSilenceTimeoutSeconds),
                onDecrement = {
                    vm.setAgentSilenceTimeoutSeconds(settings.agentSilenceTimeoutSeconds - 1)
                },
                onIncrement = {
                    vm.setAgentSilenceTimeoutSeconds(settings.agentSilenceTimeoutSeconds + 1)
                },
            )
            FooterText(stringResource(R.string.android_ui_voice_silence_timeout_hint))

            // ---- AI:服务 → 个性 → 洞察 → 记忆 ----
            SectionHeader(stringResource(R.string.shared_ai_service))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                (aiProviderPresets.map { it.name } + "自定义").forEach { name ->
                    FilterChip(
                        selected = settings.aiProvider == name,
                        onClick = { vm.setAiProvider(name) },
                        label = { Text(localizedProviderName(name)) },
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
                        if (settings.aiProvider == "自定义") stringResource(R.string.android_ui_model_name)
                        else stringResource(
                            R.string.android_ui_model_default_0,
                            aiProviderPresets.firstOrNull { it.name == settings.aiProvider }?.model.orEmpty(),
                        )
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
                Text(
                    if (vm.keySaved) stringResource(R.string.android_ui_saved)
                    else stringResource(R.string.android_ui_save_api_key),
                )
            }
            FooterText(stringResource(R.string.android_ui_ai_provider_storage_footer))

            SectionHeader(stringResource(R.string.android_ui_on_device_ai))
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    when (vm.geminiNanoAvailable) {
                        null -> stringResource(R.string.android_ui_tap_to_check_availability)
                        true -> stringResource(R.string.android_ui_available)
                        false -> stringResource(R.string.android_ui_not_available_on_this_device)
                    },
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                if (vm.geminiNanoChecking) {
                    CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                } else {
                    TextButton(onClick = { vm.checkGeminiNanoAvailability() }) {
                        Text(stringResource(R.string.android_ui_check))
                    }
                }
            }
            FooterText(stringResource(R.string.android_ui_on_device_ai_footer))

            SectionHeader(stringResource(R.string.shared_ai_thinking))
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                listOf(
                    "off" to stringResource(R.string.android_ui_thinking_off),
                    "low" to stringResource(R.string.android_ui_thinking_low),
                    "medium" to stringResource(R.string.android_ui_thinking_medium),
                    "high" to stringResource(R.string.android_ui_thinking_high),
                )
                    .forEachIndexed { index, (level, label) ->
                        SegmentedButton(
                            selected = settings.thinkingLevel == level,
                            onClick = { vm.setThinkingLevel(level) },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = 4),
                        ) { Text(label) }
                    }
            }
            FooterText(stringResource(R.string.android_ui_thinking_footer))

            SectionHeader(stringResource(R.string.shared_web_search))
            OutlinedTextField(
                value = vm.tavilyKey,
                onValueChange = vm::onTavilyKeyChange,
                placeholder = { Text(stringResource(R.string.android_ui_tavily_api_key)) },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = vm::saveTavilyKey,
                enabled = !vm.tavilyKeySaved,
                modifier = Modifier.padding(top = 8.dp),
            ) {
                Text(
                    if (vm.tavilyKeySaved) stringResource(R.string.android_ui_saved)
                    else stringResource(R.string.android_ui_save),
                )
            }
            FooterText(stringResource(R.string.android_ui_tavily_setup_footer))

            SectionHeader(stringResource(R.string.shared_ai_personality))
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                (listOf("默认") + personaPresets.map { it.first } + "自定义").forEach { name ->
                    FilterChip(
                        selected = settings.personaStyle == name,
                        onClick = { vm.setPersonaStyle(name) },
                        label = { Text(localizedPersonaName(name)) },
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
                    FooterText(localizedPersonaDescription(preset.second))
                }
            }
            FooterText(stringResource(R.string.android_ui_persona_footer))

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
            FooterText(stringResource(R.string.android_ui_completion_insight_footer))


            SectionHeader(stringResource(R.string.shared_ai_memory))
            Text(
                stringResource(R.string.android_ui_edit_ai_memory),
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
            FooterText(stringResource(R.string.android_ui_duration_memory_footer))

            SectionHeader(stringResource(R.string.android_ui_backup))
            Text(
                stringResource(R.string.android_ui_export_backup),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(enabled = !vm.backupBusy) {
                        exportLauncher.launch("lodo-backup-${System.currentTimeMillis()}.zip")
                    }
                    .padding(vertical = 12.dp),
            )
            Text(
                stringResource(R.string.android_ui_import_backup),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(enabled = !vm.backupBusy) { importLauncher.launch(arrayOf("application/zip", "application/octet-stream")) }
                    .padding(vertical = 12.dp),
            )
            vm.backupMessage?.let { FooterText(it) }
            FooterText(stringResource(R.string.android_ui_backup_footer))

            SectionHeader(stringResource(R.string.android_ui_routine))
            Text(
                stringResource(R.string.android_ui_manage_routines),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { showRoutines = true }
                    .padding(vertical = 12.dp),
            )
            FooterText(stringResource(R.string.android_ui_routine_footer))

            // Android 12/12L 上精确闹钟权限可被用户关闭,提供跳转入口
            if (Build.VERSION.SDK_INT in 31..32) {
                val alarmManager = context.getSystemService(AlarmManager::class.java)
                if (!alarmManager.canScheduleExactAlarms()) {
                    SectionHeader(stringResource(R.string.android_ui_permissions))
                    Text(
                        stringResource(R.string.android_ui_enable_alarm_permission),
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
                    FooterText(stringResource(R.string.android_ui_alarm_permission_delay))
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
    if (showQuietStartPicker) {
        LodoTimePickerDialog(
            initial = TimeFormat.localTime(settings.quietHoursStart),
            onConfirm = {
                vm.setQuietHoursStart(TimeFormat.hhmm(it))
                showQuietStartPicker = false
            },
            onDismiss = { showQuietStartPicker = false },
        )
    }
    if (showQuietEndPicker) {
        LodoTimePickerDialog(
            initial = TimeFormat.localTime(settings.quietHoursEnd),
            onConfirm = {
                vm.setQuietHoursEnd(TimeFormat.hhmm(it))
                showQuietEndPicker = false
            },
            onDismiss = { showQuietEndPicker = false },
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
                }) { Text(stringResource(R.string.android_ui_save)) }
            },
            dismissButton = {
                TextButton(onClick = { showMemoryEditor = false }) { Text(stringResource(R.string.shared_cancel)) }
            },
        )
    }

    if (confirmMemoryReset) {
        AlertDialog(
            onDismissRequest = { confirmMemoryReset = false },
            title = { Text(stringResource(R.string.android_ui_clear_ai_memory_question)) },
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

@Composable
private fun localizedProviderName(name: String): String = when (name) {
    "通义千问" -> stringResource(R.string.shared_tongyi_qianwen)
    "智谱" -> stringResource(R.string.shared_zhipu)
    "自定义" -> stringResource(R.string.shared_custom)
    else -> name
}

@Composable
private fun localizedPersonaName(name: String): String = when (name) {
    "默认" -> stringResource(R.string.shared_default)
    "高效秘书" -> stringResource(R.string.shared_efficient_secretary)
    "温柔陪伴" -> stringResource(R.string.shared_gentle_companion)
    "严格教练" -> stringResource(R.string.shared_strict_coach)
    "幽默轻松" -> stringResource(R.string.shared_playful_witty)
    "自定义" -> stringResource(R.string.shared_custom)
    else -> name
}

@Composable
private fun localizedPersonaDescription(text: String): String {
    val language = if (LocalConfiguration.current.locales[0].language == "en") Lang.EN else Lang.ZH
    return Strings.translate(text, language)
}
