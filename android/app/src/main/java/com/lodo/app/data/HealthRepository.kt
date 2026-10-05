package com.lodo.app.data

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.request.AggregateGroupByPeriodRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import com.lodo.app.core.HealthDailyPoint
import com.lodo.app.core.HealthMetricKind
import com.lodo.app.core.HealthReport
import com.lodo.app.core.HealthSeries
import java.time.Duration
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.Period
import java.time.ZoneId
import kotlin.reflect.KClass

/**
 * Health Connect 桥接(对应 iOS HealthKitBridge):只读授权、未授权/无数据/查询失败一律返回
 * 空报告静默降级。总开关 healthEnabled 默认关,关着时一次都不读(调用方负责判断)。
 * Health Connect 和 HealthKit 一样不明确告诉 app 读权限被拒,所以"被拒"和"没数据"是同一种空态。
 */
class HealthRepository(private val context: Context) {
    val readPermissions: Set<String> = setOf(
        HealthPermission.getReadPermission(StepsRecord::class),
        HealthPermission.getReadPermission(ActiveCaloriesBurnedRecord::class),
        HealthPermission.getReadPermission(ExerciseSessionRecord::class),
        HealthPermission.getReadPermission(SleepSessionRecord::class),
        HealthPermission.getReadPermission(RestingHeartRateRecord::class),
        HealthPermission.getReadPermission(HeartRateVariabilityRmssdRecord::class),
        HealthPermission.getReadPermission(WeightRecord::class),
    )

    /** 设备上有没有可用的 Health Connect(Android 14+ 自带,13 及以下要装 app)。 */
    val isAvailable: Boolean
        get() = HealthConnectClient.getSdkStatus(context) == HealthConnectClient.SDK_AVAILABLE

    private fun client(): HealthConnectClient? = if (isAvailable) runCatching { HealthConnectClient.getOrCreate(context) }.getOrNull() else null

    suspend fun grantedPermissions(): Set<String> =
        client()?.let { runCatching { it.permissionController.getGrantedPermissions() }.getOrNull() } ?: emptySet()

    suspend fun report(days: Int): HealthReport {
        val client = client() ?: return HealthReport.EMPTY
        val zone = ZoneId.systemDefault()
        val endDay = LocalDate.now()
        val startDay = endDay.minusDays(days.toLong() - 1)
        val range = TimeRangeFilter.between(startDay.atStartOfDay(), LocalDateTime.now())
        val granted = grantedPermissions()
        fun ok(kind: KClass<out Record>) = HealthPermission.getReadPermission(kind) in granted
        val series = mutableListOf<HealthSeries>()

        suspend fun aggregate(kind: HealthMetricKind, metric: androidx.health.connect.client.aggregate.AggregateMetric<*>, value: (Any?) -> Double?) {
            runCatching {
                val result = client.aggregateGroupByPeriod(AggregateGroupByPeriodRequest(setOf(metric), range, Period.ofDays(1)))
                val points = result.mapNotNull { r ->
                    val v = value(r.result[metric]) ?: return@mapNotNull null
                    if (v <= 0) null else HealthDailyPoint(r.startTime.toLocalDate(), v)
                }
                if (points.isNotEmpty()) series += HealthSeries(kind, points)
            }
        }
        if (ok(StepsRecord::class)) aggregate(HealthMetricKind.STEPS, StepsRecord.COUNT_TOTAL) { (it as? Long)?.toDouble() }
        if (ok(ActiveCaloriesBurnedRecord::class)) aggregate(HealthMetricKind.ACTIVE_ENERGY, ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL) {
            (it as? androidx.health.connect.client.units.Energy)?.inKilocalories
        }
        if (ok(ExerciseSessionRecord::class)) aggregate(HealthMetricKind.EXERCISE_MINUTES, ExerciseSessionRecord.EXERCISE_DURATION_TOTAL) {
            (it as? Duration)?.toMinutes()?.toDouble()
        }
        if (ok(SleepSessionRecord::class)) runCatching {
            // 睡眠按醒来那天归日。
            val records = client.readRecords(ReadRecordsRequest(SleepSessionRecord::class, TimeRangeFilter.between(startDay.minusDays(1).atStartOfDay(), LocalDateTime.now()))).records
            val byDay = records.groupBy { it.endTime.atZone(zone).toLocalDate() }
                .mapValues { (_, list) -> list.sumOf { Duration.between(it.startTime, it.endTime).toMinutes() } / 60.0 }
            val points = byDay.filterKeys { !it.isBefore(startDay) }.map { HealthDailyPoint(it.key, it.value) }
            if (points.isNotEmpty()) series += HealthSeries(HealthMetricKind.SLEEP_HOURS, points)
        }
        suspend fun <T : Record> dailyAverage(kind: HealthMetricKind, cls: KClass<T>, time: (T) -> java.time.Instant, value: (T) -> Double) {
            if (!ok(cls)) return
            runCatching {
                val records = client.readRecords(ReadRecordsRequest(cls, range)).records
                val points = records.groupBy { time(it).atZone(zone).toLocalDate() }
                    .map { (day, list) -> HealthDailyPoint(day, list.map(value).average()) }
                if (points.isNotEmpty()) series += HealthSeries(kind, points)
            }
        }
        dailyAverage(HealthMetricKind.RESTING_HEART_RATE, RestingHeartRateRecord::class, { it.time }, { it.beatsPerMinute.toDouble() })
        dailyAverage(HealthMetricKind.HRV, HeartRateVariabilityRmssdRecord::class, { it.time }, { it.heartRateVariabilityMillis })
        dailyAverage(HealthMetricKind.BODY_MASS, WeightRecord::class, { it.time }, { it.weight.inKilograms })
        return HealthReport(series.sortedBy { it.kind.ordinal }, days)
    }
}
