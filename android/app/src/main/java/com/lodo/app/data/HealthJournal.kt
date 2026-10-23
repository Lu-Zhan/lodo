package com.lodo.app.data

import android.content.Context
import androidx.room.withTransaction
import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalDateTime

/** 健康手记不依赖 Health Connect 授权;所有入口共享同一个进程级协调器。 */
class HealthJournal(private val app: com.lodo.app.LodoApp) {
    val dao get() = app.database.healthDao()
    private val prefs = app.getSharedPreferences("health-journal", Context.MODE_PRIVATE)
    private val medicationMutex = Mutex()
    private val cycleMutex = Mutex()
    private val dietMutex = Mutex()
    val settingsRevision = MutableStateFlow(0)
    val dietPlan = MutableStateFlow(decodeDiet(prefs.getString("diet", "").orEmpty()))
    val planning = MutableStateFlow(false)
    val medicationVisible get() = prefs.getBoolean("medicationVisible", true)
    val cycleEnabled get() = prefs.getBoolean("cycleEnabled", false)
    val cycleReminderEnabled get() = prefs.getBoolean("cycleReminderEnabled", true)
    val weightGoal: WeightGoal get() {
        val json = runCatching { JSONObject(prefs.getString("weightGoal", "").orEmpty()) }.getOrNull() ?: return WeightGoal()
        return WeightGoal(json.dbl("heightCm"), json.dbl("targetWeightKg"), json.dbl("targetBodyFatPercent"))
    }
    fun setMedicationVisible(value: Boolean) { prefs.edit().putBoolean("medicationVisible", value).apply(); settingsRevision.value++ }
    fun setCycleEnabled(value: Boolean) { prefs.edit().putBoolean("cycleEnabled", value).apply(); settingsRevision.value++ }
    fun setCycleReminder(value: Boolean) { prefs.edit().putBoolean("cycleReminderEnabled", value).apply(); settingsRevision.value++ }
    fun saveGoal(goal: WeightGoal) {
        require(goal.heightCm == null || goal.heightCm.isFinite() && goal.heightCm in 50.0..250.0)
        require(goal.targetWeightKg == null || goal.targetWeightKg.isFinite() && goal.targetWeightKg in 20.0..500.0)
        require(goal.targetBodyFatPercent == null || goal.targetBodyFatPercent.isFinite() && goal.targetBodyFatPercent in 1.0..80.0)
        prefs.edit().putString("weightGoal", JSONObject().put("heightCm", goal.heightCm).put("targetWeightKg", goal.targetWeightKg)
            .put("targetBodyFatPercent", goal.targetBodyFatPercent).toString()).apply()
        settingsRevision.value++
    }
    suspend fun saveWeight(record: WeightRecordEntity) {
        require(record.dateMillis <= System.currentTimeMillis()) { "测量时间不能晚于现在" }
        require(record.weightKg != null || record.bodyFatPercent != null || record.muscleMassKg != null || record.boneMassKg != null) { "请填写测量数据" }
        require(record.weightKg == null || record.weightKg.isFinite() && record.weightKg in 20.0..500.0) { "体重超出范围" }
        require(record.bodyFatPercent == null || record.bodyFatPercent.isFinite() && record.bodyFatPercent in 1.0..80.0) { "体脂率超出范围" }
        dao.saveWeight(record)
    }
    suspend fun saveFood(text: String, date: LocalDateTime = LocalDateTime.now()): FoodRecordEntity {
        require(text.isNotBlank())
        val record = FoodRecordEntity(text = text.trim(), dateMillis = date.toEpochMillis())
        dao.saveFood(record) // 网络失败也留下原文。
        try { estimateFood(record.uuid) } catch (e: kotlinx.coroutines.CancellationException) { throw e }
        catch (_: Exception) { /* 原文已保存;界面显示未估算,单独重试不会重复建立饮食条目。 */ }
        return dao.food(record.uuid) ?: record
    }
    suspend fun estimateFood(id: String) {
        val before = dao.food(id) ?: return
        val estimate = DeepSeekClient.estimateNutrition(app.settings.aiConfig(), before.text)
        app.database.withTransaction {
            val current = dao.food(id) ?: return@withTransaction
            if (current.text != before.text) return@withTransaction
            val n = estimate.total
            dao.saveFood(current.copy(estimated = true, calories = n.calories, proteinG = n.proteinG, fatG = n.fatG, carbsG = n.carbsG,
                itemsData = JSONArray(estimate.items.map { item -> JSONObject().put("name", item.name).put("amount", item.amount)
                    .put("calories", item.nutrition.calories).put("protein", item.nutrition.proteinG).put("fat", item.nutrition.fatG).put("carbs", item.nutrition.carbsG) }).toString()))
        }
    }
    suspend fun planDiet(day: LocalDate, health: HealthReport?) {
        if (!dietMutex.tryLock()) return
        planning.value = true
        try {
            val now = LocalDateTime.now()
            val entries = WeightPlan.merge(dao.weights().map { it.entry() }, health?.series(HealthMetricKind.BODY_MASS)?.points.orEmpty())
            val summary = WeightPlan.promptSummary(entries, weightGoal, now) ?: "用户还没有记录体重或目标"
            val foods = dao.foods().filter { it.dateMillis.toLocalDateTime().toLocalDate() == now.toLocalDate() }
            val intake = foods.fold(Nutrition()) { a, item -> a + item.nutrition }
            val today = if (foods.isEmpty()) null else "今天已记录 ${foods.size} 次进食,其中 ${foods.count { !it.estimated }} 次还没估算;已估算摄入 ${WeightPlan.format(intake.calories)} 千卡(蛋白质 ${WeightPlan.format(intake.proteinG)} 克、脂肪 ${WeightPlan.format(intake.fatG)} 克、碳水 ${WeightPlan.format(intake.carbsG)} 克)"
            val config = app.settings.aiConfig()
            val plan = DeepSeekClient.weightPlan(config, summary, health?.promptSummary(), today, day, day == now.toLocalDate(), if (app.settings.snapshot().language == "en") "英文" else "中文")
            persistDiet(plan)
        } finally { planning.value = false; dietMutex.unlock() }
    }
    suspend fun toggleMealTask(mealId: String) = dietMutex.withLock {
        val plan = dietPlan.value ?: return@withLock
        val meal = plan.meals.firstOrNull { it.id == mealId } ?: return@withLock
        val taskId = meal.taskUuid
        val updated = if (taskId != null) {
            val task = app.repository.current(taskId)
            if (task?.statusEnum == TaskStatus.PENDING) app.repository.delete(taskId)
            meal.copy(taskUuid = null)
        } else {
            val task = app.repository.saveNew(ParsedTask(meal.taskTitle, plan.remindAt(meal, LocalDateTime.now()), false, 0, RepeatType.NONE, emptyList(), emptyList()))
            meal.copy(taskUuid = task.uuid)
        }
        persistDiet(plan.copy(meals = plan.meals.map { if (it.id == mealId) updated else it }))
    }
    private fun persistDiet(plan: WeightDietPlan) { prefs.edit().putString("diet", encodeDiet(plan).toString()).apply(); dietPlan.value = plan }

