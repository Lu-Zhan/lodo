package com.lodo.app.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.DragHandle
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.lodo.app.core.SidebarLayout
import com.lodo.app.ui.AppSection
import com.lodo.app.ui.FooterText
import com.lodo.app.ui.L
import com.lodo.app.ui.LodoSubPage

/** 本地预览立即响应拖动,松手/取消拖动时保存;开关立即保存。 */
@Composable
fun SidebarSettingsScreen(
    initialLayout: String,
    onLayoutChange: (SidebarLayout) -> Unit,
    onBack: () -> Unit,
) {
    var layout by remember {
        mutableStateOf(SidebarLayout.decode(initialLayout, AppSection.entries.map { it.name }))
    }
    val listState = rememberLazyListState()
    var draggedId by remember { mutableStateOf<String?>(null) }
    var draggedTop by remember { mutableFloatStateOf(0f) }
    var draggedHeight by remember { mutableFloatStateOf(0f) }
    val edge = with(LocalDensity.current) { 56.dp.toPx() }
    val maxScrollPerFrame = with(LocalDensity.current) { 12.dp.toPx() }

    fun moveAtDragPosition() {
        val id = draggedId ?: return
        val info = listState.layoutInfo
        val current = info.visibleItemsInfo.firstOrNull { it.key == id } ?: return
        // 等待 LazyColumn 完成上次换位的布局,避免同一帧用旧位置换回去。
        if (current.index != layout.items.indexOfFirst { it.id == id }) return
        val center = (draggedTop + draggedHeight / 2).coerceIn(
            info.viewportStartOffset.toFloat(), (info.viewportEndOffset - 1).coerceAtLeast(info.viewportStartOffset).toFloat(),
        )
        val target = info.visibleItemsInfo.firstOrNull { center >= it.offset && center < it.offset + it.size }
        if (target != null && target.key != id) layout = layout.move(id, target.key as String)
    }

    fun finishDrag() {
        if (draggedId != null) onLayoutChange(layout)
        draggedId = null
    }

    // 手指停在列表边缘也持续滚动,矮屏下能把首项拖到末尾。
    LaunchedEffect(draggedId) {
        if (draggedId == null) return@LaunchedEffect
        var previousFrame = withFrameNanos { it }
        while (draggedId != null) {
            val frame = withFrameNanos { it }
            val frameScale = ((frame - previousFrame) / 16_666_667f).coerceIn(0f, 3f)
            previousFrame = frame
            val info = listState.layoutInfo
            val center = draggedTop + draggedHeight / 2
            val scroll = when {
                center < info.viewportStartOffset + edge ->
                    -((info.viewportStartOffset + edge - center) / edge).coerceIn(0f, 1f)
                center > info.viewportEndOffset - edge ->
                    ((center - info.viewportEndOffset + edge) / edge).coerceIn(0f, 1f)
                else -> 0f
            }
            if (scroll != 0f) listState.scrollBy(scroll * maxScrollPerFrame * frameScale)
            moveAtDragPosition()
        }
    }

    LodoSubPage(L("侧边栏", "Sidebar"), onBack = onBack) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).padding(horizontal = 16.dp)) {
            FooterText(L("开关控制显示,长按拖动排序。设置始终显示。", "Toggle visibility; long-press to reorder. Settings always stays visible."))
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize().pointerInput(listState) {
                    detectDragGesturesAfterLongPress(
                        onDragStart = { position ->
                            listState.layoutInfo.visibleItemsInfo.firstOrNull {
                                position.y >= it.offset && position.y < it.offset + it.size
                            }?.let {
                                draggedId = it.key as String
                                draggedTop = it.offset.toFloat()
                                draggedHeight = it.size.toFloat()
                            }
                        },
                        onDrag = { change, amount ->
                            if (draggedId != null) {
                                change.consume()
                                draggedTop += amount.y
                                moveAtDragPosition()
                            }
                        },
                        onDragEnd = ::finishDrag,
                        onDragCancel = ::finishDrag,
                    )
                },
            ) {
                items(layout.items, key = { it.id }) { item ->
                    val section = AppSection.valueOf(item.id)
                    val dragging = draggedId == item.id
                    val index = layout.items.indexOf(item)
                    Row(
                        Modifier
                            .animateItem(placementSpec = if (dragging) null else androidx.compose.animation.core.spring())
                            .zIndex(if (dragging) 1f else 0f)
                            .graphicsLayer {
                                translationY = if (dragging) {
                                    val offset = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == item.id }?.offset ?: 0
                                    draggedTop - offset
                                } else 0f
                                shadowElevation = if (dragging) 4.dp.toPx() else 0f
                            }
                            .background(if (dragging) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surface)
                            .fillMaxWidth().height(64.dp)
                            .semantics {
                                // TalkBack 无需拖动也能排序。
                                customActions = buildList {
                                    if (index > 0) add(CustomAccessibilityAction(L("上移", "Move up")) {
                                        layout = layout.move(item.id, layout.items[index - 1].id)
                                        onLayoutChange(layout)
                                        true
                                    })
                                    if (index < layout.items.lastIndex) add(CustomAccessibilityAction(L("下移", "Move down")) {
                                        layout = layout.move(item.id, layout.items[index + 1].id)
                                        onLayoutChange(layout)
                                        true
                                    })
                                }
                            }
                            .padding(horizontal = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Icon(section.icon, contentDescription = null, modifier = Modifier.size(24.dp))
                        Text(section.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1,
                            overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                        Switch(item.visible, onCheckedChange = { visible ->
                            layout = layout.setVisible(item.id, visible)
                            onLayoutChange(layout)
                        }, modifier = Modifier.semantics { contentDescription = section.title })
                        Icon(Icons.Outlined.DragHandle, contentDescription = L("长按拖动排序", "Long-press to reorder"))
                    }
                }
            }
        }
    }
}
