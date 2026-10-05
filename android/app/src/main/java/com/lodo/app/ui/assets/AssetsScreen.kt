package com.lodo.app.ui.assets

import android.app.Application
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.AccountBalance
import androidx.compose.material.icons.outlined.AccountBalanceWallet
import androidx.compose.material.icons.outlined.CreditCard
import androidx.compose.material.icons.outlined.DirectionsCar
import androidx.compose.material.icons.outlined.HealthAndSafety
import androidx.compose.material.icons.outlined.House
import androidx.compose.material.icons.outlined.Inventory2
import androidx.compose.material.icons.outlined.Payments
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.ShowChart
import androidx.compose.material.icons.outlined.TrendingDown
import androidx.compose.material.icons.outlined.TrendingUp
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.LodoApp
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.core.AssetCategory
import com.lodo.app.core.FinanceCadence
import com.lodo.app.core.FinanceKind
import com.lodo.app.core.FinancePlan
import com.lodo.app.data.ExchangeRates
import com.lodo.app.data.FinanceEntity
import com.lodo.app.data.MemoryEntity
import com.lodo.app.data.formatAmount
import com.lodo.app.data.snapshot
import com.lodo.app.data.toLocalDateTime
import com.lodo.app.ui.FullEmpty
import com.lodo.app.ui.GroupCard
import com.lodo.app.ui.L
import com.lodo.app.ui.LocalSettings
import com.lodo.app.ui.LodoPage
import com.lodo.app.ui.LodoRow
import com.lodo.app.ui.countdown.SwitchRow
import com.lodo.app.ui.theme.LodoColor
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDateTime

class AssetsViewModel(application: Application) : AndroidViewModel(application) {
    private val app = application as LodoApp
    val memories = app.memoryRepository.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val finance = app.finance.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val rates = ExchangeRates.rates

    fun refresh() = viewModelScope.launch {
        ExchangeRates.refreshIfNeeded(app)
        app.finance.syncReminders(app.repository, app.settings.snapshot().allDayTime)
    }

    fun saveAsset(existing: MemoryEntity?, title: String, category: String, value: Double?, currency: String,
                  liability: Double?, rate: Double?, note: String) = viewModelScope.launch {
        if (existing == null) app.memoryRepository.saveAsset(title, value, currency, liability, rate, listOf(category), note = note)
        else app.memoryRepository.updateAsset(existing.uuid, title, value, currency, liability, rate, category, note)
    }

    fun deleteAsset(uuid: String) = viewModelScope.launch { app.memoryRepository.delete(uuid) }

    fun saveFinance(e: FinanceEntity) = viewModelScope.launch {
        app.finance.save(e, app.repository, app.settings.snapshot().allDayTime)
    }

    fun deleteFinance(uuid: String) = viewModelScope.launch { app.finance.delete(uuid, app.repository) }
}

fun categoryIcon(category: String): ImageVector = when (category) {
    "房产" -> Icons.Outlined.House
    "车辆" -> Icons.Outlined.DirectionsCar
    "存款" -> Icons.Outlined.AccountBalance
    "投资" -> Icons.Outlined.ShowChart
    "保险" -> Icons.Outlined.HealthAndSafety
    else -> Icons.Outlined.Inventory2
}

fun cadenceLabel(c: FinanceCadence) = when (c) {
    FinanceCadence.MONTHLY -> L("每月", "Monthly")
    FinanceCadence.QUARTERLY -> L("每季度", "Quarterly")
    FinanceCadence.YEARLY -> L("每年", "Yearly")
    FinanceCadence.IRREGULAR -> L("不定期", "Irregular")
}

/**
 * 「资产」页,对应 iOS AssetsView:隔几个月更新一次的资产台账(不记日常消费)。
 * 顶部总览:净资产、每月收入/固定支出/结余、多久没更新;资产(打「资产」标签的记忆条目)按分类;
 * 收入/固定支出/信用卡是独立表,信用卡开了提醒会在还款日前一天生成一条任务。
 */
