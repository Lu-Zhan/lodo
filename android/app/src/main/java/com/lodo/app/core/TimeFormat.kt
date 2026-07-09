package com.lodo.app.core

import java.time.LocalDate
import java.time.LocalDateTime
import java.time.LocalTime
import java.time.format.DateTimeFormatter

/** "HH:MM" 字符串与时间的互转、列表行日期文案(对应 iOS AppSettings.time/hhmm 与 TaskItem.format)。 */
object TimeFormat {
    private val hhmmFormatter = DateTimeFormatter.ofPattern("HH:mm")
    private val monthDayFormatter = DateTimeFormatter.ofPattern("M月d日 HH:mm")

    /** 解析 "HH:MM";格式异常时与 iOS 版一致回退到 9:00。 */
    fun localTime(hhmm: String): LocalTime {
        val parts = hhmm.split(":").mapNotNull { it.toIntOrNull() }
        if (parts.size != 2 || parts[0] !in 0..23 || parts[1] !in 0..59) return LocalTime.of(9, 0)
        return LocalTime.of(parts[0], parts[1])
    }

    /** 把 "HH:MM" 应用到某一天,得到具体提醒时间。 */
    fun timeOn(hhmm: String, day: LocalDate): LocalDateTime = day.atTime(localTime(hhmm))

    fun hhmm(time: LocalTime): String = "%02d:%02d".format(time.hour, time.minute)

    /** "今天 21:00" / "明天 08:30" / "7月15日 10:00"。 */
    fun format(dateTime: LocalDateTime, today: LocalDate = LocalDate.now()): String {
        val time = dateTime.format(hhmmFormatter)
        return when (dateTime.toLocalDate()) {
            today -> "今天 $time"
            today.plusDays(1) -> "明天 $time"
            else -> dateTime.format(monthDayFormatter)
        }
    }
}
