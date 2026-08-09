package com.lodo.app.ui.memory

import com.lodo.app.R
import androidx.compose.ui.res.stringResource
import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import com.lodo.app.core.ContactGraphLayout
import com.lodo.app.data.ContactRelationshipEntity
import com.lodo.app.data.MemoryEntity
import kotlin.math.hypot

/**
 * 人脉关系图谱,对应 iOS ContactGraphView——这是仓库里明确认可的自绘 UI 例外
 * (CLAUDE.md:"人脉之间的关系图谱可视化…是唯一经用户明确确认的例外"的 Android
 * 对应实现),用 Compose Canvas 画节点连线,确定性圆形布局(ContactGraphLayout,
 * 不做力导向仿真)。点两个节点新建关系,关系列表另起一行管理(删除靠列表而不是
 * 在图上做连线命中检测,更可靠)。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContactGraphScreen(
    contacts: List<MemoryEntity>,
    relationships: List<ContactRelationshipEntity>,
    onAddRelationship: (fromUuid: String, toUuid: String, label: String) -> Unit,
    onDeleteRelationship: (String) -> Unit,
    onBack: () -> Unit,
) {
    var firstSelected by remember { mutableStateOf<String?>(null) }
    var pendingPair by remember { mutableStateOf<Pair<String, String>?>(null) }

    val positions = remember(contacts.map { it.uuid }) {
        ContactGraphLayout.circlePositions(contacts.size, radius = 1.0)
    }
    val nameByUuid = remember(contacts) { contacts.associate { it.uuid to it.title } }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.android_ui_contact_graph)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.android_ui_back))
                    }
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            if (contacts.size < 2) {
                Text(
                    stringResource(R.string.android_ui_need_two_contacts),
                    modifier = Modifier.padding(16.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                val nodeColor = MaterialTheme.colorScheme.primary
                val selectedColor = MaterialTheme.colorScheme.error
                val edgeColor = MaterialTheme.colorScheme.outlineVariant
                val labelColorArgb = MaterialTheme.colorScheme.onSurface.toArgb()
                Canvas(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(320.dp)
                        .pointerInput(contacts.map { it.uuid }) {
                            detectTapGestures { tapOffset ->
                                val center = Offset(size.width / 2f, size.height / 2f)
                                val scale = minOf(size.width, size.height) / 2.5f
                                val hitIndex = positions.indices.minByOrNull { i ->
                                    val (x, y) = positions[i]
                                    val nodeCenter = center + Offset((x * scale).toFloat(), (y * scale).toFloat())
                                    hypot((tapOffset.x - nodeCenter.x).toDouble(), (tapOffset.y - nodeCenter.y).toDouble())
                                }?.takeIf { i ->
                                    val (x, y) = positions[i]
                                    val nodeCenter = center + Offset((x * scale).toFloat(), (y * scale).toFloat())
                                    hypot((tapOffset.x - nodeCenter.x).toDouble(), (tapOffset.y - nodeCenter.y).toDouble()) < 60.0
                                } ?: return@detectTapGestures
                                val tappedUuid = contacts[hitIndex].uuid
                                val first = firstSelected
                                if (first == null) {
                                    firstSelected = tappedUuid
                                } else if (first == tappedUuid) {
                                    firstSelected = null
                                } else {
                                    pendingPair = first to tappedUuid
                                    firstSelected = null
                                }
                            }
                        },
                ) {
                    val center = Offset(size.width / 2f, size.height / 2f)
                    val scale = minOf(size.width, size.height) / 2.5f
                    fun nodeCenter(index: Int): Offset {
                        val (x, y) = positions[index]
                        return center + Offset((x * scale).toFloat(), (y * scale).toFloat())
                    }
                    relationships.forEach { rel ->
                        val fromIndex = contacts.indexOfFirst { it.uuid == rel.fromUuid }
                        val toIndex = contacts.indexOfFirst { it.uuid == rel.toUuid }
                        if (fromIndex >= 0 && toIndex >= 0) {
                            drawLine(edgeColor, nodeCenter(fromIndex), nodeCenter(toIndex), strokeWidth = 3f)
                        }
                    }
                    contacts.forEachIndexed { i, contact ->
                        val p = nodeCenter(i)
                        drawCircle(
                            color = if (contact.uuid == firstSelected) selectedColor else nodeColor,
                            radius = 28f, center = p,
                        )
                        drawContext.canvas.nativeCanvas.drawText(
                            contact.title.take(6), p.x, p.y + 45f,
                            Paint().apply { color = labelColorArgb; textSize = 32f; textAlign = Paint.Align.CENTER },
                        )
                    }
                }
                Text(
                    stringResource(R.string.android_ui_tap_two_contacts_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }

            HorizontalDivider(modifier = Modifier.padding(vertical = 12.dp))

            if (relationships.isEmpty()) {
                Text(
                    stringResource(R.string.android_ui_no_relationships_yet),
                    modifier = Modifier.padding(16.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
                    items(relationships, key = { it.uuid }) { rel ->
                        ListItem(
                            headlineContent = {
                                Text("${nameByUuid[rel.fromUuid] ?: "?"} ↔ ${nameByUuid[rel.toUuid] ?: "?"}")
                            },
                            supportingContent = { Text(rel.label) },
                            trailingContent = {
                                IconButton(onClick = { onDeleteRelationship(rel.uuid) }) {
                                    Icon(Icons.Filled.Close, contentDescription = stringResource(R.string.shared_cancel))
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    pendingPair?.let { (fromUuid, toUuid) ->
        var label by remember(fromUuid, toUuid) { mutableStateOf("") }
        val defaultLabel = stringResource(R.string.android_ui_relationship_default_label)
        AlertDialog(
            onDismissRequest = { pendingPair = null },
            title = { Text("${nameByUuid[fromUuid]} ↔ ${nameByUuid[toUuid]}") },
            text = {
                OutlinedTextField(
                    value = label, onValueChange = { label = it },
                    placeholder = { Text(stringResource(R.string.android_ui_relationship_label_placeholder)) },
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        onAddRelationship(fromUuid, toUuid, label.trim().ifBlank { defaultLabel })
                        pendingPair = null
                    },
                ) { Text(stringResource(R.string.android_ui_save)) }
            },
            dismissButton = { TextButton(onClick = { pendingPair = null }) { Text(stringResource(R.string.shared_cancel)) } },
        )
    }
}
