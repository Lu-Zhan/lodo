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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.lodo.app.data.MemoryEntity

/** "记一笔资产"/编辑资产,对应 iOS 资产收藏表单的核心子集:标题 + 金额 + 币种 +
 * 可选负债本金/利率。字段是结构化输入,不需要 AI 整理,离线也能用。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AssetComposeSheet(
    existing: MemoryEntity? = null,
    onSave: (title: String, value: Double?, currency: String, liability: Double?, interestRate: Double?) -> Unit,
    onDelete: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    var title by remember { mutableStateOf(existing?.title.orEmpty()) }
    var valueText by remember { mutableStateOf(existing?.assetValue?.toString().orEmpty()) }
    var currency by remember { mutableStateOf(existing?.assetCurrencyOrDefault ?: "CNY") }
    var liabilityText by remember { mutableStateOf(existing?.assetLiability?.toString().orEmpty()) }
    var interestText by remember { mutableStateOf(existing?.assetInterestRate?.toString().orEmpty()) }

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
                    stringResource(R.string.android_ui_record_asset),
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.weight(1f),
                    textAlign = TextAlign.Center,
                )
                TextButton(
                    onClick = {
                        onSave(
                            title.trim(), valueText.toDoubleOrNull(), currency.trim().ifBlank { "CNY" },
                            liabilityText.toDoubleOrNull(), interestText.toDoubleOrNull(),
                        )
                    },
                    enabled = title.isNotBlank(),
                ) { Text(stringResource(R.string.android_ui_save)) }
            }
            OutlinedTextField(
                value = title, onValueChange = { title = it },
                label = { Text(stringResource(R.string.android_ui_title)) },
                modifier = Modifier.fillMaxWidth(),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = valueText, onValueChange = { valueText = it },
                    label = { Text(stringResource(R.string.android_ui_amount)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = currency, onValueChange = { currency = it.uppercase() },
                    label = { Text(stringResource(R.string.android_ui_currency)) },
                    modifier = Modifier.weight(1f),
                )
            }
            OutlinedTextField(
                value = liabilityText, onValueChange = { liabilityText = it },
                label = { Text(stringResource(R.string.android_ui_liability_principal_optional)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = interestText, onValueChange = { interestText = it },
                label = { Text(stringResource(R.string.android_ui_annual_interest_rate_optional)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                modifier = Modifier.fillMaxWidth(),
            )
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
