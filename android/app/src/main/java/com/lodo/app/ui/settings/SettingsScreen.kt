package com.lodo.app.ui.settings

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
                title = { Text("设置") },
                navigationIcon = {
                    onBack?.let {
                        IconButton(onClick = it) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
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
            SectionHeader("提醒")
            StepperRow(
                label = "稍等间隔:${settings.snoozeMinutes} 分钟",
                onDecrement = { vm.setSnoozeMinutes(settings.snoozeMinutes - 5) },
                onIncrement = { vm.setSnoozeMinutes(settings.snoozeMinutes + 5) },
            )
            TimeRow("全天事项提醒时间", settings.allDayTime) { showAllDayPicker = true }
            FooterText("稍等或忽略提醒后,间隔多久再次提醒,直到完成。")
            FooterText("只有日期、没有时间的事项,当天几点提醒。")

            SectionHeader("每日汇总")
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
                            Text("时间 ${i + 1}", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                            Text(hhmm, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                        }
                        IconButton(onClick = {
                            vm.setDigestTimes(settings.digestTimes.filterIndexed { j, _ -> j != i })
                        }) {
                            Icon(Icons.Filled.Close, contentDescription = "删除时间点")
                        }
                    }
                }
                TextButton(onClick = { vm.setDigestTimes(settings.digestTimes + "09:00") }) {
                    Icon(Icons.Filled.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("添加时间点")
                }
            }
            FooterText("在设定时间提醒今天开始或到期的事项。")

            SectionHeader("振动反馈")
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "振动反馈",
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = settings.hapticsEnabled, onCheckedChange = vm::setHapticsEnabled)
            }
            FooterText("滑动完成、删除等操作时轻微振动。")

            // ---- AI:服务 → 个性 → 洞察 → 记忆 ----
            SectionHeader("AI 服务")
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
                    placeholder = { Text("接口地址(…/chat/completions)") },
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

            SectionHeader("AI 个性")
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
                    placeholder = { Text("描述 AI 的说话风格,例如:像武侠小说里的师父") },
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

            SectionHeader("完成洞察")
            Row(
                modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "完成洞察",
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f),
                )
                Switch(checked = settings.insightEnabled, onCheckedChange = vm::setInsightEnabled)
            }
            FooterText("每周在已完成页生成一句正向回顾,不会推送通知。")


            SectionHeader("AI 记忆")
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
            Text(
                "重置记忆",
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
            title = { Text("AI 记忆") },
            text = {
                OutlinedTextField(
                    value = vm.memoryText,
                    onValueChange = { vm.memoryText = it },
                    placeholder = { Text("暂无记忆;AI 会在事项完成后自动归纳,也可以直接在这里手写。") },
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
                TextButton(onClick = { showMemoryEditor = false }) { Text("取消") }
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
                }) { Text("重置记忆") }
            },
            dismissButton = {
                TextButton(onClick = { confirmMemoryReset = false }) { Text("取消") }
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
