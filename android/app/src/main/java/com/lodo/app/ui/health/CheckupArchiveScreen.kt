package com.lodo.app.ui.health

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.core.*
import com.lodo.app.data.*
import com.lodo.app.ui.L
import com.lodo.app.ui.LodoSubPage
import java.time.LocalDate

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun CheckupArchiveScreen(vm: HealthJournalViewModel, onBack: () -> Unit) {
    val all by vm.checkups.collectAsStateWithLifecycle()
    val memories by vm.memories.collectAsStateWithLifecycle()
    val profiles by vm.profiles.collectAsStateWithLifecycle()
    val busy by vm.busy.collectAsStateWithLifecycle()
    val error by vm.error.collectAsStateWithLifecycle()
    var owner by rememberSaveable { mutableStateOf<String?>(null) }
    var metricMode by rememberSaveable { mutableStateOf(false) }
    var editor by remember { mutableStateOf<HealthEditor?>(null) }
    var reportEditor by remember { mutableStateOf<MemoryEntity?>(null) }
    var review by remember { mutableStateOf<CheckupReview?>(null) }
    var message by remember { mutableStateOf<String?>(null) }
    var delete by remember { mutableStateOf<Pair<String, (() -> Unit)>?>(null) }
    val entries = all.filter { it.profileUuid == owner }
    val reports = memories.filter { CheckupRepository.TAG in it.tagsList && it.checkupOwner() == owner }
        .sortedByDescending { it.checkupDateDay ?: it.createdAtMillis.toLocalDateTime().toLocalDate().toString() }
    val metrics = remember(entries) { CheckupPlan.metrics(entries.map { it.snapshot() }) }
    LodoSubPage(L("体检档案", "Checkups"), onBack, focus = AgentFocus(AgentPageFocus.HEALTH), actions = {
        IconButton(onClick = { editor = HealthEditor.Checkup() }) { Icon(Icons.Filled.Add, L("添加体检指标", "Add checkup item")) }
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            item("people") { FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(owner == null, { owner = null }, label = { Text(L("本人", "Me")) })
                profiles.forEach { p -> FilterChip(owner == p.uuid, { owner = p.uuid }, label = { Text(p.name) }) }
            } }
            item("import") { CheckupReportImport(vm, owner) }
            item("mode") {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    SegmentedButton(!metricMode, { metricMode = false }, shape = SegmentedButtonDefaults.itemShape(0, 2)) { Text(L("按报告", "By report")) }
                    SegmentedButton(metricMode, { metricMode = true }, shape = SegmentedButtonDefaults.itemShape(1, 2)) { Text(L("按指标", "By metric")) }
                }
            }
            if (busy) item("busy") { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            error?.let { text -> item("error") { Text(text, color = MaterialTheme.colorScheme.error) } }
            item("match") { OutlinedButton(onClick = { vm.runAction {
                val result = vm.app.checkups.normalizationPlan(owner)
                if (result.plan.isEmpty) message = L("没有需要修改的检查项", "No changes needed") else review = result
            } }, enabled = !busy && entries.isNotEmpty(), modifier = Modifier.fillMaxWidth()) { Text(L("重新匹配检查项", "Match item names")) } }
            if (metricMode) {
                items(metrics, key = { "metric-${it.key}" }) { metric ->
                    MetricHistory(metric) { id -> all.firstOrNull { it.uuid == id }?.let { editor = HealthEditor.Checkup(it) } }
                }
            } else {
                items(reports, key = { "report-${it.uuid}" }) { report ->
                    val records = entries.filter { it.reportUuid == report.uuid }.sortedBy { it.sortIndex }
                    HealthGroup(report.title) {
                        Text("${report.checkupDateDay ?: report.createdAtMillis.toLocalDateTime().toLocalDate()} · ${report.checkupInstitution.orEmpty()}")
                        Text(L("${records.count { it.kind == "item" }} 项 · ${CheckupPlan.abnormalCount(records.map { it.snapshot() })} 项异常", "${records.count { it.kind == "item" }} items"))
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            if (report.relativeFilePath != null) TextButton(onClick = { vm.runAction { vm.app.memoryRepository.openFile(report) } }) { Text(L("查看原件", "View original")) }
                            TextButton(onClick = { reportEditor = report }) { Text(L("报告资料", "Report details")) }
                            TextButton(onClick = { editor = HealthEditor.Checkup(CheckupEntryEntity(reportUuid = report.uuid, profileUuid = report.checkupOwner(), dateDay = report.checkupDateDay ?: LocalDate.now().toString(), sortIndex = (records.maxOfOrNull { it.sortIndex } ?: -1) + 1)) }) { Text(L("补一项", "Add item")) }
                            TextButton(onClick = { delete = L("删除整份报告和检查项?原件也会删除。", "Delete this report, items and original?") to { vm.runAction { vm.app.memoryRepository.delete(report.uuid) } } }) { Text(L("删除报告", "Delete report")) }
                        }
                        records.groupBy { if (it.kind == "item") it.category else L("综合建议", "Overall advice") }.forEach { (category, rows) ->
                            if (category.isNotBlank()) Text(category, style = MaterialTheme.typography.titleSmall)
                            rows.forEach { row ->
                                TextButton(onClick = { editor = HealthEditor.Checkup(row) }, modifier = Modifier.fillMaxWidth()) {
                                    Column(Modifier.fillMaxWidth()) {
                                        if (row.kind == "item") Text("${row.name} · ${row.snapshot().displayValue} ${flagLabel(row.snapshot().effectiveFlag)}")
                                        if (row.referenceRange.isNotBlank()) Text(L("参考 ", "Reference ") + row.referenceRange)
                                        if (row.conclusion.isNotBlank() && row.value.isNotBlank()) Text(row.conclusion)
                                        if (row.advice.isNotBlank()) Text(row.advice)
                                    }
                                }
                                TextButton(onClick = { delete = L("删除这项检查记录?", "Delete this checkup item?") to { vm.runAction { vm.app.checkups.deleteEntry(row.uuid) } } }) { Text(L("删除这一项", "Delete item")) }
                            }
                        }
                    }
                }
                // 旧备份可能只有指标没有报告主条目,仍然可查看、编辑,不会丢在界面之外。
                items(entries.filter { e -> reports.none { it.uuid == e.reportUuid } }, key = { "orphan-${it.uuid}" }) { entry -> HealthGroup("${entry.dateDay} · ${entry.name}") {
                    Text(entry.snapshot().displayValue)
                    TextButton(onClick = { editor = HealthEditor.Checkup(entry) }) { Text(L("编辑", "Edit")) }
                    TextButton(onClick = { delete = L("删除这项检查记录?", "Delete item?") to { vm.runAction { vm.app.checkups.deleteEntry(entry.uuid) } } }) { Text(L("删除", "Delete")) }
                } }
            }
            if (entries.isEmpty() && reports.isEmpty()) item("empty") { Text(L("还没有体检记录。导入报告或手动补一项,原文件和每次结果都会留下。", "No checkup records. Import a report or add an item manually.")) }
        }
    }
    editor?.let { value -> HealthEditorSheet(value, vm) { editor = null } }
    reportEditor?.let { report -> CheckupReportEditor(report, profiles, busy, error, onDismiss = { reportEditor = null }) { title, date, institution, person -> vm.runAction {
        vm.app.checkups.updateReport(report.uuid, title, date, institution, person); reportEditor = null
    } } }
    review?.let { proposed -> AlertDialog(onDismissRequest = { review = null }, title = { Text(L("核对匹配结果", "Review matches")) },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            proposed.plan.groups.forEach { Text("${it.variants.joinToString("、")} → ${it.canonical} (${it.recordCount})") }
            Text(L("改动 ${proposed.plan.updates.size} 条记录,删除 ${proposed.plan.removals.size} 条同报告重复记录。不同结果不会删除。", "${proposed.plan.updates.size} updates; ${proposed.plan.removals.size} same-report duplicates removed. Different results are retained."))
        } }, confirmButton = { TextButton(onClick = { vm.runAction { vm.app.checkups.applyNormalization(proposed); review = null } }, enabled = !busy) { Text(L("应用", "Apply")) } }, dismissButton = { TextButton(onClick = { review = null }) { Text(L("取消", "Cancel")) } }) }
    delete?.let { (text, action) -> AlertDialog(onDismissRequest = { delete = null }, title = { Text(text) }, confirmButton = { TextButton(onClick = { delete = null; action() }) { Text(L("删除", "Delete")) } }, dismissButton = { TextButton(onClick = { delete = null }) { Text(L("取消", "Cancel")) } }) }
    message?.let { text -> AlertDialog(onDismissRequest = { message = null }, title = { Text(text) }, confirmButton = { TextButton(onClick = { message = null }) { Text(L("好", "OK")) } }) }
}

