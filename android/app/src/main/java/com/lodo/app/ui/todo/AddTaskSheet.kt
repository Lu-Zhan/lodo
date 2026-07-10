package com.lodo.app.ui.todo

import android.content.Intent
import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.lodo.app.ai.ParsedTask
import com.lodo.app.ui.FooterText
import com.lodo.app.ui.SectionHeader
import kotlinx.coroutines.launch

/** 系统语音识别(zh-CN)启动 Intent。 */
internal fun speechIntent(): Intent =
    Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
        .putExtra(
            RecognizerIntent.EXTRA_LANGUAGE_MODEL,
            RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
        )
        .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")

/**
 * 快速添加页,对应 iOS AddTaskView:纵向两个模块——
 * 上方 AI 输入(自然语言 + 语音),解析结果直接回填下方手动输入表单;
 * 没说时长时按记忆文件建议时长,并以颜色 + 图标标注 AI 建议。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddTaskSheet(
    allDayTime: String,
    onAiParse: suspend (String) -> Pair<ParsedTask, Int?>,
    onSave: (ParsedTask) -> Unit,
    onDismiss: () -> Unit,
) {
    val form = rememberTaskFormState(null)
    var text by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var aiFilled by remember { mutableStateOf(false) }
    /** AI 按记忆建议的时长值;用户手动改动后清除高亮。 */
    var suggestedDuration by remember { mutableStateOf<Int?>(null) }
    val scope = rememberCoroutineScope()

    fun parse() {
        val trimmed = text.trim()
        if (trimmed.isEmpty() || busy) return
        scope.launch {
            busy = true
            errorText = null
            try {
                val (parsed, suggested) = onAiParse(trimmed)
                form.apply(parsed)
                aiFilled = true
                suggestedDuration = suggested
                text = ""
            } catch (e: Exception) {
                errorText = e.message
            } finally {
                busy = false
            }
        }
    }

    val speechLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        result.data?.getStringArrayListExtra(RecognizerIntent.EXTRA_RESULTS)
            ?.firstOrNull()?.takeIf { it.isNotBlank() }?.let { spoken ->
                text = if (text.isBlank()) spoken else text + spoken
            }
    }

    fun save() {
        val result = form.makeParsed(allDayTime)
        if (result == null) {
            errorText = "请补全事项内容和时间设置"
            return
        }
        onSave(result)
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .navigationBarsPadding()
                .imePadding(),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = onDismiss) { Text("取消") }
                Text(
                    "添加",
                    style = MaterialTheme.typography.titleMedium,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = ::save, enabled = form.isValid) { Text("保存") }
            }

            SectionHeader("AI 助手")
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("例如:明天3点开会一小时") },
                trailingIcon = {
                    Row {
                        IconButton(onClick = {
                            runCatching { speechLauncher.launch(speechIntent()) }
                                .onFailure { errorText = "设备不支持语音输入" }
                        }, enabled = !busy) {
                            Icon(Icons.Filled.Mic, contentDescription = "语音输入")
                        }
                        if (busy) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(24.dp).padding(top = 12.dp),
                                strokeWidth = 2.dp,
                            )
                        } else {
                            IconButton(onClick = ::parse, enabled = text.isNotBlank()) {
                                Icon(Icons.Filled.AutoAwesome, contentDescription = "解析")
                            }
                        }
                    }
                },
            )
            FooterText("一句话描述事项,解析结果会填入下方表单;没说时长时 AI 会按历史记忆建议。")
            errorText?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }

            TaskFormFields(
                state = form,
                allDayTime = allDayTime,
                header = "手动输入",
                aiFilled = aiFilled,
                suggestedDuration = suggestedDuration != null &&
                    form.duration == suggestedDuration,
            )

            Spacer(Modifier.height(24.dp))
        }
    }
}