    suspend fun saveMedication(input: MedicationEntity) = medicationMutex.withLock {
        val med = input.copy(times = joinCsv(splitCsv(input.times).map { java.time.LocalTime.parse(it).toString().take(5) }.distinct().sorted()),
            days = joinIntCsv(splitIntCsv(input.days).filter { it in 0..6 }.distinct().sorted()))
        require(med.name.isNotBlank())
        val latest = dao.medication(med.uuid)
        val existing = (latest?.taskUuid ?: med.taskUuid)?.let { app.repository.current(it) }
        val next = if (med.reminderEnabled && !med.archived) MedicationPlan.nextDose(med.entry(), LocalDateTime.now()) else null
        var taskId: String? = null
        if (next == null) existing?.let { app.repository.delete(it.uuid) }
        else {
            val title = "服药:${med.name}" + med.dosage.takeIf { it.isNotBlank() }?.let { " $it" }.orEmpty()
            val type = if (med.days.isEmpty()) RepeatType.DAILY else RepeatType.WEEKLY
            val parsed = ParsedTask(title, next, false, 0, type, splitIntCsv(med.days), splitCsv(med.times), existing?.project.orEmpty())
            if (existing?.statusEnum == TaskStatus.PENDING) {
                if (existing.title != title || existing.repeatTypeEnum != type || existing.repeatTimes != med.times || existing.repeatDays != med.days)
                    app.repository.applyEdit(existing.uuid, parsed)
                taskId = existing.uuid
            } else taskId = app.repository.saveNew(parsed).uuid
            app.database.taskDao().byUuid(taskId)?.let { app.database.taskDao().upsert(it.copy(medicationUuid = med.uuid)) }
        }
        dao.saveMedication(med.copy(taskUuid = taskId))
    }
    suspend fun deleteMedication(id: String) = medicationMutex.withLock {
        dao.medication(id)?.taskUuid?.let { app.repository.delete(it) }
        dao.deleteMedication(id) // 服药历史保留姓名快照。
    }
    suspend fun logNextDose(id: String, target: LocalDateTime, status: String = "taken"): Boolean = medicationMutex.withLock {
        var updatedTask: TaskEntity? = null
        val saved = app.database.withTransaction {
            val med = dao.medication(id) ?: return@withTransaction false
            val now = LocalDateTime.now()
            val slots = MedicationPlan.todaySlots(listOf(med.entry()), dao.doses().map { it.entry() }, now)
            val next = MedicationPlan.nextUnrecordedSlot(id, slots) ?: return@withTransaction false
            if (next.time != target) return@withTransaction false
            dao.saveDose(MedicationDoseEntity(medicationUuid = id, name = med.name, dosage = med.dosage, status = status))
            val task = med.taskUuid?.let { app.database.taskDao().byUuid(it) }
            if (task?.statusEnum == TaskStatus.PENDING && task.remindAt <= now.plusHours(1)) {
                Scheduler.nextOccurrence(task.toData(), task.remindAt)?.let { at ->
                    updatedTask = task.copy(remindAtMillis = at.toEpochMillis(), nextRemindAtMillis = at.toEpochMillis(), phase = "start", ignoreStreak = 0)
                    app.database.taskDao().upsert(updatedTask!!)
                }
            }
            true
        }
        updatedTask?.let { app.alarms.scheduleReminder(it.uuid, it.nextRemindAt); com.lodo.app.notify.Notifications.dismiss(app, it.uuid) }
        saved
    }

