package com.lodo.app.ui.health

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.room.withTransaction
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.core.*
import com.lodo.app.data.*
import com.lodo.app.ui.L
import java.time.LocalDate
import java.time.LocalDateTime

@Composable fun BodyReportImport(vm: HealthJournalViewModel) = ReportImport(vm, true)
@Composable fun CheckupReportImport(vm: HealthJournalViewModel, initialOwner: String? = null) = ReportImport(vm, false, initialOwner)

/** 文件先保存到私有目录;整理失败保留原件,重试不会再复制一份。 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ReportImport(vm: HealthJournalViewModel, weight: Boolean, initialOwner: String? = null) {
    val memories by vm.memories.collectAsState()
    val profiles by vm.profiles.collectAsState()
    val busy by vm.busy.collectAsState()
    var profileId by remember(initialOwner) { mutableStateOf(initialOwner) }
    var preview by remember { mutableStateOf<Pair<MemoryEntity, ParsedWeightReport>?>(null) }
    var reportToReplace by remember { mutableStateOf<MemoryEntity?>(null) }
    val tag = if (weight) "体重秤报告" else "体检报告"
    fun parse(item: MemoryEntity) = vm.runAction {
        val source = if (item.sourceText.isBlank()) vm.app.memoryRepository.extractReport(item) else item
        if (weight) {
            val result = DeepSeekClient.parseWeightReport(vm.app.settings.aiConfig(), source.sourceText)
            require(result.measurements.isNotEmpty()) { "没有读到有效测量,原文件已保留" }
            preview = source to result
        } else {
            // profile 从报告自身取,重试时不能悄悄改成界面当前选择的人。
            val owner = source.checkupOwner()
            val known = CheckupPlan.knownNames(vm.journal.dao.checkups().filter { it.profileUuid == owner }.map { it.snapshot() })
            val result = DeepSeekClient.parseCheckupReport(vm.app.settings.aiConfig(), CheckupRepository.rawText(source).take(30000), known)
            vm.app.checkups.saveParsed(source, result)
        }
    }
    // 保存与解析分开启动,避免 runAction 的重入保护吞掉解析。
    var savedToParse by remember { mutableStateOf<MemoryEntity?>(null) }
    LaunchedEffect(savedToParse, busy) { if (!busy) savedToParse?.let { savedToParse = null; parse(it) } }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) vm.runAction {
            val tags = listOf(tag) + if (!weight && profileId != null) listOf("家人健康", "health-profile:$profileId") else listOf(MemoryEntity.healthTagName)
            savedToParse = vm.app.memoryRepository.saveReportFile(uri, tags)
        }
    }
    HealthGroup(if (weight) L("体重秤报告", "Scale reports") else L("体检报告", "Checkup reports")) {
        Text(L("PDF / 照片在本机取字后交给 AI;原文件保留在本机并进入备份。", "OCR runs locally; only text is sent to AI. Originals remain local and are backed up."), style = MaterialTheme.typography.bodySmall)
        if (!weight) FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip(profileId == null, { profileId = null }, label = { Text(L("本人", "Me")) })
            profiles.forEach { profile -> FilterChip(profileId == profile.uuid, { profileId = profile.uuid }, label = { Text(profile.name) }) }
        }
        OutlinedButton(onClick = { picker.launch(arrayOf("application/pdf", "image/*", "text/plain")) }, enabled = !busy) { Text(L("导入报告", "Import report")) }
        for (item in memories.filter { tag in it.tagsList }) {
            Text(item.originalFileName ?: item.title)
            Row {
                TextButton(onClick = { vm.runAction { vm.app.memoryRepository.openFile(item) } }) { Text(L("查看原件", "View original")) }
                TextButton(onClick = { reportToReplace = item }, enabled = !busy) { Text(L("重新整理", "Reprocess")) }
            }
        }
    }
    reportToReplace?.let { item -> AlertDialog(onDismissRequest = { reportToReplace = null }, title = { Text(L("重新整理这份报告?", "Reprocess this report?")) },
        text = { Text(if (weight) L("将重新核对测量,不会直接写入。", "Measurements will be reviewed before saving.") else L("将替换这份报告的检查项,包括你手工修改过的内容。", "This replaces the report's items, including manual edits.")) },
        confirmButton = { TextButton(onClick = { reportToReplace = null; parse(item) }) { Text(L("继续", "Continue")) } }, dismissButton = { TextButton(onClick = { reportToReplace = null }) { Text(L("取消", "Cancel")) } }) }
    preview?.let { (item, report) -> WeightReportPreview(report, busy, onDismiss = { preview = null }) { selected ->
        vm.runAction {
            vm.app.database.withTransaction {
                val existing = vm.journal.dao.weights()
                for (m in selected) {
                    val date = requireNotNull(m.date) { "请补全测量日期" }
                    require(date <= LocalDateTime.now().plusMinutes(5)) { "测量日期不能在未来" }
                    // 同一时刻且所有读数相同的测量不重复写入,日期相同但读数不同则保留。
                    val record = WeightRecordEntity(dateMillis = date.toEpochMillis(), weightKg = m.weightKg, bodyFatPercent = m.bodyFatPercent,
                        muscleMassKg = m.muscleMassKg, visceralFatLevel = m.visceralFatLevel, basalMetabolicKcal = m.basalMetabolicKcal,
                        bodyWaterPercent = m.bodyWaterPercent, boneMassKg = m.boneMassKg, reportUuid = item.uuid)
                    if (existing.none { it.dateMillis == record.dateMillis && it.weightKg == record.weightKg && it.bodyFatPercent == record.bodyFatPercent &&
                        it.muscleMassKg == record.muscleMassKg && it.visceralFatLevel == record.visceralFatLevel && it.basalMetabolicKcal == record.basalMetabolicKcal && it.bodyWaterPercent == record.bodyWaterPercent && it.boneMassKg == record.boneMassKg }) vm.journal.dao.saveWeight(record)
                }
            }
            preview = null
        }
    } }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WeightReportPreview(report: ParsedWeightReport, busy: Boolean, onDismiss: () -> Unit, onSave: (List<WeightMeasurement>) -> Unit) {
    val selected = remember(report) { mutableStateMapOf<String, Boolean>().apply { report.measurements.forEach { put(it.id, it.date != null) } } }
    val dates = remember(report) { mutableStateMapOf<String, String>().apply { report.measurements.forEach { put(it.id, it.date?.toString()?.replace('T', ' ') ?: "") } } }
    var error by remember { mutableStateOf<String?>(null) }
    ModalBottomSheet(onDismissRequest = { if (!busy) onDismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(L("核对测量", "Review measurements"), style = MaterialTheme.typography.titleLarge)
            Text(L("请核对日期、单位和读数,只导入勾选的测量。", "Check dates, units and readings. Only selected measurements are imported."))
            if (report.droppedValues > 0) Text(L("有 ${report.droppedValues} 项读数因单位或范围异常未采用。", "${report.droppedValues} readings were dropped due to units or range."))
            for (m in report.measurements) {
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    Checkbox(selected[m.id] == true, { selected[m.id] = it })
                    Text(listOfNotNull(m.weightKg?.let { "$it kg" }, m.bodyFatPercent?.let { "体脂 $it%" }, m.muscleMassKg?.let { "肌肉 $it kg" }, m.visceralFatLevel?.let { "内脏脂肪 $it" }, m.basalMetabolicKcal?.let { "代谢 $it kcal" }, m.bodyWaterPercent?.let { "水分 $it%" }, m.boneMassKg?.let { "骨量 $it kg" }).joinToString(" · "), Modifier.weight(1f))
                }
                OutlinedTextField(dates[m.id].orEmpty(), { dates[m.id] = it }, label = { Text(L("测量日期时间(YYYY-MM-DD HH:mm)", "Date/time (YYYY-MM-DD HH:mm)")) }, modifier = Modifier.fillMaxWidth())
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(onClick = {
                runCatching {
                    val records = report.measurements.filter { selected[it.id] == true }.map { m ->
                        val raw = dates[m.id].orEmpty().trim()
                        val date = if (raw.length == 10) LocalDate.parse(raw).atStartOfDay() else LocalDateTime.parse(raw.replace(' ', 'T'))
                        require(date <= LocalDateTime.now().plusMinutes(5)) { "测量日期不能在未来" }; m.copy(date = date)
                    }
                    require(records.isNotEmpty()) { "请至少勾选一次测量" }; onSave(records)
                }.onFailure { error = it.message ?: "日期无效" }
            }, enabled = !busy, modifier = Modifier.fillMaxWidth()) { Text(L("导入选中的测量", "Import selected measurements")) }
            Spacer(Modifier.height(24.dp))
        }
    }
}
