package com.lodo.app.ui.health

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.lodo.app.core.*
import com.lodo.app.data.*
import com.lodo.app.ui.L
import com.lodo.app.ui.countdown.SwitchRow
import java.time.LocalDate
import java.time.LocalDateTime
import java.util.UUID

sealed interface HealthEditor {
    data class Weight(val record: WeightRecordEntity? = null) : HealthEditor
    data object Food : HealthEditor
    data object Goal : HealthEditor
    data class Medication(val record: MedicationEntity? = null) : HealthEditor
    data class Dose(val med: MedicationEntity? = null, val record: MedicationDoseEntity? = null) : HealthEditor
    data class Period(val record: PeriodRecordEntity? = null) : HealthEditor
    data class Flow(val day: LocalDate = LocalDate.now()) : HealthEditor
    data class Profile(val record: HealthProfileEntity? = null) : HealthEditor
    data class Checkup(val record: CheckupEntryEntity? = null) : HealthEditor
    data object Note : HealthEditor
}

/** 每种表单只写结构化记录;保存失败保留表单内容,由上层显示错误。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun HealthEditorSheet(editor: HealthEditor, vm: HealthJournalViewModel, onDismiss: () -> Unit) {
    val weight = (editor as? HealthEditor.Weight)?.record
    val dose = (editor as? HealthEditor.Dose)?.record
    val doseMed = (editor as? HealthEditor.Dose)?.med
    val med = (editor as? HealthEditor.Medication)?.record
    val period = (editor as? HealthEditor.Period)?.record
    val profile = (editor as? HealthEditor.Profile)?.record
    val checkup = (editor as? HealthEditor.Checkup)?.record
    var title by remember { mutableStateOf(dose?.name ?: doseMed?.name ?: med?.name ?: profile?.name ?: checkup?.name ?: "") }
    var note by remember { mutableStateOf(dose?.note ?: weight?.note ?: med?.note ?: period?.note ?: profile?.notes ?: checkup?.advice ?: "") }
    var date by remember { mutableStateOf(weight?.dateMillis?.toLocalDateTime()?.toLocalDate()?.toString() ?: period?.startDay ?: checkup?.dateDay ?: LocalDate.now().toString()) }
    var end by remember { mutableStateOf(period?.endDay ?: "") }
    var kg by remember { mutableStateOf(weight?.weightKg?.toString() ?: "") }
    var fat by remember { mutableStateOf(weight?.bodyFatPercent?.toString() ?: "") }
    var dosage by remember { mutableStateOf(dose?.dosage ?: doseMed?.dosage ?: med?.dosage ?: profile?.relation ?: checkup?.value ?: "") }
    var times by remember { mutableStateOf(med?.times ?: "") }
    var days by remember { mutableStateOf(med?.entry()?.days.orEmpty().toSet()) }
    var remind by remember { mutableStateOf(med?.reminderEnabled ?: false) }
    var archived by remember { mutableStateOf(med?.archived ?: false) }
    var height by remember { mutableStateOf(vm.journal.weightGoal.heightCm?.toString() ?: "") }
    var target by remember { mutableStateOf(vm.journal.weightGoal.targetWeightKg?.toString() ?: "") }
    var targetFat by remember { mutableStateOf(vm.journal.weightGoal.targetBodyFatPercent?.toString() ?: "") }
    var unit by remember { mutableStateOf(checkup?.unit ?: "") }
    var reference by remember { mutableStateOf(checkup?.referenceRange ?: "") }
    var flag by remember { mutableStateOf(checkup?.flag ?: "") }
    var profileId by remember { mutableStateOf(checkup?.profileUuid) }
    var category by remember { mutableStateOf(checkup?.category.orEmpty()) }
    var conclusion by remember { mutableStateOf(checkup?.conclusion.orEmpty()) }
    var birthday by remember { mutableStateOf(profile?.birthday.orEmpty()) }
    var takenTime by remember { mutableStateOf((dose?.takenAtMillis?.toLocalDateTime() ?: LocalDateTime.now()).withSecond(0).withNano(0).toString().replace('T', ' ')) }
    var doseState by remember { mutableStateOf(dose?.status ?: "taken") }
    val profiles by vm.profiles.collectAsState()
    val busy by vm.busy.collectAsState()
    val error by vm.error.collectAsState()
    val heading = when (editor) {
        is HealthEditor.Weight -> L("记体重", "Record weight")
        HealthEditor.Food -> L("记饮食", "Record food")
        HealthEditor.Goal -> L("体重目标", "Weight goal")
        is HealthEditor.Medication -> L("药品资料", "Medication")
        is HealthEditor.Dose -> L("记录服药", "Record medication dose")
        is HealthEditor.Period -> L("记录经期", "Record period")
        is HealthEditor.Flow -> L("补记出血量", "Record flow")
        is HealthEditor.Profile -> L("家人档案", "Family profile")
        is HealthEditor.Checkup -> L("体检指标", "Checkup item")
        HealthEditor.Note -> L("记一笔健康资料", "Health note")
    }
    fun nullableNumber(s: String): Double? { if (s.isBlank()) return null; return s.toDouble().also { require(it.isFinite()) { "请输入有效数字" } } }
    fun save() = vm.runAction {
        when (editor) {
            is HealthEditor.Weight -> {
                val day = LocalDate.parse(date)
                vm.journal.saveWeight((weight ?: WeightRecordEntity()).copy(dateMillis = if (weight != null && day == weight.dateMillis.toLocalDateTime().toLocalDate()) weight.dateMillis else day.atStartOfDay().toEpochMillis(),
                    weightKg = nullableNumber(kg), bodyFatPercent = nullableNumber(fat), note = note))
            }
            HealthEditor.Food -> vm.journal.saveFood(note, LocalDate.parse(date).atTime(LocalDateTime.now().toLocalTime()))
            HealthEditor.Goal -> vm.journal.saveGoal(WeightGoal(nullableNumber(height), nullableNumber(target), nullableNumber(targetFat)))
            is HealthEditor.Medication -> vm.journal.saveMedication((med ?: MedicationEntity(name = title)).copy(name = title.trim(), dosage = dosage.trim(), note = note,
                times = times.replace('，', ',').replace('、', ','), days = joinIntCsv(days.sorted()), reminderEnabled = remind, archived = archived))
            is HealthEditor.Dose -> {
                require(title.isNotBlank()) { "请填写药名" }
                val time = LocalDateTime.parse(takenTime.trim().replace(' ', 'T'))
                require(time <= LocalDateTime.now()) { "服药时间不能在未来" }
                vm.journal.dao.saveDose((dose ?: MedicationDoseEntity(medicationUuid = doseMed?.uuid, name = title)).copy(name = title.trim(), dosage = dosage.trim(), takenAtMillis = time.toEpochMillis(), status = doseState, note = note))
            }
            is HealthEditor.Period -> {
                val start = LocalDate.parse(date); val finish = end.takeIf { it.isNotBlank() }?.let(LocalDate::parse)
                require(start <= LocalDate.now() && (finish == null || finish in start..LocalDate.now())) { "经期日期无效" }
                val existing = vm.journal.dao.periods().firstOrNull { it.uuid != period?.uuid && it.startDay == date }
                require(existing == null) { "这一天已记录过开始" }
                vm.journal.dao.savePeriod((period ?: PeriodRecordEntity(startDay = date)).copy(startDay = date, endDay = end.takeIf { it.isNotBlank() }, note = note))
            }
            is HealthEditor.Profile -> {
                require(title.isNotBlank()) { "请填写姓名" }
                val birth = birthday.takeIf { it.isNotBlank() }?.let(LocalDate::parse)
                require(birth == null || birth <= LocalDate.now()) { "出生日期不能在未来" }
                vm.journal.dao.saveProfile((profile ?: HealthProfileEntity(name = title)).copy(name = title.trim(), relation = dosage.trim(), birthday = birth?.toString(), notes = note))
            }
            is HealthEditor.Checkup -> {
                require(checkup?.kind in setOf("advice", "summary") || title.isNotBlank()); LocalDate.parse(date)
                vm.app.checkups.saveEntry((checkup ?: CheckupEntryEntity(reportUuid = UUID.randomUUID().toString(), dateDay = date)).copy(name = title.trim(), value = dosage.trim(), unit = unit.trim(), referenceRange = reference.trim(),
                    flag = flag, advice = note, dateDay = date, profileUuid = profileId, category = category.trim(), conclusion = conclusion.trim()))
            }
            HealthEditor.Note -> { require(note.isNotBlank()); vm.saveNote(note) }
            is HealthEditor.Flow -> Unit
        }
        vm.error.value = null; onDismiss()
    }
    ModalBottomSheet(onDismissRequest = { if (!busy) onDismiss() }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding().padding(horizontal = 20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            com.lodo.app.ui.assets.SheetHeader(heading, !busy, onDismiss, { save() })
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (editor is HealthEditor.Weight || editor is HealthEditor.Period || editor is HealthEditor.Checkup || editor == HealthEditor.Food)
                OutlinedTextField(date, { date = it }, label = { Text(L("日期(YYYY-MM-DD)", "Date (YYYY-MM-DD)")) }, modifier = Modifier.fillMaxWidth(), singleLine = true, readOnly = checkup != null)
            when (editor) {
                is HealthEditor.Weight -> {
                    OutlinedTextField(kg, { kg = it }, label = { Text(L("体重(公斤)", "Weight (kg)")) }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                    OutlinedTextField(fat, { fat = it }, label = { Text(L("体脂率(%)", "Body fat (%)")) }, modifier = Modifier.fillMaxWidth(), singleLine = true)
                }
                HealthEditor.Goal -> {
                    OutlinedTextField(height, { height = it }, label = { Text(L("身高(厘米)", "Height (cm)")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(target, { target = it }, label = { Text(L("目标体重(公斤)", "Target weight (kg)")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(targetFat, { targetFat = it }, label = { Text(L("目标体脂率(%)", "Target body fat (%)")) }, modifier = Modifier.fillMaxWidth())
                }
                is HealthEditor.Medication -> {
                    OutlinedTextField(title, { title = it }, label = { Text(L("药名", "Medication name")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(dosage, { dosage = it }, label = { Text(L("每次用量", "Dosage")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(times, { times = it }, label = { Text(L("服药时间(HH:mm,多个用逗号分隔)", "Times (HH:mm, comma separated)")) }, modifier = Modifier.fillMaxWidth())
                    Text(L("不填时间 = 按需服用;不选周几 = 每天", "No time = as needed; no weekday = every day"), style = MaterialTheme.typography.bodySmall)
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) { weekdayNames.forEachIndexed { index, label ->
                        FilterChip(index in days, { days = if (index in days) days - index else days + index }, label = { Text(label) })
                    } }
                    SwitchRow(L("服药提醒", "Medication reminders"), remind) { remind = it }
                    SwitchRow(L("停用", "Archived"), archived) { archived = it }
                }
                is HealthEditor.Dose -> {
                    OutlinedTextField(title, { title = it }, label = { Text(L("药名", "Medication name")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(dosage, { dosage = it }, label = { Text(L("用量", "Dosage")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(takenTime, { takenTime = it }, label = { Text(L("服药时间(YYYY-MM-DD HH:mm)", "Time (YYYY-MM-DD HH:mm)")) }, modifier = Modifier.fillMaxWidth())
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        FilterChip(doseState == "taken", { doseState = "taken" }, label = { Text(L("已服用", "Taken")) })
                        FilterChip(doseState == "skipped", { doseState = "skipped" }, label = { Text(L("已跳过", "Skipped")) })
                    }
                }
                is HealthEditor.Period -> OutlinedTextField(end, { end = it }, label = { Text(L("结束日期(可选,YYYY-MM-DD)", "End date (optional)")) }, modifier = Modifier.fillMaxWidth())
                is HealthEditor.Profile -> {
                    OutlinedTextField(title, { title = it }, label = { Text(L("姓名", "Name")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(dosage, { dosage = it }, label = { Text(L("关系", "Relation")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(birthday, { birthday = it }, label = { Text(L("出生日期(可选,YYYY-MM-DD)", "Birthday (optional, YYYY-MM-DD)")) }, modifier = Modifier.fillMaxWidth())
                }
                is HealthEditor.Checkup -> {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        FilterChip(profileId == null, { profileId = null }, enabled = checkup == null, label = { Text(L("本人", "Me")) })
                        profiles.forEach { p -> FilterChip(profileId == p.uuid, { profileId = p.uuid }, enabled = checkup == null, label = { Text(p.name) }) }
                    }
                    OutlinedTextField(category, { category = it }, label = { Text(L("分类/科室", "Category")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(title, { title = it }, label = { Text(L("指标名称", "Item name")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(conclusion, { conclusion = it }, label = { Text(L("结论/描述", "Conclusion")) }, minLines = 2, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(dosage, { dosage = it }, label = { Text(L("结果", "Result")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(unit, { unit = it }, label = { Text(L("单位", "Unit")) }, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(reference, { reference = it }, label = { Text(L("参考范围", "Reference range")) }, modifier = Modifier.fillMaxWidth())
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) { listOf("" to "未标", "normal" to "正常", "high" to "偏高", "low" to "偏低", "abnormal" to "异常").forEach { (raw, label) ->
                        FilterChip(flag == raw, { flag = raw }, label = { Text(label) })
                    } }
                }
                is HealthEditor.Flow -> {
                    OutlinedTextField(date, { date = it }, label = { Text(L("日期(YYYY-MM-DD)", "Date (YYYY-MM-DD)")) }, modifier = Modifier.fillMaxWidth())
                    CycleFlowLevel.selectable.forEach { level -> TextButton(onClick = { vm.runAction { vm.journal.saveFlow(LocalDate.parse(date), level); onDismiss() } }) { Text(flowLabel(level)) } }
                }
                else -> Unit
            }
            if (editor !is HealthEditor.Flow && editor != HealthEditor.Goal) OutlinedTextField(note, { note = it },
                label = { Text(if (editor == HealthEditor.Food) L("吃了什么", "What did you eat?") else L("备注", "Notes")) }, minLines = 2, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(24.dp))
        }
    }
}
fun flowLabel(level: CycleFlowLevel?) = when (level) {
    CycleFlowLevel.NONE -> L("无", "None")
    CycleFlowLevel.LIGHT -> L("少", "Light")
    CycleFlowLevel.MEDIUM -> L("中", "Medium")
    CycleFlowLevel.HEAVY -> L("多", "Heavy")
    CycleFlowLevel.UNSPECIFIED -> L("有出血,未分档", "Bleeding, unspecified")
    null -> L("未记", "Not recorded")
}