    fun confirmations(): CyclePrediction.Confirmations = CyclePrediction.Confirmations(
        prefs.getString("notStartedThrough", null)?.let { runCatching { LocalDate.parse(it) }.getOrNull() },
        prefs.getString("ongoingThrough", null)?.let { runCatching { LocalDate.parse(it) }.getOrNull() })
    fun confirmCycle(ongoing: Boolean, value: LocalDate?) {
        prefs.edit().putString(if (ongoing) "ongoingThrough" else "notStartedThrough", value?.toString()).apply(); settingsRevision.value++
    }
    suspend fun startPeriod(day: LocalDate) = cycleMutex.withLock {
        require(day <= LocalDate.now())
        if (dao.periods().none { it.startDay == day.toString() }) dao.savePeriod(PeriodRecordEntity(startDay = day.toString()))
        prefs.edit().remove("notStartedThrough").remove("ongoingThrough").apply(); settingsRevision.value++
    }
    suspend fun endPeriod(id: String, day: LocalDate) = cycleMutex.withLock {
        val record = dao.periods().firstOrNull { it.uuid == id } ?: return@withLock
        require(day >= LocalDate.parse(record.startDay) && day <= LocalDate.now())
        dao.savePeriod(record.copy(endDay = day.toString()))
        prefs.edit().remove("ongoingThrough").apply(); settingsRevision.value++
    }
    suspend fun saveFlow(day: LocalDate, level: CycleFlowLevel?) = cycleMutex.withLock {
        require(day <= LocalDate.now())
        val latest = dao.flows().filter { it.dayKey == day.toString() }.maxByOrNull { it.updatedAtMillis }
        dao.saveFlow((latest ?: PeriodFlowEntity(dayKey = day.toString(), levelRaw = "")).copy(levelRaw = level?.raw.orEmpty(),
            updatedAtMillis = System.currentTimeMillis(), isDeleted = level == null))
    }

