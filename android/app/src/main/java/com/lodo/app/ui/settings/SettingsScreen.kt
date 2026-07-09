package com.lodo.app.ui.settings

import android.app.AlarmManager
import android.content.Intent
import android.os.Build
import android.provider.Settings as SystemSettings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
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
import com.lodo.app.ui.FooterText
import com.lodo.app.ui.LodoTimePickerDialog
import com.lodo.app.ui.SectionHeader
import com.lodo.app.ui.StepperRow

/** 设置标签页,分节与文案对应 iOS SettingsView(钥匙串改为本机加密存储)。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(modifier: Modifier = Modifier, vm: SettingsViewModel = viewModel()) {
    val settings by vm.settings.collectAsStateWithLifecycle()
    val context = LocalContext.current

    var showAllDayPicker by remember { mutableStateOf(false) }
    var showDigestPicker by remember { mutableStateOf(false) }

    Scaffold(
        modifier = modifier,
        topBar = { TopAppBar(title = { Text("设置") }) },
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
            FooterText("稍等或忽略提醒后,间隔多久再次提醒,直到完成。")

            SectionHeader("全天事项")
            TimeRow("全天事项提醒时间", settings.allDayTime) { showAllDayPicker = true }
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
                TimeRow("汇总提醒时间", settings.digestTime) { showDigestPicker = true }
            }
            FooterText("每天固定时间提醒当前未完成的事项数量。")

            SectionHeader("AI(DeepSeek)")
            OutlinedTextField(
                value = vm.apiKey,
                onValueChange = vm::onApiKeyChange,
                placeholder = { Text("DeepSeek API Key(sk-…)") },
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = vm::saveApiKey,
                enabled = !vm.keySaved,
                modifier = Modifier.padding(top = 8.dp),
            ) {
                Text(if (vm.keySaved) "已保存" else "保存 API Key")
            }
            FooterText("用于自然语言创建和编辑事项,加密存储在本机。")

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
    if (showDigestPicker) {
        LodoTimePickerDialog(
            initial = TimeFormat.localTime(settings.digestTime),
            onConfirm = {
                vm.setDigestTime(TimeFormat.hhmm(it))
                showDigestPicker = false
            },
            onDismiss = { showDigestPicker = false },
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
