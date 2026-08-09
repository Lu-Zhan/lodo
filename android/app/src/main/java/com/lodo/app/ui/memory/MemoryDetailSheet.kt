package com.lodo.app.ui.memory

import com.lodo.app.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.lodo.app.core.TimeFormat
import com.lodo.app.data.MemoryEntity
import com.lodo.app.data.MemoryStatus

/** 收藏详情/编辑,对应 iOS MemoryDetailView 的核心子集:标题、标签可编辑,
 * 原文只读展示,整理失败可重试,支持删除。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun MemoryDetailSheet(
    item: MemoryEntity,
    allTags: List<String>,
    onSave: (title: String, tags: List<String>) -> Unit,
    onRetry: () -> Unit,
    onDelete: () -> Unit,
    onDismiss: () -> Unit,
) {
    var title by remember(item.uuid) { mutableStateOf(item.title) }
    var tagsText by remember(item.uuid) { mutableStateOf(item.tagsList.joinToString("、")) }

    fun commit() {
        val tags = tagsText.split("、", ",").map { it.trim() }.filter { it.isNotEmpty() }.distinct()
        onSave(title.trim(), tags)
    }

    ModalBottomSheet(
        onDismissRequest = { commit(); onDismiss() },
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                label = { Text(stringResource(R.string.android_ui_title)) },
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = tagsText,
                onValueChange = { tagsText = it },
                label = { Text(stringResource(R.string.android_ui_tags_separated_by)) },
                modifier = Modifier.fillMaxWidth(),
            )
            if (allTags.isNotEmpty()) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    allTags.forEach { tag ->
                        val selected = tagsText.split("、", ",").map { it.trim() }.contains(tag)
                        FilterChip(
                            selected = selected,
                            onClick = {
                                val current = tagsText.split("、", ",").map { it.trim() }.filter { it.isNotEmpty() }
                                tagsText = if (selected) (current - tag).joinToString("、")
                                else (current + tag).joinToString("、")
                            },
                            label = { Text(tag) },
                        )
                    }
                }
            }
            if (item.statusEnum == MemoryStatus.FAILED) {
                Text(
                    stringResource(R.string.android_ui_organize_failed_tap_to_retry),
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.padding(top = 4.dp),
                )
                TextButton(onClick = onRetry) { Text(stringResource(R.string.android_ui_retry)) }
            }
            if (item.urlString != null) {
                Text(
                    item.urlString,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            if (item.sourceText.isNotBlank()) {
                HorizontalDivider()
                Text(stringResource(R.string.android_ui_original_text), style = MaterialTheme.typography.titleSmall)
                Text(item.sourceText, style = MaterialTheme.typography.bodyMedium)
            }
            Text(
                TimeFormat.format(item.createdAt),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)) {
                OutlinedButton(onClick = { commit(); onDismiss() }, modifier = Modifier.weight(1f)) {
                    Text(stringResource(R.string.android_ui_save))
                }
            }
            TextButton(onClick = { onDelete(); onDismiss() }) {
                Text(
                    stringResource(R.string.android_ui_delete_this_memory),
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}
