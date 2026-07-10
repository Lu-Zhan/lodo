package com.lodo.app.ui.todo

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
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
import com.lodo.app.data.TaskEntity
import com.lodo.app.ui.SectionHeader
import kotlinx.coroutines.launch

/** 创建/编辑共用表单;编辑模式下支持 AI 自然语言指令修改。对应 iOS TaskEditView。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TaskEditSheet(
    existing: TaskEntity?,
    parsed: ParsedTask?,
    allDayTime: String,
    onAiEdit: suspend (ParsedTask, String) -> ParsedTask,
    onSave: (ParsedTask) -> Unit,
    onDismiss: () -> Unit,
) {
    val source: ParsedTask? = remember { parsed ?: existing?.toParsedTask() }
    val form = rememberTaskFormState(source)

    var aiInstruction by remember { mutableStateOf("") }
    var aiBusy by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    fun save() {
        val result = form.makeParsed(allDayTime)
        if (result == null) {
            errorText = "请补全事项内容和时间设置"
            return
        }
        onSave(result)
    }

    fun applyAi() {
        val instruction = aiInstruction.trim()
        val current = form.makeParsed(allDayTime)
        if (instruction.isEmpty() || aiBusy || current == null) return
        scope.launch {
            aiBusy = true
            errorText = null
            try {
                form.apply(onAiEdit(current, instruction))
                aiInstruction = ""
            } catch (e: Exception) {
                errorText = e.message
            } finally {
                aiBusy = false
            }
        }
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
                    if (existing == null) "新建事项" else "编辑事项",
                    style = MaterialTheme.typography.titleMedium,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = ::save, enabled = form.isValid) { Text("保存") }
            }

            TaskFormFields(state = form, allDayTime = allDayTime)

            if (existing != null) {
                SectionHeader("AI 修改")
                OutlinedTextField(
                    value = aiInstruction,
                    onValueChange = { aiInstruction = it },
                    placeholder = { Text("例如:改到明天晚上8点") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Button(
                    onClick = ::applyAi,
                    enabled = !aiBusy && aiInstruction.isNotBlank(),
                    modifier = Modifier.padding(top = 8.dp),
                ) {
                    if (aiBusy) {
                        CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Filled.AutoAwesome, contentDescription = null, modifier = Modifier.size(18.dp))
                    }
                    Spacer(Modifier.width(4.dp))
                    Text("应用修改")
                }
            }

            errorText?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 8.dp),
                )
            }

            Spacer(Modifier.height(24.dp))
        }
    }
}
