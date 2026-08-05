package com.lodo.app.notify

/** 通知权限缺失时的闹钟重排退避间隔:随连续缺失次数递增,避免高频重试,
 * 封顶后仍保持一个较短周期以便权限恢复时尽快追上。 */
object NotifyBackoff {
    fun minutes(missCount: Int): Long = (5L * missCount).coerceAtMost(30L)
}