@Composable
fun AssetsScreen(vm: AssetsViewModel = viewModel()) {
    val memories by vm.memories.collectAsStateWithLifecycle()
    val finance by vm.finance.collectAsStateWithLifecycle()
    val rates by vm.rates.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { vm.refresh() }
    val assets = memories.filter { it.isAsset }
    var menu by remember { mutableStateOf(false) }
    var editAsset by remember { mutableStateOf<MemoryEntity?>(null) }
    var newAsset by remember { mutableStateOf(false) }
    var editFinance by remember { mutableStateOf<FinanceEntity?>(null) }
    var newFinanceKind by remember { mutableStateOf<FinanceKind?>(null) }
    val now = LocalDateTime.now()
    val display = "CNY"
    val convert: (Double, String, String) -> Double? = { a, f, t -> ExchangeRates.convert(a, f, t) }
    @Suppress("UNUSED_VARIABLE") val ratesKey = rates
    val net = FinancePlan.netWorth(assets.map { FinancePlan.AssetAmount(it.assetValue, it.assetLiability, it.assetCurrencyOrDefault) }, display, convert)
    val monthly = FinancePlan.monthlyTotal(finance.map { it.snapshot() }, display, now, convert)
    val stale = assets.count { FinancePlan.monthsSince(it.assetUpdatedAt.toLocalDateTime(), now) >= FinancePlan.STALE_MONTHS }

    LodoPage(
        title = L("资产", "Assets"),
        focus = AgentFocus(AgentPageFocus.ASSETS),
        askPrompt = L("记一笔资产?", "Update an asset?"),
        actions = {
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Filled.Add, L("新建", "Add")) }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text(L("资产 / 负债", "Asset / liability")) }, onClick = { menu = false; newAsset = true })
                    DropdownMenuItem(text = { Text(L("收入", "Income")) }, onClick = { menu = false; newFinanceKind = FinanceKind.INCOME })
                    DropdownMenuItem(text = { Text(L("固定支出", "Fixed expense")) }, onClick = { menu = false; newFinanceKind = FinanceKind.EXPENSE })
                    DropdownMenuItem(text = { Text(L("信用卡", "Credit card")) }, onClick = { menu = false; newFinanceKind = FinanceKind.CREDIT_CARD })
                }
            }
        },
    ) { padding ->
        if (assets.isEmpty() && finance.isEmpty()) {
            FullEmpty(Icons.Outlined.AccountBalanceWallet, L("还没有记过资产", "No assets yet"),
                L("说一句「记一下招行存款 32 万」,或从右上角「+」添加收入、支出和信用卡。", "Tell the AI \"savings at CMB is 320k\", or add income/expenses/cards from +."), padding)
            return@LodoPage
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp,
            top = padding.calculateTopPadding() + 4.dp, bottom = padding.calculateBottomPadding() + 16.dp)) {
            item("summary") {
                Card(shape = RoundedCornerShape(28.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                    Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(L("净资产", "Net worth"), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        Text(formatAmount(net.net, display), fontSize = 32.sp, fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        Text(L("资产 ", "Assets ") + formatAmount(net.assets, display) + L(" · 负债 ", " · Liabilities ") + formatAmount(net.liabilities, display),
                            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        if (finance.any { it.kind != FinanceKind.CREDIT_CARD.raw }) {
                            HorizontalDivider(Modifier.padding(vertical = 6.dp), color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.2f))
                            Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                                Stat(L("每月收入", "Income/mo"), formatAmount(monthly.income, display))
                                Stat(L("固定支出", "Expenses/mo"), formatAmount(monthly.expense, display))
                                Stat(L("结余", "Net/mo"), formatAmount(monthly.net, display))
                            }
                            if (monthly.irregularCount > 0) Text(L("另有 ${monthly.irregularCount} 项不定期的没折算", "${monthly.irregularCount} irregular item(s) not included"),
                                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        }
                        val missing = (net.missingCurrencies + monthly.missingCurrencies).distinct()
                        if (missing.isNotEmpty()) Text(L("换不出汇率,没计入:", "No exchange rate, not counted: ") + missing.joinToString("、"),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        if (stale > 0) Text(L("$stale 项超过 3 个月没更新了", "$stale item(s) not updated for 3+ months"),
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onPrimaryContainer)
                    }
                }
            }
            val groups = assets.groupBy { AssetCategory.category(it.tagsList, MemoryEntity.reservedTagNames) }
            AssetCategory.orderedGroups(groups.keys.toList()).forEach { cat ->
                item("cat-$cat") {
                    GroupCard(title = cat) {
                        groups.getValue(cat).forEachIndexed { i, a ->
                            if (i > 0) HorizontalDivider(Modifier.padding(start = 52.dp))
                            val staleItem = FinancePlan.monthsSince(a.assetUpdatedAt.toLocalDateTime(), now) >= FinancePlan.STALE_MONTHS
                            LodoRow(
                                a.title, icon = categoryIcon(cat), onClick = { editAsset = a },
                                subtitle = listOfNotNull(
                                    a.assetLiability?.let { L("负债 ", "Liability ") + formatAmount(it, a.assetCurrencyOrDefault) },
                                    a.assetInterestRate?.let { L("利率 $it%", "Rate $it%") },
                                    a.summary.takeIf { it.isNotBlank() },
                                ).joinToString(" · "),
                                trailing = {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        if (staleItem) Icon(Icons.Outlined.Schedule, L("很久没更新", "Stale"), tint = LodoColor.warning, modifier = Modifier.size(16.dp).padding(end = 2.dp))
                                        a.assetValue?.let { Text(formatAmount(it, a.assetCurrencyOrDefault), fontWeight = FontWeight.SemiBold) }
                                    }
                                },
                            )
                        }
                    }
                }
            }
            listOf(FinanceKind.INCOME to L("收入", "Income"), FinanceKind.EXPENSE to L("固定支出", "Fixed expenses"),
                FinanceKind.CREDIT_CARD to L("信用卡", "Credit cards")).forEach { (kind, title) ->
                val list = finance.filter { it.kind == kind.raw }
                if (list.isNotEmpty()) item("fin-${kind.raw}") {
                    GroupCard(title = title) {
                        list.forEachIndexed { i, f ->
                            if (i > 0) HorizontalDivider(Modifier.padding(start = 52.dp))
                            val snap = f.snapshot()
                            val subtitle = when (kind) {
                                FinanceKind.CREDIT_CARD -> listOfNotNull(
                                    f.institution.takeIf { it.isNotBlank() },
                                    FinancePlan.nextDueDate(snap, now)?.let { L("下次还款 $it", "Next due $it") },
                                    if (f.remindEnabled && f.dayOfMonth != null) L("前一天提醒", "Reminds the day before") else null,
                                ).joinToString(" · ")
                                else -> listOfNotNull(cadenceLabel(snap.cadence), f.dayOfMonth?.let { L("$it 号", "day $it") },
                                    f.institution.takeIf { it.isNotBlank() }).joinToString(" · ")
                            }
                            LodoRow(
                                f.title, subtitle = subtitle, onClick = { editFinance = f },
                                icon = when (kind) {
                                    FinanceKind.INCOME -> Icons.Outlined.TrendingUp
                                    FinanceKind.EXPENSE -> Icons.Outlined.TrendingDown
                                    FinanceKind.CREDIT_CARD -> Icons.Outlined.CreditCard
                                },
                                trailing = { f.amount?.let { Text(formatAmount(it, f.currency), fontWeight = FontWeight.SemiBold) } },
                            )
                        }
                    }
                }
            }
        }
    }
    if (newAsset || editAsset != null) AssetEditSheet(editAsset,
        onSave = { t, c, v, cur, l, r, n -> vm.saveAsset(editAsset, t, c, v, cur, l, r, n); newAsset = false; editAsset = null },
        onDelete = { editAsset?.let { vm.deleteAsset(it.uuid) }; editAsset = null },
        onDismiss = { newAsset = false; editAsset = null })
    val financeKind = editFinance?.let { FinanceKind.from(it.kind) } ?: newFinanceKind
    if (financeKind != null) FinanceEditSheet(financeKind, editFinance,
        onSave = { vm.saveFinance(it); editFinance = null; newFinanceKind = null },
        onDelete = { editFinance?.let { vm.deleteFinance(it.uuid) }; editFinance = null },
        onDismiss = { editFinance = null; newFinanceKind = null })
}

