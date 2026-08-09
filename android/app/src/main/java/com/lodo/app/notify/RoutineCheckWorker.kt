package com.lodo.app.notify

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.lodo.app.LodoApp

/** 定时任务(AI 例行任务)的触发机制,对应 iOS BGAppRefreshTask 那一层——
 * iOS 不允许 app 后台常驻跑定时器,靠系统的后台刷新任务 + 预排通知兜底
 * 两条腿走路;Android 用 WorkManager 周期性检查是同一个约束下的对应方案
 * (WorkManager 也不保证精确到分钟触发,15 分钟是系统允许的最小周期间隔,
 * 与 iOS 的"不保证唤醒、错过超过 6 小时就跳过"是同一类"尽力而为"的语义,
 * 不追求精确闹钟触发——例行任务本身也不需要闹钟级别的精确度)。 */
class RoutineCheckWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val app = applicationContext as LodoApp
        return try {
            app.routineRepository.runDue()
            Result.success()
        } catch (e: Exception) {
            Result.retry()
        }
    }
}
