package com.lodo.app.ui.health

import android.app.Application
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.lodo.app.LodoApp
import com.lodo.app.ai.AgentFocus
import com.lodo.app.ai.AgentPageFocus
import com.lodo.app.core.*
import com.lodo.app.data.*
import com.lodo.app.ui.*
import com.lodo.app.ui.countdown.SwitchRow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.LocalDateTime

class HealthJournalViewModel(application: Application) : AndroidViewModel(application) {
    val app = application as LodoApp
    val journal get() = app.healthJournal
    val weights = journal.dao.observeWeights().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val foods = journal.dao.observeFoods().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val medications = journal.dao.observeMedications().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val doses = journal.dao.observeDoses().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val periods = journal.dao.observePeriods().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val flows = journal.dao.observeFlows().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val profiles = journal.dao.observeProfiles().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val checkups = journal.dao.observeCheckups().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val memories = app.memoryRepository.observeAll().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val busy = MutableStateFlow(false)
    val error = MutableStateFlow<String?>(null)
    fun runAction(block: suspend () -> Unit) = viewModelScope.launch {
        if (busy.value) return@launch
        busy.value = true; error.value = null
        try { block() } catch (e: CancellationException) { throw e } catch (e: Exception) { error.value = e.message ?: "操作失败" }
        finally { busy.value = false }
    }
    suspend fun saveNote(text: String) { app.memoryRepository.saveText(app.settings.aiConfig(), text, listOf(MemoryEntity.healthTagName)) }
}

