package com.lodo.app.ui

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.res.stringResource
import com.lodo.app.R
import com.lodo.app.ai.ParsedTask
import com.lodo.app.core.Lang
import com.lodo.app.core.RepeatType
import com.lodo.app.core.Strings
import com.lodo.app.core.TimeFormat
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

/** ViewModel and other non-Compose UI text still follows the selected app language. */
fun localizedDateTimeForLanguage(
    dateTime: LocalDateTime,
    language: Lang,
    today: LocalDate = LocalDate.now(),
): String {
    return TimeFormat.localized(dateTime, language, today)
}

fun localizedParsedTaskCaption(task: ParsedTask, language: Lang): String {
    val parts = mutableListOf(localizedDateTimeForLanguage(task.remindAt, language))
    if (task.repeatType != RepeatType.NONE) {
        val times = task.repeatTimes.joinToString("/")
        val recurrence = when (task.repeatType) {
            RepeatType.DAILY -> Strings.of("android_core_ai.daily", language)
            RepeatType.WEEKLY -> {
                val weekdayKeys = listOf(
                    "shared.mon", "shared.tue", "shared.wed", "shared.thu",
                    "shared.fri", "shared.sat", "shared.sun",
                )
                val weekdays = task.repeatDays.sorted().mapNotNull { day ->
                    weekdayKeys.getOrNull(day)?.let { key ->
                        val full = Strings.of(key, language)
                        if (language == Lang.ZH) full.drop(1) else full
                    }
                }.joinToString(if (language == Lang.ZH) "、" else ", ")
                Strings.of("android_core_ai.weekly_caption_prefix", language).trim() +
                    (if (language == Lang.EN) " " else "") + weekdays
            }
            RepeatType.NONE -> ""
        }
        parts += "$recurrence $times".trim()
    } else if (task.allDay) {
        parts += Strings.of("shared.all_day", language)
    }
    if (task.durationMinutes > 0) {
        parts += "${task.durationMinutes} ${Strings.of("android_core_ai.minutes_unit", language)}"
    }
    return parts.joinToString(" · ")
}

@Composable
fun localizedWeekdayLabels(): List<String> = listOf(
    stringResource(R.string.shared_mon),
    stringResource(R.string.shared_tue),
    stringResource(R.string.shared_wed),
    stringResource(R.string.shared_thu),
    stringResource(R.string.shared_fri),
    stringResource(R.string.shared_sat),
    stringResource(R.string.shared_sun),
)

@Composable
fun localizedWeekdayChipLabel(index: Int): String {
    val locale = LocalConfiguration.current.locales[0]
    val full = localizedWeekdayLabels()[index]
    return if (locale.language == "zh") full.drop(1) else full
}

@Composable
fun localizedWeekdayList(days: List<Int>, compactChinese: Boolean = false): String {
    val locale = LocalConfiguration.current.locales[0]
    val labels = localizedWeekdayLabels().map { label ->
        if (compactChinese && locale.language == "zh") label.drop(1) else label
    }
    return days.sorted().map { labels[it] }.joinToString(if (locale.language == "zh") "、" else ", ")
}

@Composable
fun localizedDateTimeLabel(dateTime: LocalDateTime, today: LocalDate = LocalDate.now()): String {
    val locale = LocalConfiguration.current.locales[0]
    val time = dateTime.format(DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale))
    return when (dateTime.toLocalDate()) {
        today -> stringResource(R.string.android_ui_date_time_today_0, time)
        today.plusDays(1) -> stringResource(R.string.android_ui_date_time_tomorrow_0, time)
        else -> {
            val formatted = dateTime.format(
                DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(locale),
            )
            stringResource(R.string.android_ui_date_time_on_0, formatted)
        }
    }
}

@Composable
fun localizedDayLabel(date: LocalDate, today: LocalDate = LocalDate.now()): String {
    val yesterday = stringResource(R.string.android_ui_yesterday)
    val locale = LocalConfiguration.current.locales[0]
    return if (date == today.minusDays(1)) yesterday
    else date.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM).withLocale(locale))
}