@Composable private fun MetricHistory(metric: CheckupMetric, onEdit: (String) -> Unit) {
    HealthGroup(metric.name) {
        val units = metric.records.map { it.unit.trim().lowercase() }.filter { it.isNotEmpty() }.distinct()
        if (metric.isNumeric && units.size <= 1) TrendChart(metric)
        if (units.size > 1) Text(L("历次单位不同,只列原始结果,不连成趋势线。", "Units differ; original results are listed without connecting them."))
        for (record in metric.records.asReversed()) TextButton(onClick = { onEdit(record.id) }, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.fillMaxWidth()) {
                Text("${record.date} · ${record.displayValue} ${flagLabel(record.effectiveFlag)}")
                if (record.reference.isNotBlank()) Text(L("参考 ", "Reference ") + record.reference)
                if (record.advice.isNotBlank()) Text(record.advice)
            }
        }
    }
}
@Composable private fun TrendChart(metric: CheckupMetric) {
    val records = metric.records.filter { it.numericValue != null }
    if (records.size < 2) return
    val color = MaterialTheme.colorScheme.primary
    val referenceColor = MaterialTheme.colorScheme.outline
    val bounds = metric.referenceBounds
    val values = records.map { it.numericValue!! }
    val all = values + listOfNotNull(bounds.low, bounds.high)
    val low = all.min(); val high = all.max()
    val range = (high - low).takeIf { it > 0 && it.isFinite() } ?: 1.0
    Canvas(Modifier.fillMaxWidth().height(120.dp).semantics { contentDescription = "${metric.name}: ${records.joinToString { "${it.date} ${it.displayValue}" }}" }) {
        val pad = 8.dp.toPx()
        fun y(value: Double) = (size.height - pad - ((value - low) / range).toFloat() * (size.height - 2 * pad))
        listOfNotNull(bounds.low, bounds.high).forEach { value -> drawLine(referenceColor, Offset(pad, y(value)), Offset(size.width - pad, y(value)), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 4.dp.toPx()))) }
        val firstDay = records.first().date.toEpochDay(); val daySpan = (records.last().date.toEpochDay() - firstDay).coerceAtLeast(1)
        val path = Path()
        records.forEachIndexed { i, record ->
            val x = pad + ((record.date.toEpochDay() - firstDay).toDouble() / daySpan).toFloat() * (size.width - 2 * pad)
            val y = y(record.numericValue!!)
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            drawCircle(color, 3.dp.toPx(), Offset(x, y))
        }
        drawPath(path, color, style = Stroke(2.dp.toPx()))
    }
}
private fun flagLabel(raw: String?) = when (raw) { "high" -> "↑ 偏高"; "low" -> "↓ 偏低"; "abnormal" -> "异常"; "normal" -> "正常"; else -> "" }

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable private fun CheckupReportEditor(report: MemoryEntity, profiles: List<HealthProfileEntity>, busy: Boolean, error: String?, onDismiss: () -> Unit,
    onSave: (String, LocalDate, String, String?) -> Unit) {
    var title by remember(report.uuid) { mutableStateOf(report.title) }
    var day by remember(report.uuid) { mutableStateOf(report.checkupDateDay ?: report.createdAtMillis.toLocalDateTime().toLocalDate().toString()) }
    var institution by remember(report.uuid) { mutableStateOf(report.checkupInstitution.orEmpty()) }
    var owner by remember(report.uuid) { mutableStateOf(report.checkupOwner()) }
    val parsedDay = runCatching { LocalDate.parse(day) }.getOrNull()
    ModalBottomSheet(onDismissRequest = { if (!busy) onDismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            com.lodo.app.ui.assets.SheetHeader(L("报告资料", "Report details"), parsedDay != null && !busy, onDismiss) { onSave(title, requireNotNull(parsedDay), institution, owner) }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            OutlinedTextField(title, { title = it }, label = { Text(L("报告名称", "Report title")) }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(day, { day = it }, label = { Text(L("体检日期(YYYY-MM-DD)", "Date (YYYY-MM-DD)")) }, isError = parsedDay == null, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(institution, { institution = it }, label = { Text(L("体检机构", "Institution")) }, modifier = Modifier.fillMaxWidth())
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilterChip(owner == null, { owner = null }, label = { Text(L("本人", "Me")) })
                profiles.forEach { p -> FilterChip(owner == p.uuid, { owner = p.uuid }, label = { Text(p.name) }) }
            }
            Text(L("修改日期和归属会同时更新全部检查项;家人资料不进入本人的健康分析。", "Date and owner changes update every item. Family data is excluded from your health analysis."))
            Spacer(Modifier.height(24.dp))
        }
    }
}