/** 手记为首页主体,健康连接仅为补充数据源,关闭授权不能把手记功能整页挡住。 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun HealthScreen(vm: HealthViewModel = viewModel(), journalVm: HealthJournalViewModel = viewModel()) {
    val j = journalVm.journal
    val weights by journalVm.weights.collectAsStateWithLifecycle()
    val foods by journalVm.foods.collectAsStateWithLifecycle()
    val meds by journalVm.medications.collectAsStateWithLifecycle()
    val doses by journalVm.doses.collectAsStateWithLifecycle()
    val periods by journalVm.periods.collectAsStateWithLifecycle()
    val flows by journalVm.flows.collectAsStateWithLifecycle()
    val profiles by journalVm.profiles.collectAsStateWithLifecycle()
    val memories by journalVm.memories.collectAsStateWithLifecycle()
    val revision by j.settingsRevision.collectAsStateWithLifecycle()
    val diet by j.dietPlan.collectAsStateWithLifecycle()
    val planning by j.planning.collectAsStateWithLifecycle()
    val busy by journalVm.busy.collectAsStateWithLifecycle()
    val error by journalVm.error.collectAsStateWithLifecycle()
    val settings = LocalSettings.current
    var page by rememberSaveable { mutableStateOf("home") }
    var editor by remember { mutableStateOf<HealthEditor?>(null) }
    var menu by remember { mutableStateOf(false) }
    var deleteAction by remember { mutableStateOf<(() -> Unit)?>(null) }
    var deleteWarning by remember { mutableStateOf<String?>(null) }
    var earlyDose by remember { mutableStateOf<MedicationPlan.Slot?>(null) }
    var now by remember { mutableStateOf(LocalDateTime.now()) }
    LaunchedEffect(Unit) { while (true) { now = LocalDateTime.now(); delay(30000) } }
    LaunchedEffect(settings.healthEnabled) { if (settings.healthEnabled) vm.load() }
    // revision 是偏好变化的失效信号(记录本身走 Room Flow)。
    val goal = remember(revision) { j.weightGoal }
    val medicationVisible = remember(revision) { j.medicationVisible }
    val cycleEnabled = remember(revision) { j.cycleEnabled }
    val entries = WeightPlan.merge(weights.map { it.entry() }, vm.report?.series(HealthMetricKind.BODY_MASS)?.points.orEmpty())
    val currentWeight = WeightPlan.latestWeight(entries)?.weightKg
    val today = now.toLocalDate()
    val todayFoods = foods.filter { it.dateMillis.toLocalDateTime().toLocalDate() == today }
    val intake = todayFoods.fold(Nutrition()) { a, food -> a + food.nutrition }
    val slots = MedicationPlan.todaySlots(meds.map { it.entry() }, doses.map { it.entry() }, now)
    val prediction = remember(periods, today, revision) { CyclePrediction.predict(CyclePlan.merge(periods.map { it.entry() }, emptyList(), today), today, j.confirmations()) }
    val flowByDay = CycleFlow.resolve(flows.map { it.entry() }, emptyList())
    fun recordDose(slot: MedicationPlan.Slot) {
        if (MedicationPlan.isEarly(slot, LocalDateTime.now())) earlyDose = slot
        else journalVm.runAction { j.logNextDose(slot.medicationId, slot.time) }
    }
    if (page == "data") { HealthDataScreen(vm, onBack = { page = "home" }); return }
    if (page == "checkups") { CheckupArchiveScreen(journalVm, onBack = { page = "home" }); return }
    val heading = when (page) {
        "weight" -> L("体重与饮食", "Weight & food")
        "medication" -> L("用药管理", "Medications")
        "cycle" -> L("经期", "Cycle")
        "checkups" -> L("体检档案", "Checkups")
        "profiles" -> L("家人档案", "Family profiles")
        "body" -> L("身体档案", "Body records")
        "notes" -> L("健康记录", "Health notes")
        else -> L("健康", "Health")
    }
    val actions: @Composable RowScope.() -> Unit = {
        Box {
            IconButton(onClick = { menu = true }) { Icon(Icons.Filled.Add, L("添加", "Add")) }
            DropdownMenu(menu, { menu = false }) {
                fun choose(value: HealthEditor) { menu = false; editor = value }
                DropdownMenuItem(text = { Text(L("记体重", "Record weight")) }, onClick = { choose(HealthEditor.Weight()) })
                DropdownMenuItem(text = { Text(L("记饮食", "Record food")) }, onClick = { choose(HealthEditor.Food) })
                DropdownMenuItem(text = { Text(L("添加药品", "Add medication")) }, onClick = { choose(HealthEditor.Medication()) })
                DropdownMenuItem(text = { Text(L("记录服药", "Record medication dose")) }, onClick = { choose(HealthEditor.Dose()) })
                DropdownMenuItem(text = { Text(L("记一笔健康资料", "Health note")) }, onClick = { choose(HealthEditor.Note) })
                DropdownMenuItem(text = { Text(L("记录经期", "Record period")) }, onClick = { choose(HealthEditor.Period()) })
                DropdownMenuItem(text = { Text(L("添加家人档案", "Add family profile")) }, onClick = { choose(HealthEditor.Profile()) })
                DropdownMenuItem(text = { Text(L("添加体检指标", "Add checkup item")) }, onClick = { choose(HealthEditor.Checkup()) })
            }
        }
    }
    val content: @Composable (PaddingValues) -> Unit = { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (busy) item("busy") { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            error?.let { message -> item("error") { TextButton(onClick = { journalVm.error.value = null }) { Text(message, color = MaterialTheme.colorScheme.error) } } }
            if (page == "home") {
                item("today") {
                    HealthGroup(L("今天", "Today")) {
                        Text(listOfNotNull(currentWeight?.let { "${WeightPlan.format(it)} kg" }, if (todayFoods.isNotEmpty()) "${WeightPlan.format(intake.calories)} kcal" else null,
                            vm.report?.latest(HealthMetricKind.STEPS)?.let { "${WeightPlan.format(it)} 步" }).joinToString(" · ").ifBlank { L("从记下一笔开始", "Start with a record") })
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { editor = HealthEditor.Weight() }) { Text(L("记体重", "Record weight")) }
                            OutlinedButton(onClick = { editor = HealthEditor.Food }) { Text(L("记饮食", "Record food")) }
                        }
                        if (medicationVisible) for (med in meds.filterNot { it.archived }) {
                            MedicationPlan.nextUnrecordedSlot(med.uuid, slots)?.let { slot ->
                                Text("${slot.name} ${slot.dosage} · ${slot.time.toLocalTime()}")
                                Button(onClick = { recordDose(slot) }, modifier = Modifier.fillMaxWidth(), enabled = !busy) { Text(L("记录已服用", "Record as taken")) }
                            }
                        }
                    }
                }
                item("environment") { HealthGroup(L("天气与空气质量", "Weather & air quality")) { EnvironmentPanel(journalVm) } }
                item("management") { HealthGroup(L("健康管理", "Health management")) {
                    HealthLink(L("体重与饮食", "Weight & food")) { page = "weight" }
                    if (medicationVisible) HealthLink(L("用药管理", "Medications")) { page = "medication" }
                    else TextButton(onClick = { j.setMedicationVisible(true) }) { Text(L("显示用药管理", "Show medications")) }
                    HealthLink(if (cycleEnabled) cycleCaption(prediction) else L("经期 · 未开启", "Cycle · off")) { page = "cycle" }
                } }
                item("data") { HealthGroup(L("健康数据", "Health data")) { HealthLink(L("指标与趋势", "Metrics & trends")) { page = "data" } } }
                item("library") { HealthGroup(L("健康资料", "Health library")) {
                    HealthLink(L("体检档案", "Checkups")) { page = "checkups" }
                    HealthLink(L("身体档案", "Body records")) { page = "body" }
                    HealthLink(L("健康记录", "Health notes")) { page = "notes" }
                    HealthLink(L("家人档案", "Family profiles")) { page = "profiles" }
                } }
                item("analysis") { HealthAnalysisCard(vm) }
            }
            if (page == "weight" || page == "body") {
                item("weight-summary") { HealthGroup(L("体重与饮食", "Weight & food")) {
                    Text(currentWeight?.let { "${WeightPlan.format(it)} kg" } ?: L("还没有体重记录", "No weight records"), style = MaterialTheme.typography.headlineMedium)
                    WeightPlan.bmi(currentWeight, goal.heightCm)?.let { Text("BMI ${WeightPlan.format(it)}") }
                    goal.targetWeightKg?.let { Text(L("目标 ", "Target ") + "${WeightPlan.format(it)} kg") }
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = { editor = HealthEditor.Goal }) { Text(L("设置目标", "Set goal")) }
                        TextButton(onClick = { editor = HealthEditor.Weight() }) { Text(L("记体重", "Record weight")) }
                        TextButton(onClick = { editor = HealthEditor.Food }) { Text(L("记饮食", "Record food")) }
                    }
                } }
                if (page == "weight") {
                    item("diet") { HealthGroup(L("饮食安排", "Meal plan")) {
                        Text(L("今天已估算摄入 ", "Estimated intake today: ") + "${WeightPlan.format(intake.calories)} kcal")
                        if (todayFoods.any { !it.estimated }) Text(L("合计不含尚未估算的记录", "Totals exclude records not yet estimated"))
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { journalVm.runAction { j.planDiet(today, vm.report) } }, enabled = !planning) { Text(L("安排今天", "Plan today")) }
                            OutlinedButton(onClick = { journalVm.runAction { j.planDiet(today.plusDays(1), vm.report) } }, enabled = !planning) { Text(L("安排明天", "Plan tomorrow")) }
                        }
                        if (planning) LinearProgressIndicator(Modifier.fillMaxWidth())
                        diet?.let { plan ->
                            Text("${plan.day} · ${plan.advice}")
                            for (meal in plan.meals) {
                                Text("${meal.time} ${meal.taskTitle}" + meal.calories?.let { " · $it kcal" }.orEmpty())
                                TextButton(onClick = { journalVm.runAction { j.toggleMealTask(meal.id) } }) { Text(if (meal.taskUuid == null) L("加入任务", "Add task") else L("撤掉任务", "Remove task")) }
                            }
                        }
                    } }
                    items(foods, key = { "food-${it.uuid}" }) { food ->
                        HealthGroup(food.dateMillis.toLocalDateTime().toString().replace('T', ' ')) {
                            Text(food.text)
                            if (food.estimated) Text("${WeightPlan.format(food.calories)} kcal · P ${WeightPlan.format(food.proteinG)}g / F ${WeightPlan.format(food.fatG)}g / C ${WeightPlan.format(food.carbsG)}g")
                            else TextButton(onClick = { journalVm.runAction { j.estimateFood(food.uuid) } }) { Text(L("重新估算", "Retry estimate")) }
                            TextButton(onClick = { deleteAction = { journalVm.runAction { j.dao.deleteFood(food.uuid) } } }) { Text(L("删除", "Delete")) }
                        }
                    }
                }
                if (page == "body") item("body-import") { BodyReportImport(journalVm) }
                items(weights.asReversed(), key = { "weight-${it.uuid}" }) { record ->
                    HealthGroup(record.dateMillis.toLocalDateTime().toLocalDate().toString()) {
                        Text(listOfNotNull(record.weightKg?.let { "${WeightPlan.format(it)} kg" }, record.bodyFatPercent?.let { "${WeightPlan.format(it)}%" }).joinToString(" · "))
                        listOfNotNull(record.muscleMassKg?.let { "肌肉量 $it kg" }, record.visceralFatLevel?.let { "内脏脂肪 $it" }, record.basalMetabolicKcal?.let { "基础代谢 $it kcal" }, record.bodyWaterPercent?.let { "水分 $it%" }, record.boneMassKg?.let { "骨量 $it kg" }).forEach { Text(it) }
                        if (record.note.isNotBlank()) Text(record.note)
                        Row { TextButton(onClick = { editor = HealthEditor.Weight(record) }) { Text(L("编辑", "Edit")) }
                            TextButton(onClick = { deleteAction = { journalVm.runAction { j.dao.deleteWeight(record.uuid) } } }) { Text(L("删除", "Delete")) } }
                    }
                }
            }
            if (page == "medication") {
                item("medication-option") { SwitchRow(L("显示用药管理", "Show medications"), medicationVisible, subtitle = L("只隐藏界面,提醒仍会响", "Hides the section only; reminders continue")) { j.setMedicationVisible(it) } }
                items(meds, key = { "med-${it.uuid}" }) { med ->
                    HealthGroup(med.name + if (med.archived) L(" · 已停用", " · archived") else "") {
                        Text("${med.dosage} · ${med.times}")
                        if (!med.archived && med.times.isBlank()) TextButton(onClick = { editor = HealthEditor.Dose(med) }) { Text(L("记录已服用", "Record as taken")) }
                        MedicationPlan.nextUnrecordedSlot(med.uuid, slots)?.let { slot ->
                            Text(slot.time.toLocalTime().toString())
                            Button(onClick = { recordDose(slot) }, modifier = Modifier.fillMaxWidth(), enabled = !busy) { Text(L("记录已服用", "Record as taken")) }
                            TextButton(onClick = { journalVm.runAction { j.logNextDose(med.uuid, slot.time, "skipped") } }) { Text(L("跳过这一顿", "Skip dose")) }
                        }
                        Row { TextButton(onClick = { editor = HealthEditor.Medication(med) }) { Text(L("编辑", "Edit")) }
                            TextButton(onClick = { deleteAction = { journalVm.runAction { j.deleteMedication(med.uuid) } } }) { Text(L("删除", "Delete")) } }
                    }
                }
                items(doses.take(200), key = { "dose-${it.uuid}" }) { dose -> HealthGroup(dose.name) {
                    Text("${dose.takenAtMillis.toLocalDateTime()} · ${if (dose.status == "taken") L("已服用", "Taken") else L("已跳过", "Skipped")}")
                    TextButton(onClick = { editor = HealthEditor.Dose(record = dose) }) { Text(L("编辑", "Edit")) }
                    TextButton(onClick = { deleteAction = { journalVm.runAction { j.dao.deleteDose(dose.uuid) } } }) { Text(L("删除记录", "Delete record")) }
                } }
            }
            if (page == "cycle") {
                item("cycle-options") { SwitchRow(L("经期记录", "Cycle tracking"), cycleEnabled) { j.setCycleEnabled(it) } }
                if (cycleEnabled) {
                    item("cycle-reminder") { SwitchRow(L("经期提醒", "Cycle reminder"), j.cycleReminderEnabled, subtitle = L("依据充足时,预计范围前两天提醒", "Reminds two days before the range when there is sufficient evidence")) { j.setCycleReminder(it) } }
                    item("cycle-current") { HealthGroup(cycleCaption(prediction)) {
                        prediction.currentEnd?.let { Text(L("预计结束 ", "Expected end ") + "${it.lower} — ${it.upper}") }
                        prediction.nextStart?.let { Text(L("预计下次开始 ", "Next start ") + "${it.lower} — ${it.upper}") }
                        Text(L("依据 ${prediction.validCycles} 个有效周期;仅供记录,不能用于避孕。", "Based on ${prediction.validCycles} cycles; not for contraception."))
                        if (prediction.startRevised || prediction.endRevised) Text(L("已根据你的确认重新估计", "Revised using your confirmation"))
                        if (prediction.phase in setOf(CyclePrediction.Phase.IN_WINDOW, CyclePrediction.Phase.LATE)) TextButton(onClick = { j.confirmCycle(false, today) }) { Text(L("今天还没来", "Not started today")) }
                        if (prediction.currentEnd?.lower?.let { today >= it } == true) TextButton(onClick = { j.confirmCycle(true, today) }) { Text(L("今天还没结束", "Still ongoing today")) }
                        if (j.confirmations().notStartedThrough == today || j.confirmations().ongoingThrough == today) TextButton(onClick = { j.confirmCycle(false, null); j.confirmCycle(true, null) }) { Text(L("撤销今天的确认", "Undo today's confirmation")) }
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { journalVm.runAction { j.startPeriod(today) } }) { Text(L("经期开始了", "Period started")) }
                            periods.lastOrNull { it.startDay <= today.toString() && it.endDay == null }?.let { p -> OutlinedButton(onClick = { journalVm.runAction { j.endPeriod(p.uuid, today) } }) { Text(L("经期结束了", "Period ended")) } }
                        }
                        Text(L("今天出血量: ", "Today's flow: ") + flowLabel(flowByDay[today.toString()]?.level))
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) { CycleFlowLevel.selectable.forEach { level ->
                            FilterChip(flowByDay[today.toString()]?.level == level, { journalVm.runAction { j.saveFlow(today, level) } }, label = { Text(flowLabel(level)) })
                        } }
                        TextButton(onClick = { editor = HealthEditor.Flow() }) { Text(L("补记出血量", "Record past flow")) }
                        TextButton(onClick = { journalVm.runAction { j.saveFlow(today, null) } }) { Text(L("清除今天的出血量", "Clear today's flow")) }
                    } }
                    items(periods.asReversed(), key = { "period-${it.uuid}" }) { p -> HealthGroup("${p.startDay} — ${p.endDay ?: L("结束待确认", "End unconfirmed")}") {
                        Row { TextButton(onClick = { editor = HealthEditor.Period(p) }) { Text(L("编辑", "Edit")) }
                            TextButton(onClick = { deleteAction = { journalVm.runAction { j.dao.deletePeriod(p.uuid) } } }) { Text(L("删除", "Delete")) } }
                    } }
                    items(flowByDay.entries.sortedByDescending { it.key }, key = { "flow-${it.key}" }) { (day, flow) -> Text("$day · ${flowLabel(flow.level)}") }
                }
            }
            if (page == "profiles") {
                item("self") { Text(L("本人无需新建档案;家人的数据不会参与本人的 AI 健康分析。", "Your profile is implicit. Family records are excluded from your AI health analysis.")) }
                items(profiles, key = { "profile-${it.uuid}" }) { profile -> HealthGroup("${profile.name} · ${profile.relation}") {
                    Text(profile.notes)
                    TextButton(onClick = { editor = HealthEditor.Profile(profile) }) { Text(L("编辑", "Edit")) }
                    TextButton(onClick = { deleteWarning = L("这位家人的全部体检报告、检查项和原文件都会删除。", "All of this person's reports, items and original files will be deleted."); deleteAction = { journalVm.runAction {
                        journalVm.app.checkups.deleteProfile(profile.uuid)
                    } } }) { Text(L("删除", "Delete")) }
                } }
            }
            if (page == "notes") items(memories.filter { MemoryEntity.healthTagName in it.tagsList }, key = { "note-${it.uuid}" }) { note -> HealthGroup(note.title) {
                Text(note.summary); Text(note.sourceText)
                TextButton(onClick = { deleteAction = { journalVm.runAction { journalVm.app.memoryRepository.delete(note.uuid) } } }) { Text(L("删除", "Delete")) }
            } }
            if (page != "home") item("add-record") { OutlinedButton(onClick = { editor = when (page) {
                "weight", "body" -> HealthEditor.Weight()
                "medication" -> HealthEditor.Medication()
                "cycle" -> HealthEditor.Period()
                "profiles" -> HealthEditor.Profile()
                "checkups" -> HealthEditor.Checkup()
                else -> HealthEditor.Note
            } }, modifier = Modifier.fillMaxWidth()) { Text(L("添加记录", "Add record")) } }
        }
    }
    if (page == "home") LodoPage(heading, AgentFocus(AgentPageFocus.HEALTH), actions = actions, content = content)
    else LodoSubPage(heading, { page = "home" }, focus = AgentFocus(AgentPageFocus.HEALTH), actions = actions, content = content)
    editor?.let { value -> HealthEditorSheet(value, journalVm) { editor = null } }
    earlyDose?.let { slot -> AlertDialog(onDismissRequest = { earlyDose = null }, title = { Text(L("现在记录已服用?", "Record this dose now?")) },
        text = { Text(L("距离 ${slot.name} ${slot.time.toLocalTime()} 这一顿还超过一小时。", "This dose is more than an hour away.")) },
        confirmButton = { TextButton(onClick = { earlyDose = null; journalVm.runAction { j.logNextDose(slot.medicationId, slot.time) } }) { Text(L("记录已服用", "Record as taken")) } },
        dismissButton = { TextButton(onClick = { earlyDose = null }) { Text(L("取消", "Cancel")) } }) }
    deleteAction?.let { action -> AlertDialog(onDismissRequest = { deleteAction = null; deleteWarning = null }, title = { Text(L("删除这条记录?", "Delete this record?")) },
        text = { deleteWarning?.let { Text(it) } },
        confirmButton = { TextButton(onClick = { deleteAction = null; deleteWarning = null; action() }) { Text(L("删除", "Delete")) } }, dismissButton = { TextButton(onClick = { deleteAction = null; deleteWarning = null }) { Text(L("取消", "Cancel")) } }) }
}

@Composable
internal fun HealthGroup(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium); content()
        }
    }
}
@Composable private fun HealthLink(title: String, onClick: () -> Unit) { TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth()) { Text(title, modifier = Modifier.fillMaxWidth()) } }
fun cycleCaption(result: CyclePrediction.Result): String = when (result.phase) {
    CyclePrediction.Phase.NO_RECORDS -> L("还没有经期记录", "No period records")
    CyclePrediction.Phase.IN_PERIOD -> L("经期第 ${result.day} 天", "Period day ${result.day}")
    CyclePrediction.Phase.END_UNCONFIRMED -> L("结束日期待确认", "End date unconfirmed")
    CyclePrediction.Phase.INSUFFICIENT -> L("记录不足,暂不预测", "Not enough records to predict")
    CyclePrediction.Phase.BEFORE -> L("距预计开始 ${result.daysUntilStart} 天", "${result.daysUntilStart} days to expected start")
    CyclePrediction.Phase.IN_WINDOW -> L("可能这几天到来", "May start in these days")
    CyclePrediction.Phase.LATE -> L("超出预计范围 ${result.lateDays} 天", "${result.lateDays} days beyond the expected range")
}

@Composable internal fun HealthAnalysisCard(vm: HealthViewModel) {
    HealthGroup(L("AI 健康分析", "AI health analysis")) {
        Text(L("只发送本人汇总与健康资料,不发送家人档案。", "Only your summaries and notes are sent, not family records."), style = MaterialTheme.typography.bodySmall)
        if (vm.analyzing) CircularProgressIndicator(Modifier.size(24.dp))
        else Button(onClick = vm::analyze) { Text(L("分析", "Analyze")) }
        vm.analysis?.let { a -> Text(a.analysis); a.suggestions.forEach { Text("• $it") } }
        vm.error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
    }
}