    suspend fun promptSummary(): String? {
        val now = LocalDateTime.now()
        val parts = mutableListOf<String>()
        WeightPlan.promptSummary(dao.weights().map { it.entry() }, weightGoal, now)?.let(parts::add)
        val foods = dao.foods().filter { it.dateMillis.toLocalDateTime().toLocalDate() == now.toLocalDate() }
        val total = foods.fold(Nutrition()) { a, f -> a + f.nutrition }
        if (foods.isNotEmpty()) parts += "今天进食 ${foods.size} 次,已估算摄入 ${WeightPlan.format(total.calories)} 千卡,${foods.count { !it.estimated }} 次尚未估算"
        val meds = dao.medications().filterNot { it.archived }
        if (meds.isNotEmpty()) {
            val (taken, expected) = MedicationPlan.adherence(meds.map { it.entry() }, dao.doses().map { it.entry() }, 7, now)
            parts += "最近 7 天服药已记录 $taken 顿 / 应服 $expected 顿"
        }
        // 只纳入本人条目,家人健康资料严格不混入本人的分析。
        if (cycleEnabled) {
            val prediction = CyclePrediction.predict(CyclePlan.merge(dao.periods().map { it.entry() }, emptyList(), now.toLocalDate()), now.toLocalDate(), confirmations())
            parts += "经期记录:状态 ${prediction.phase},有效周期 ${prediction.validCycles};预计下次开始 ${prediction.nextStart?.lower ?: "暂无"}—${prediction.nextStart?.upper ?: "暂无"}(仅供记录,不能用于避孕)"
        }
        val checkups = dao.checkups().filter { it.profileUuid == null }.map { it.snapshot() }
        val reports = app.database.memoryDao().all().filter { CheckupRepository.TAG in it.tagsList && it.checkupOwner() == null }.map {
            CheckupReportValue(it.uuid, it.title, it.checkupDateDay?.let(LocalDate::parse) ?: it.createdAtMillis.toLocalDateTime().toLocalDate(), it.checkupInstitution.orEmpty())
        }
        CheckupPlan.promptSummary(reports, checkups)?.let(parts::add)
        return parts.takeIf { it.isNotEmpty() }?.joinToString("\n\n")
    }

    fun backupSettings(): JSONObject = JSONObject().put("weightGoal", JSONObject(prefs.getString("weightGoal", "{}").orEmpty().ifBlank { "{}" }))
        .put("medicationVisible", medicationVisible).put("cycleEnabled", cycleEnabled).put("cycleReminderEnabled", cycleReminderEnabled)
        .put("diet", dietPlan.value?.let(::encodeDiet))
    fun restoreSettings(json: JSONObject) {
        val editor = prefs.edit()
        // 不覆盖本机已经设置过的偏好,与记录合并规则一致;确认日期不跨设备恢复。
        for (key in listOf("medicationVisible", "cycleEnabled", "cycleReminderEnabled"))
            if (!prefs.contains(key) && json.has(key)) editor.putBoolean(key, json.optBoolean(key))
        if (!prefs.contains("weightGoal")) json.optJSONObject("weightGoal")?.let { editor.putString("weightGoal", it.toString()) }
        if (!prefs.contains("diet")) json.optJSONObject("diet")?.let { raw -> decodeDiet(raw.toString())?.let { plan ->
            editor.putString("diet", encodeDiet(plan).toString()); dietPlan.value = plan
        } }
        editor.apply(); settingsRevision.value++
    }

    companion object {
        fun encodeDiet(plan: WeightDietPlan): JSONObject = JSONObject().put("day", plan.day.toString()).put("advice", plan.advice).put("meals", JSONArray(plan.meals.map {
            JSONObject().put("id", it.id).put("meal", it.meal).put("time", it.time).put("food", it.food).put("calories", it.calories).put("taskUuid", it.taskUuid)
        }))
        fun decodeDiet(raw: String): WeightDietPlan? = runCatching {
            val json = JSONObject(raw)
            val day = LocalDate.parse(json.getString("day"))
            val parsed = WeightDietPlan.parse(json, day) ?: return@runCatching null
            val array = json.getJSONArray("meals")
            parsed.copy(meals = parsed.meals.mapIndexed { index, meal -> meal.copy(id = array.getJSONObject(index).optString("id", meal.id), taskUuid = array.getJSONObject(index).str("taskUuid")) })
        }.getOrNull()
    }
}