@Composable
private fun Stat(label: String, value: String) = Column {
    Text(label, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
    Text(value, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onPrimaryContainer)
}

@Composable
fun SheetHeader(title: String, canSave: Boolean, onCancel: () -> Unit, onSave: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        TextButton(onClick = onCancel) { Text(L("取消", "Cancel")) }
        Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f), textAlign = TextAlign.Center)
        TextButton(onClick = onSave, enabled = canSave) { Text(L("保存", "Save")) }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CurrencyChips(selected: String, onSelect: (String) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        ExchangeRates.commonCurrencies.take(8).forEach { c ->
            FilterChip(selected = selected == c, onClick = { onSelect(c) }, label = { Text(c) })
        }
    }
}

private fun String.toAmount(): Double? = replace(",", "").trim().toDoubleOrNull()
private fun Double?.text(): String = this?.let { if (it % 1.0 == 0.0) it.toLong().toString() else it.toString() } ?: ""

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun AssetEditSheet(
    existing: MemoryEntity?,
    onSave: (String, String, Double?, String, Double?, Double?, String) -> Unit,
    onDelete: () -> Unit, onDismiss: () -> Unit,
) {
    var title by remember { mutableStateOf(existing?.title ?: "") }
    var category by remember { mutableStateOf(existing?.let { AssetCategory.category(it.tagsList, MemoryEntity.reservedTagNames) } ?: "存款") }
    var value by remember { mutableStateOf(existing?.assetValue.text()) }
    var currency by remember { mutableStateOf(existing?.assetCurrencyOrDefault ?: "CNY") }
    var liability by remember { mutableStateOf(existing?.assetLiability.text()) }
    var rate by remember { mutableStateOf(existing?.assetInterestRate.text()) }
    var note by remember { mutableStateOf(existing?.summary ?: "") }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SheetHeader(if (existing == null) L("新建资产", "New asset") else L("编辑资产", "Edit asset"), title.isNotBlank(), onDismiss) {
                onSave(title.trim(), category, value.toAmount(), currency, liability.toAmount(), rate.toAmount(), note.trim())
            }
            OutlinedTextField(title, { title = it }, label = { Text(L("名称", "Name")) }, singleLine = true, modifier = Modifier.fillMaxWidth())
            FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                AssetCategory.presets.forEach { c -> FilterChip(selected = category == c, onClick = { category = c }, label = { Text(c) },
                    leadingIcon = { Icon(categoryIcon(c), null, Modifier.size(18.dp)) }) }
            }
            OutlinedTextField(value, { value = it }, label = { Text(L("金额", "Value")) }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
            CurrencyChips(currency) { currency = it }
            OutlinedTextField(liability, { liability = it }, label = { Text(L("负债本金(可选)", "Liability (optional)")) }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(rate, { rate = it }, label = { Text(L("年化利率 %(可选)", "Interest rate % (optional)")) }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(note, { note = it }, label = { Text(L("备注", "Notes")) }, modifier = Modifier.fillMaxWidth())
            Text(L("每次保存都算核对过一次。", "Saving counts as checked today."), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (existing != null) TextButton(onClick = onDelete) { Text(L("删除", "Delete"), color = MaterialTheme.colorScheme.error) }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun FinanceEditSheet(
    kind: FinanceKind, existing: FinanceEntity?,
    onSave: (FinanceEntity) -> Unit, onDelete: () -> Unit, onDismiss: () -> Unit,
) {
    var title by remember { mutableStateOf(existing?.title ?: "") }
    var amount by remember { mutableStateOf(existing?.amount.text()) }
    var currency by remember { mutableStateOf(existing?.currency ?: "CNY") }
    var cadence by remember { mutableStateOf(FinanceCadence.from(existing?.cadence ?: "monthly")) }
    var day by remember { mutableStateOf(existing?.dayOfMonth?.toString() ?: "") }
    var statement by remember { mutableStateOf(existing?.statementDay?.toString() ?: "") }
    var institution by remember { mutableStateOf(existing?.institution ?: "") }
    var remind by remember { mutableStateOf(existing?.remindEnabled ?: true) }
    var notes by remember { mutableStateOf(existing?.notes ?: "") }
    val heading = when (kind) {
        FinanceKind.INCOME -> L("收入", "Income")
        FinanceKind.EXPENSE -> L("固定支出", "Fixed expense")
        FinanceKind.CREDIT_CARD -> L("信用卡", "Credit card")
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            SheetHeader(heading, title.isNotBlank(), onDismiss) {
                onSave((existing ?: FinanceEntity(kind = kind.raw, title = "")).copy(
                    title = title.trim(), amount = amount.toAmount(), currency = currency, cadence = cadence.raw,
                    dayOfMonth = day.toIntOrNull()?.coerceIn(1, 31), statementDay = statement.toIntOrNull()?.coerceIn(1, 31),
                    institution = institution.trim(), remindEnabled = remind, notes = notes,
                ))
            }
            OutlinedTextField(title, { title = it }, label = { Text(if (kind == FinanceKind.CREDIT_CARD) L("卡名", "Card name") else L("名称", "Name")) },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(institution, { institution = it }, label = { Text(if (kind == FinanceKind.CREDIT_CARD) L("银行", "Bank") else L("来源/对象(可选)", "From/to (optional)")) },
                singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(amount, { amount = it }, label = { Text(if (kind == FinanceKind.CREDIT_CARD) L("额度(可选)", "Limit (optional)") else L("金额", "Amount")) },
                singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal), modifier = Modifier.fillMaxWidth())
            CurrencyChips(currency) { currency = it }
            if (kind != FinanceKind.CREDIT_CARD) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    FinanceCadence.entries.forEach { c -> FilterChip(selected = cadence == c, onClick = { cadence = c }, label = { Text(cadenceLabel(c)) }) }
                }
            }
            OutlinedTextField(day, { day = it.filter(Char::isDigit).take(2) },
                label = { Text(if (kind == FinanceKind.CREDIT_CARD) L("还款日(每月几号)", "Due day of month") else L("每月几号(可选)", "Day of month (optional)")) },
                singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth())
            if (kind == FinanceKind.CREDIT_CARD) {
                OutlinedTextField(statement, { statement = it.filter(Char::isDigit).take(2) }, label = { Text(L("账单日(可选)", "Statement day (optional)")) },
                    singleLine = true, keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth())
                SwitchRow(L("还款提醒", "Payment reminder"), remind, subtitle = L("还款日前一天在全天提醒时刻生成一条任务", "Creates a task the day before the due date")) { remind = it }
            }
            OutlinedTextField(notes, { notes = it }, label = { Text(L("备注", "Notes")) }, modifier = Modifier.fillMaxWidth())
            if (existing != null) TextButton(onClick = onDelete) { Text(L("删除", "Delete"), color = MaterialTheme.colorScheme.error) }
            Spacer(Modifier.height(24.dp))
        }
    }
}
