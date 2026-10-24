package com.lodo.app.data

import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.MenstruationFlowRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import com.lodo.app.LodoApp
import com.lodo.app.core.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.time.LocalDate
import java.time.ZoneId

/** 健康库本身是账本。读全分页成功才对账,只删除本包写的流量记录。 */
class CycleHealthSync(private val app: LodoApp) {
    enum class Status { IDLE, SYNCING, SYNCED, NOT_AUTHORIZED, FAILED }
    val status = MutableStateFlow(Status.IDLE)
    val samples = MutableStateFlow<List<CycleFlow.HealthSample>>(emptyList())
    val permissions = setOf(HealthPermission.getReadPermission(MenstruationFlowRecord::class),
        HealthPermission.getWritePermission(MenstruationFlowRecord::class))
    val requestPermissions: Set<String> get() = permissions + if (app.health.isAvailable &&
        HealthConnectClient.getOrCreate(app).features.getFeatureStatus(
            androidx.health.connect.client.HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_HISTORY
        ) == androidx.health.connect.client.HealthConnectFeatures.FEATURE_STATUS_AVAILABLE)
        setOf(HealthPermission.PERMISSION_READ_HEALTH_DATA_HISTORY) else emptySet()
    private val mutex = Mutex()
    suspend fun refresh() = mutex.withLock {
        val reads = app.healthJournal.cycleEnabled &&
            (app.healthJournal.cycleHealthSyncEnabled || app.settings.snapshot().healthEnabled)
        if (!reads || !app.health.isAvailable) {
            samples.value = emptyList(); status.value = Status.IDLE
            return@withLock
        }
        try {
            val client = HealthConnectClient.getOrCreate(app)
            val granted = client.permissionController.getGrantedPermissions()
            if (HealthPermission.getReadPermission(MenstruationFlowRecord::class) !in granted) {
                samples.value = emptyList(); status.value = Status.NOT_AUTHORIZED
                return@withLock
            }
            status.value = Status.SYNCING
            val today = LocalDate.now()
            // 历史授权后对齐 iOS 的 400 天;否则保守留在默认 30 天内。窗口外不增不删。
            val since = today.minusDays(if (HealthPermission.PERMISSION_READ_HEALTH_DATA_HISTORY in granted) 399 else 29)
            val zone = ZoneId.systemDefault()
            val records = mutableListOf<MenstruationFlowRecord>()
            var token: String? = null
            do {
                val page = client.readRecords(ReadRecordsRequest(MenstruationFlowRecord::class,
                    TimeRangeFilter.between(since.atStartOfDay(), today.plusDays(1).atStartOfDay()), pageToken = token))
                records += page.records
                token = page.pageToken
            } while (token != null)
            fun day(r: MenstruationFlowRecord) = r.time.atZone(r.zoneOffset ?: zone).toLocalDate().toString()
            val foreign = records.filter { it.metadata.dataOrigin.packageName != app.packageName }
            samples.value = foreign.map { CycleFlow.HealthSample(day(it), level(it.flow)) }
            if (!app.healthJournal.cycleHealthSyncEnabled) { status.value = Status.IDLE; return@withLock }
            if (!granted.containsAll(permissions)) { status.value = Status.NOT_AUTHORIZED; return@withLock }
            val manual = app.database.healthDao().periods().map { it.entry() }
            val flows = app.database.healthDao().flows().map { it.entry() }
            val merged = CyclePlan.merge(manual, CyclePlan.periodsFromFlowDays(samples.value.filter { it.level.isBleeding }.map { LocalDate.parse(it.dayKey) }), today)
            val desired = CycleHealthExport.desired(manual, flows, foreign.map(::day).toSet(), since, today,
                CyclePrediction.predict(merged, today, app.healthJournal.confirmations()).periodLength)
            val existing = records.filter { it.metadata.dataOrigin.packageName == app.packageName }.map {
                CycleHealthExport.Existing(it.metadata.id, CycleHealthExport.Day(day(it), level(it.flow)))
            }
            val plan = CycleHealthExport.plan(desired, existing)
            // 等待读取期间可能关掉开关;再次检查,不继续写入。
            if (!app.healthJournal.cycleHealthSyncEnabled || !app.healthJournal.cycleEnabled) return@withLock
            if (plan.delete.isNotEmpty()) client.deleteRecords(MenstruationFlowRecord::class, plan.delete, emptyList())
            if (plan.add.isNotEmpty()) client.insertRecords(plan.add.map {
                val time = LocalDate.parse(it.dayKey).atTime(12, 0).atZone(zone)
                MenstruationFlowRecord(time = time.toInstant(), zoneOffset = time.offset, flow = flow(it.level),
                    metadata = Metadata.manualEntry(clientRecordId = "lodo-cycle-${it.dayKey}", clientRecordVersion = System.currentTimeMillis()))
            })
            status.value = Status.SYNCED
        } catch (e: CancellationException) { throw e
        } catch (_: Exception) { samples.value = emptyList(); status.value = Status.FAILED }
    }

    private fun level(flow: Int) = when (flow) {
        MenstruationFlowRecord.FLOW_LIGHT -> CycleFlowLevel.LIGHT
        MenstruationFlowRecord.FLOW_MEDIUM -> CycleFlowLevel.MEDIUM
        MenstruationFlowRecord.FLOW_HEAVY -> CycleFlowLevel.HEAVY
        else -> CycleFlowLevel.UNSPECIFIED
    }
    private fun flow(level: CycleFlowLevel) = when (level) {
        CycleFlowLevel.LIGHT -> MenstruationFlowRecord.FLOW_LIGHT
        CycleFlowLevel.MEDIUM -> MenstruationFlowRecord.FLOW_MEDIUM
        CycleFlowLevel.HEAVY -> MenstruationFlowRecord.FLOW_HEAVY
        else -> MenstruationFlowRecord.FLOW_UNKNOWN
    }
}
