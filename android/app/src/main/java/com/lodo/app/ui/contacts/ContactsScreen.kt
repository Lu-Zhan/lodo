package com.lodo.app.ui.contacts

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.People
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.contacts.ContactsBridge
import com.lodo.app.ui.FullEmpty
import com.lodo.app.ui.L
import com.lodo.app.ui.LodoPage
import com.lodo.app.ui.LodoRow
import com.lodo.app.ui.memory.ContactComposeSheet
import com.lodo.app.ui.memory.ContactGraphScreen
import com.lodo.app.ui.memory.MemoryViewModel

/**
 * 「人脉」页,对应 iOS ContactListView:人脉条目仍是打了「人脉」标签的记忆条目,
 * 这里只是独立的入口。右上角:关系图谱、新建、从通讯录导入。
 */
@Composable
fun ContactsScreen(vm: MemoryViewModel = viewModel()) {
    val items by vm.items.collectAsStateWithLifecycle()
    val relationships by vm.relationships.collectAsStateWithLifecycle()
    val contacts = items.filter { it.isContact }.sortedBy { it.title }
    val context = LocalContext.current
    var menu by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickContact()) { uri ->
        uri?.let { ContactsBridge.read(context, it) }?.let { c -> vm.saveContact(c.name, c.phone, c.email, null, null) }
    }

    if (vm.showGraph) {
        ContactGraphScreen(contacts, relationships, vm::addRelationship, vm::deleteRelationship, onBack = { vm.showGraph = false })
        return
    }

    LodoPage(
        title = L("人脉", "People"),
        focus = AgentFocus(AgentPageFocus.CONTACT),
        askPrompt = L("想起谁了?", "Thinking of someone?"),
        actions = {
            IconButton(onClick = { vm.showGraph = true }, enabled = contacts.size >= 2) { Icon(Icons.Filled.Hub, L("关系图谱", "Graph")) }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.MoreVert, L("更多", "More")) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(L("新建人脉", "New person")) }, onClick = { menu = false; creating = true })
                    DropdownMenuItem(text = { Text(L("从通讯录导入", "Import from Contacts")) }, onClick = { menu = false; pick.launch(null) })
                }
            }
        },
    ) { padding ->
        if (contacts.isEmpty()) {
            FullEmpty(Icons.Outlined.People, L("还没有人脉", "No people yet"),
                L("从右上角导入通讯录,或新建一位。", "Import from Contacts or add someone from the top-right menu."), padding)
            return@LodoPage
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp,
            top = padding.calculateTopPadding() + 8.dp, bottom = padding.calculateBottomPadding() + 16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            items(contacts, key = { it.uuid }) { c ->
                val count = relationships.count { it.fromUuid == c.uuid || it.toUuid == c.uuid }
                val subtitle = listOfNotNull(
                    c.contactNickname?.takeIf { it.isNotBlank() && it != c.title },
                    c.contactPhone ?: c.contactEmail,
                    if (count > 0) L("$count 条关系", "$count relationships") else null,
                ).joinToString(" · ")
                Card(shape = RoundedCornerShape(20.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    LodoRow(c.title, subtitle = subtitle, onClick = { editing = c.uuid }, leading = {
                        Box(Modifier.size(42.dp).background(MaterialTheme.colorScheme.secondaryContainer, CircleShape), contentAlignment = Alignment.Center) {
                            Text(c.title.take(1), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                                color = MaterialTheme.colorScheme.onSecondaryContainer)
                        }
                    })
                }
            }
        }
    }
    if (creating) ContactComposeSheet(onSave = { n, p, e, b, pr -> vm.saveContact(n, p, e, b, pr); creating = false }, onDismiss = { creating = false })
    editing?.let { uuid ->
        items.firstOrNull { it.uuid == uuid }?.let { item ->
            ContactComposeSheet(
                existing = item,
                onSave = { n, p, e, b, pr -> vm.updateContact(uuid, n, p, e, b, pr); editing = null },
                onDelete = { vm.delete(uuid); editing = null },
                onDismiss = { editing = null },
            )
        }
    }
}
