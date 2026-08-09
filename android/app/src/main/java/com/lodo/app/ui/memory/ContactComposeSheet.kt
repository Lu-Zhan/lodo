package com.lodo.app.ui.memory

import com.lodo.app.R
import androidx.compose.ui.res.stringResource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.lodo.app.contacts.ContactsBridge
import com.lodo.app.data.MemoryEntity
import com.lodo.app.data.toEpochMillis
import java.time.LocalDate
import java.time.format.DateTimeParseException

/** "记一位人脉"/编辑人脉,对应 iOS ContactDetailView 的核心子集:昵称/电话/
 * 邮箱/生日/喜好。不含头像与多文件附件(需要本地文件存储基础设施)。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ContactComposeSheet(
    existing: MemoryEntity? = null,
    onSave: (nickname: String, phone: String?, email: String?, birthdayMillis: Long?, preferences: String?) -> Unit,
    onDelete: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    var nickname by remember { mutableStateOf(existing?.contactNickname ?: existing?.title.orEmpty()) }
    var phone by remember { mutableStateOf(existing?.contactPhone.orEmpty()) }
    var email by remember { mutableStateOf(existing?.contactEmail.orEmpty()) }
    var birthdayText by remember {
        mutableStateOf(existing?.contactBirthday?.toLocalDate()?.toString().orEmpty())
    }
    var preferences by remember { mutableStateOf(existing?.contactPreferences.orEmpty()) }
    val context = LocalContext.current

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.shared_cancel)) }
                Text(
                    stringResource(R.string.android_ui_record_contact),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                    textAlign = TextAlign.Center,
                )
                TextButton(
                    onClick = {
                        val birthdayMillis = try {
                            LocalDate.parse(birthdayText.trim()).atStartOfDay().toEpochMillis()
                        } catch (e: DateTimeParseException) {
                            null
                        }
                        onSave(
                            nickname.trim(), phone.trim().ifBlank { null }, email.trim().ifBlank { null },
                            birthdayMillis, preferences.trim().ifBlank { null },
                        )
                    },
                    enabled = nickname.isNotBlank(),
                ) { Text(stringResource(R.string.android_ui_save)) }
            }
            OutlinedTextField(
                value = nickname, onValueChange = { nickname = it },
                label = { Text(stringResource(R.string.android_ui_nickname)) },
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = phone, onValueChange = { phone = it },
                label = { Text(stringResource(R.string.android_ui_phone)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Phone),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = email, onValueChange = { email = it },
                label = { Text(stringResource(R.string.android_ui_email)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = birthdayText, onValueChange = { birthdayText = it },
                label = { Text(stringResource(R.string.android_ui_birthday_yyyy_mm_dd)) },
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = preferences, onValueChange = { preferences = it },
                label = { Text(stringResource(R.string.android_ui_preferences)) },
                minLines = 2,
                modifier = Modifier.fillMaxWidth(),
            )
            if (existing != null) {
                OutlinedButton(
                    onClick = { context.startActivity(ContactsBridge.exportIntent(nickname, phone.ifBlank { null }, email.ifBlank { null })) },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.android_ui_export_to_contacts)) }
            }
            if (onDelete != null) {
                OutlinedButton(onClick = { onDelete(); onDismiss() }, modifier = Modifier.fillMaxWidth()) {
                    Text(
                        stringResource(R.string.android_ui_delete_this_memory),
                        color = MaterialTheme.colorScheme.error,
                    )
                }
            }
        }
    }
}
