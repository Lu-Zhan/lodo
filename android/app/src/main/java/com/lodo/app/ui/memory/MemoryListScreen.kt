package com.lodo.app.ui.memory

import com.lodo.app.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.TextSnippet
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AttachMoney
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.outlined.Bookmarks
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.style.TextOverflow
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.contacts.ContactsBridge
import com.lodo.app.data.MemoryEntity
import com.lodo.app.data.MemoryKind
import com.lodo.app.data.MemoryStatus
import com.lodo.app.ui.EmptyState
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.Flight

/** "记忆"tab,对应 iOS MemoryListView:AI 整理后的收藏条目列表 + 资产/人脉
 * 子功能(打了保留标签的记忆条目,默认从列表隐藏,靠专门的筛选开关显示),
 * 顶部搜索框本地过滤 + 标签筛选。不含文件/图片收藏、头像/多文件附件(见
 * MemoryEntity 的注释)。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun MemoryListScreen(modifier: Modifier = Modifier, vm: MemoryViewModel = viewModel()) {
    val items by vm.items.collectAsStateWithLifecycle()
    val relationships by vm.relationships.collectAsStateWithLifecycle()

    if (vm.showGraph) {
        ContactGraphScreen(
            contacts = items.filter { it.isContact },
            relationships = relationships,
            onAddRelationship = vm::addRelationship,
            onDeleteRelationship = vm::deleteRelationship,
            onBack = { vm.showGraph = false },
        )
        return
    }

    // 人脉有自己的页面、资产有自己的页面,记忆列表里一律不出现(同 iOS MemoryListView.filtered)。
    val filtered = items.filter { item ->
        !item.isContact && !item.isAsset &&
            (vm.selectedTag == null || item.tagsList.contains(vm.selectedTag))
    }

    com.lodo.app.ui.LodoPage(
        title = com.lodo.app.ui.L("记忆", "Memory"),
        focus = com.lodo.app.ai.AgentFocus(com.lodo.app.ai.AgentPageFocus.MEMORY),
        askPrompt = com.lodo.app.ui.L("想找点什么?", "Looking for something?"),
        modifier = modifier,
        actions = {
            // AI 是主入口;手动收藏一段文字/链接这一条 AI 也能做,但留在右上角方便粘贴。
            IconButton(onClick = { vm.showCompose = true }) {
                Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.android_ui_memorize))
            }
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            // 标签只取这一页会出现的条目(资产的分类、人脉的标签不混进来)。
            val tags = items.filter { !it.isContact && !it.isAsset }.flatMap { it.tagsList }
                .filterNot { it in MemoryEntity.reservedTagNames }.distinct().sorted()
            if (tags.isNotEmpty()) {
                androidx.compose.foundation.lazy.LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = PaddingValues(horizontal = 16.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    item {
                        FilterChip(selected = vm.selectedTag == null, onClick = { vm.selectedTag?.let(vm::toggleTag) },
                            label = { Text(com.lodo.app.ui.L("全部", "All")) })
                    }
                    items(tags) { tag ->
                        FilterChip(selected = vm.selectedTag == tag, onClick = { vm.toggleTag(tag) },
                            label = { Text(if (tag.length > 12) tag.take(11) + "…" else tag) })
                    }
                }
            }
            if (filtered.isEmpty()) {
                com.lodo.app.ui.FullEmpty(
                    Icons.Outlined.Bookmarks,
                    if (vm.selectedTag == null) stringResource(R.string.android_ui_no_memories_yet) else stringResource(R.string.android_ui_no_matching_memories),
                    com.lodo.app.ui.L("说一句「帮我记住门禁码 1234」,或从别的 app 分享进来。", "Say \"remember the door code is 1234\", or share into Lodo."),
                )
            } else {
                LazyColumn(contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(filtered, key = { it.uuid }) { item ->
                        androidx.compose.material3.Card(
                            shape = androidx.compose.foundation.shape.RoundedCornerShape(20.dp),
                            colors = androidx.compose.material3.CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
                        ) { MemoryRow(item, onClick = { vm.detailUuid = item.uuid }) }
                    }
                }
            }
        }
    }

    if (vm.showCompose) {
        MemoryComposeSheet(
            busy = vm.busy,
            errorText = vm.errorText,
            onSave = vm::save,
            onDismiss = { vm.showCompose = false },
        )
    }

    if (vm.showAssetCompose) {
        AssetComposeSheet(
            onSave = { title, value, currency, liability, interest -> vm.saveAsset(title, value, currency, liability, interest) },
            onDismiss = { vm.showAssetCompose = false },
        )
    }

    if (vm.showContactCompose) {
        ContactComposeSheet(
            onSave = { nickname, phone, email, birthday, prefs -> vm.saveContact(nickname, phone, email, birthday, prefs) },
            onDismiss = { vm.showContactCompose = false },
        )
    }

    vm.detailUuid?.let { uuid ->
        items.firstOrNull { it.uuid == uuid }?.let { item ->
            when {
                item.isAsset -> AssetComposeSheet(
                    existing = item,
                    onSave = { title, value, currency, liability, interest ->
                        vm.updateAsset(uuid, title, value, currency, liability, interest)
                    },
                    onDelete = { vm.delete(uuid) },
                    onDismiss = { vm.detailUuid = null },
                )
                item.isContact -> ContactComposeSheet(
                    existing = item,
                    onSave = { nickname, phone, email, birthday, prefs ->
                        vm.updateContact(uuid, nickname, phone, email, birthday, prefs)
                    },
                    onDelete = { vm.delete(uuid) },
                    onDismiss = { vm.detailUuid = null },
                )
                else -> MemoryDetailSheet(
                    item = item,
                    allTags = vm.allTags,
                    onSave = { title, tags -> vm.updateTitleAndTags(uuid, title, tags) },
                    onRetry = { vm.retry(uuid) },
                    onDelete = { vm.delete(uuid) },
                    onDismiss = { vm.detailUuid = null },
                )
            }
        }
    }
}

@Composable
private fun MemoryRow(item: MemoryEntity, onClick: () -> Unit) {
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        colors = androidx.compose.material3.ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
        leadingContent = {
            when {
                item.statusEnum == MemoryStatus.PROCESSING -> CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                item.isAsset -> Icon(Icons.Filled.AttachMoney, contentDescription = null)
                item.isContact -> Icon(Icons.Filled.Person, contentDescription = null)
                item.isMenu -> Icon(Icons.AutoMirrored.Outlined.MenuBook, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                item.isTravelItem || item.travelTripUuid != null -> Icon(Icons.Outlined.Flight, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                else -> Icon(iconFor(item.kindEnum), contentDescription = null)
            }
        },
        headlineContent = {
            Row(horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Text(
                    item.title.ifEmpty { stringResource(R.string.android_ui_organizing) },
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                )
                if (item.isAsset && item.assetValue != null) {
                    Text(
                        "${item.assetCurrencyOrDefault} ${item.assetValue}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }
        },
        supportingContent = {
            Column {
                when {
                    item.isContact -> {
                        val parts = listOfNotNull(item.contactPhone, item.contactEmail)
                        if (parts.isNotEmpty()) Text(parts.joinToString(" · "), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    item.isAsset -> {
                        if (item.assetLiability != null || item.assetInterestRate != null) {
                            val parts = listOfNotNull(
                                item.assetLiability?.let {
                                    stringResource(
                                        R.string.android_ui_asset_liability_0_1,
                                        item.assetCurrencyOrDefault,
                                        it,
                                    )
                                },
                                item.assetInterestRate?.let {
                                    stringResource(R.string.android_ui_interest_rate_0, it)
                                },
                            )
                            Text(parts.joinToString(" · "), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    item.summary.isNotEmpty() -> Text(item.summary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                if (item.statusEnum == MemoryStatus.FAILED) {
                    Text(
                        stringResource(R.string.android_ui_organize_failed_tap_to_retry),
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                    )
                } else if (!item.isAsset && !item.isContact && item.tagsList.isNotEmpty()) {
                    Text(
                        item.tagsList.take(3).joinToString(" ") { "#$it" },
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                }
            }
        },
    )
}

private fun iconFor(kind: MemoryKind): ImageVector = when (kind) {
    MemoryKind.LINK -> Icons.Filled.Link
    MemoryKind.TEXT -> Icons.AutoMirrored.Filled.TextSnippet
}
