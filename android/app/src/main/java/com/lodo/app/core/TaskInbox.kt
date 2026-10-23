package com.lodo.app.core

import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId

/** 与 iOS Date.distantFuture 相同的持久化哨兵;不加数据库字段,备份可互通。
 * 用绝对时间判断,避免切换时区把收集事项变成普通事项。
 * 不改 Scheduler 的三端共享语义,由业务层跳过提醒与两阶段开始。
 */
object TaskInbox {
    const val EPOCH_MILLIS = 64_092_211_200_000L
    val date: LocalDateTime
        get() = Instant.ofEpochMilli(EPOCH_MILLIS).atZone(ZoneId.systemDefault()).toLocalDateTime()

    fun contains(date: LocalDateTime): Boolean =
        date.atZone(ZoneId.systemDefault()).toInstant().toEpochMilli() >= EPOCH_MILLIS
}
