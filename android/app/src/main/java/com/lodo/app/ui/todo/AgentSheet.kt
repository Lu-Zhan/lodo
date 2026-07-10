package com.lodo.app.ui.todo

import android.speech.RecognizerIntent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
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
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircleOutline
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.lodo.app.ui.FooterText
import kotlinx.coroutines.launch

/**
 * 全局 agent,对应 iOS AgentView:大对话框,一句话新增/修改/完成/删除待办(可批量);
 * 右下角语音按钮,讲完话自动提交;批量或含完成/删除的操作先在本页确认;
 * 信息不全时反问并给候选。
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun AgentSheet(
    prefill: String?,
    onSubmit: suspend (String) -> AgentReply,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    var text by remember { mutableStateOf(prefill ?: "") }
    var busy by remember { mutableStateOf(false) }
    var errorText by remember { mutableStateOf<String?>(null) }
    var confirmLines by remember { mutableStateOf<List<String>?>(null) }
    var clarify by remember { mutableStateOf<Pair<String, List<String>>?>(null) }
    /** 反问时保留的原话,选候选后拼接重新提交。 */
    var clarifyBase by remember { mutableStateOf("") }
    val scope = rememberCoroutineScope()

    fun parse(override: String? = null) {
        val trimmed = (override ?: text).trim()
        if (trimmed.isEmpty() || busy) return
        scope.launch {
            busy = true
            errorText = null
            confirmLines = null
            try {
                when (val reply = onSubmit(trimmed)) {
                    AgentReply.Routed -> {}
                    is AgentReply.Confirm -> {
                        clarify = null
                        confirmLines = reply.lines
                    }
                    is AgentReply.Clarify -> {
                        clarifyBase = trimmed
                        clarify = reply.question to reply.options
                    }
                }
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
                // 讲完话自动提交
                parse()
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
                    "AI 助手",
                    style = MaterialTheme.typography.titleMedium,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f),
                )
                if (busy) {
                    CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                } else {
                    IconButton(onClick = { parse() }, enabled = text.isNotBlank()) {
                        Icon(Icons.Filled.AutoAwesome, contentDescription = "解析")
                    }
                }
            }

            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("例如:明天3点开会一小时 / 把开会改到晚上8点") },
                minLines = 3,
                maxLines = 8,
            )
            errorText?.let {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }

            clarify?.let { (question, options) ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(top = 12.dp),
                ) {
                    Icon(
                        Icons.Filled.HelpOutline,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(question, style = MaterialTheme.typography.bodyMedium)
                }
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.padding(top = 8.dp),
                ) {
                    options.forEach { option ->
                        OutlinedButton(onClick = {
                            val base = clarifyBase.ifBlank { text }
                            clarify = null
                            parse("$base\n补充:$option")
                        }) { Text(option) }
                    }
                }
            }

            confirmLines?.let { lines ->
                Card(modifier = Modifier.fillMaxWidth().padding(top = 12.dp)) {
                    Column(
                        modifier = Modifier.padding(12.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        lines.forEach { line ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    iconFor(line),
                                    contentDescription = null,
                                    modifier = Modifier.size(18.dp),
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(line, style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { confirmLines = null }) { Text("取消") }
                            Button(onClick = onConfirm) {
                                Icon(Icons.Filled.Check, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(4.dp))
                                Text("确认执行")
                            }
                        }
                    }
                }
            }

            FooterText("一句话新增/修改/完成/删除待办,可一次说多件事;输入内容和当前待办列表会发送给 DeepSeek 解析。")

            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp)) {
                Spacer(Modifier.weight(1f))
                // 右下角:语音输入,讲完自动提交
                FloatingActionButton(onClick = {
                    runCatching { speechLauncher.launch(speechIntent()) }
                        .onFailure { errorText = "设备不支持语音输入" }
                }) {
                    Icon(Icons.Filled.Mic, contentDescription = "语音输入")
                }
            }

            Spacer(Modifier.height(8.dp))
        }
    }
}

private fun iconFor(line: String): ImageVector = when {
    line.startsWith("新建") -> Icons.Filled.AddCircleOutline
    line.startsWith("修改") -> Icons.Filled.EditNote
    line.startsWith("完成") -> Icons.Filled.CheckCircleOutline
    line.startsWith("删除") -> Icons.Filled.DeleteOutline
    else -> Icons.Filled.AutoAwesome
}
