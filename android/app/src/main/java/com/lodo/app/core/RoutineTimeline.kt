package com.lodo.app.core

import java.time.LocalDateTime

/** 混排行只贡献一行:今天跑过则保留今天最新结果,否则展示下一次触发。 */
object RoutineTimeline {
    fun displayTime(enabled: Boolean, lastRun: LocalDateTime?, nextRun: LocalDateTime?, now: LocalDateTime): LocalDateTime? {
        if (!enabled) return null
        return lastRun?.takeIf { it.toLocalDate() == now.toLocalDate() } ?: nextRun
    }
}
