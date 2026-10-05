package com.lodo.app.core

import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Locale

/** 行程项类型,存储值与 iOS TravelItemKind 一致(flight/train/coach/lodging/place),别改。 */
enum class TravelItemKind(val raw: String, val promptName: String) {
    FLIGHT("flight", "航班"), TRAIN("train", "火车"), COACH("coach", "客车"),
    LODGING("lodging", "住宿"), PLACE("place", "地点");

    val isTransport: Boolean get() = this == FLIGHT || this == TRAIN || this == COACH

    companion object {
        fun from(raw: String?): TravelItemKind? = entries.firstOrNull { it.raw == raw?.trim()?.lowercase() }
    }
}

/** 交通补充信息(航班/火车/客车共用),整块 JSON 存在 travelFlightData,同 iOS FlightDetails。
 * 只来自用户导入的文本和手填,不接任何航班数据 API。 */
data class TransportDetails(
    val airline: String? = null,
    val departureCode: String? = null,
    val arrivalCode: String? = null,
    val departureTerminal: String? = null,
    val arrivalTerminal: String? = null,
    val checkInCounter: String? = null,
    val gate: String? = null,
    val platform: String? = null,
    val carriage: String? = null,
    val seat: String? = null,
    val cabin: String? = null,
    val aircraft: String? = null,
    val baggageBelt: String? = null,
    val status: String? = null,
    val boardingTime: String? = null,
    val estimatedDeparture: String? = null,
    val estimatedArrival: String? = null,
    val departureTimeZone: String? = null,
    val arrivalTimeZone: String? = null,
) {
    fun isEmpty() = this == TransportDetails()

    fun toJson(): String {
        val o = JSONObject()
        fun put(k: String, v: String?) { if (!v.isNullOrBlank()) o.put(k, v) }
        put("airline", airline); put("departure_code", departureCode); put("arrival_code", arrivalCode)
        put("departure_terminal", departureTerminal); put("arrival_terminal", arrivalTerminal)
        put("check_in_counter", checkInCounter); put("gate", gate); put("platform", platform)
        put("carriage", carriage); put("seat", seat); put("cabin", cabin); put("aircraft", aircraft)
        put("baggage_belt", baggageBelt); put("status", status); put("boarding_time", boardingTime)
        put("estimated_departure", estimatedDeparture); put("estimated_arrival", estimatedArrival)
        put("departure_timezone", departureTimeZone); put("arrival_timezone", arrivalTimeZone)
        return o.toString()
    }

    /** 新截图有的字段覆盖、没有的保留(同 iOS merged(with:))。 */
    fun merged(newer: TransportDetails) = TransportDetails(
        newer.airline ?: airline, newer.departureCode ?: departureCode, newer.arrivalCode ?: arrivalCode,
        newer.departureTerminal ?: departureTerminal, newer.arrivalTerminal ?: arrivalTerminal,
        newer.checkInCounter ?: checkInCounter, newer.gate ?: gate, newer.platform ?: platform,
        newer.carriage ?: carriage, newer.seat ?: seat, newer.cabin ?: cabin, newer.aircraft ?: aircraft,
        newer.baggageBelt ?: baggageBelt, newer.status ?: status, newer.boardingTime ?: boardingTime,
        newer.estimatedDeparture ?: estimatedDeparture, newer.estimatedArrival ?: estimatedArrival,
        newer.departureTimeZone ?: departureTimeZone, newer.arrivalTimeZone ?: arrivalTimeZone,
    )

    /** 摘要里给 AI 看的一行,同 iOS flightPromptLine。 */
    fun promptLine(): String = listOfNotNull(
        status?.let { "状态 $it" }, departureTerminal?.let { "出发航站楼 $it" },
        checkInCounter?.let { "值机柜台 $it" }, gate?.let { "登机口/检票口 $it" },
        platform?.let { "站台 $it" }, carriage?.let { "车厢 $it" },
        boardingTime?.let { "登机 $it" }, estimatedDeparture?.let { "预计出发 $it" },
        arrivalTerminal?.let { "到达航站楼 $it" }, estimatedArrival?.let { "预计到达 $it" },
        baggageBelt?.let { "行李转盘 $it" }, seat?.let { "座位 $it" }, aircraft?.let { "机型 $it" },
    ).joinToString(",")

    companion object {
        fun decode(json: String?): TransportDetails? {
            if (json.isNullOrBlank()) return null
            return runCatching { parse(JSONObject(json)) }.getOrNull()
        }

        fun parse(o: JSONObject?): TransportDetails? {
            o ?: return null
            fun s(k: String) = o.optString(k).trim().takeIf { it.isNotEmpty() && it != "null" }
            val d = TransportDetails(
                s("airline"), s("departure_code"), s("arrival_code"), s("departure_terminal"),
                s("arrival_terminal"), s("check_in_counter"), s("gate"), s("platform"), s("carriage"),
                s("seat"), s("cabin"), s("aircraft"), s("baggage_belt"), s("status"), s("boarding_time"),
                s("estimated_departure"), s("estimated_arrival"), s("departure_timezone"), s("arrival_timezone"),
            )
            return if (d.isEmpty()) null else d
        }
    }
}

/** 行程项的值快照,对应 iOS TravelEntry。 */
data class TravelEntry(
    val id: String,
    val kind: TravelItemKind,
    val title: String,
    val note: String = "",
    val start: LocalDateTime? = null,
    val end: LocalDateTime? = null,
    val price: Double? = null,
    val currency: String = "CNY",
    val placeName: String? = null,
    val originName: String? = null,
    val code: String? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val transport: TransportDetails? = null,
    val hasAttachment: Boolean = false,
) {
    val isUnscheduled get() = start == null
    val hasCoordinate get() = latitude != null && longitude != null
}

data class TravelDay(val date: LocalDate, val entries: List<TravelEntry>)

data class TravelCostLine(val currency: String, val amount: Double)

data class TravelTotal(val amount: Double, val missingCurrencies: List<String>)

/** 旅行纯逻辑,与 iOS TravelPlan 同义:住宿按"住了几晚"铺开(退房当天不算),交通/地点
 * 只落在开始那天,没时间的进「未排期」,落在行程区间外的单独列出来。 */
object TravelPlan {
    fun days(start: LocalDate, end: LocalDate): List<LocalDate> {
        val (a, b) = if (end.isBefore(start)) end to start else start to end
        val count = ChronoUnit.DAYS.between(a, b).toInt().coerceAtMost(60)
        return (0..count).map { a.plusDays(it.toLong()) }
    }

    fun group(entries: List<TravelEntry>, days: List<LocalDate>): List<TravelDay> =
        days.map { day -> TravelDay(day, sortedForDay(entries.filter { covers(it, day) })) }

    fun sortedForDay(entries: List<TravelEntry>): List<TravelEntry> =
        sorted(entries.filter { it.kind != TravelItemKind.LODGING })

    fun covers(entry: TravelEntry, day: LocalDate): Boolean {
        val start = entry.start ?: return false
        val startDay = start.toLocalDate()
        val end = entry.end
        if (entry.kind != TravelItemKind.LODGING || end == null) return startDay == day
        val endDay = end.toLocalDate()
        if (!endDay.isAfter(startDay)) return startDay == day
        return !day.isBefore(startDay) && day.isBefore(endDay)
    }

    /** 当晚住哪(日程里排在每天的最后一行)。 */
    fun lodgings(day: LocalDate, entries: List<TravelEntry>): List<TravelEntry> =
        entries.filter { it.kind == TravelItemKind.LODGING && covers(it, day) }

    fun nights(entry: TravelEntry): Int? {
        if (entry.kind != TravelItemKind.LODGING) return null
        val s = entry.start ?: return null
        val e = entry.end ?: return null
        val n = ChronoUnit.DAYS.between(s.toLocalDate(), e.toLocalDate()).toInt()
        return n.takeIf { it > 0 }
    }

    fun unscheduled(entries: List<TravelEntry>) = sorted(entries.filter { it.isUnscheduled })

    fun outOfRange(entries: List<TravelEntry>, days: List<LocalDate>): List<TravelEntry> {
        if (days.isEmpty()) return sorted(entries.filter { !it.isUnscheduled })
        return sorted(entries.filter { e -> !e.isUnscheduled && days.none { covers(e, it) } })
    }

    fun transports(entries: List<TravelEntry>) = sorted(entries.filter { it.kind.isTransport })

    fun sorted(entries: List<TravelEntry>): List<TravelEntry> = entries.sortedWith { l, r ->
        val ls = l.start
        val rs = r.start
        when {
            ls != null && rs != null -> if (ls != rs) ls.compareTo(rs) else l.title.compareTo(r.title)
            ls != null -> -1
            rs != null -> 1
            else -> l.title.compareTo(r.title)
        }
    }

    fun costs(entries: List<TravelEntry>): List<TravelCostLine> {
        val totals = linkedMapOf<String, Double>()
        for (e in entries) {
            val p = e.price ?: continue
            if (p == 0.0) continue
            totals[e.currency] = (totals[e.currency] ?: 0.0) + p
        }
        return totals.map { TravelCostLine(it.key, it.value) }
            .sortedWith(compareByDescending<TravelCostLine> { it.amount }.thenBy { it.currency })
    }

    fun total(entries: List<TravelEntry>, target: String, convert: (Double, String, String) -> Double?): TravelTotal {
        var sum = 0.0
        val missing = sortedSetOf<String>()
        for (line in costs(entries)) {
            if (line.currency == target) sum += line.amount
            else convert(line.amount, line.currency, target)?.let { sum += it } ?: missing.add(line.currency)
        }
        return TravelTotal(sum, missing.toList())
    }

    /** read_trip 的摘要,行格式同 iOS promptSummary;includeIDs 时每行末尾带 [id:…]。 */
    fun promptSummary(tripTitle: String, days: List<LocalDate>, entries: List<TravelEntry>, includeIDs: Boolean = false): String {
        if (entries.isEmpty()) return "「$tripTitle」还没有任何行程项。"
        val dayFmt = DateTimeFormatter.ofPattern("M月d日", Locale.CHINA)
        val timeFmt = DateTimeFormatter.ofPattern("HH:mm")
        fun line(e: TravelEntry): String {
            val parts = mutableListOf("${e.kind.promptName}:${e.title}")
            e.code?.takeIf { it.isNotBlank() }?.let { parts += it }
            e.start?.let { s -> parts += s.format(timeFmt) + (e.end?.let { "–" + it.format(timeFmt) } ?: "") }
            val origin = e.originName
            val place = e.placeName
            if (!origin.isNullOrBlank() && !place.isNullOrBlank()) parts += "$origin → $place"
            else if (!place.isNullOrBlank()) parts += place
            e.price?.takeIf { it != 0.0 }?.let { parts += "${e.currency} ${String.format(Locale.ROOT, "%.2f", it)}" }
            e.transport?.promptLine()?.takeIf { it.isNotEmpty() }?.let { parts += it }
            return "  - " + parts.joinToString(" · ") + if (includeIDs) " [id:${e.id}]" else ""
        }
        val out = mutableListOf("「$tripTitle」行程:")
        for (day in group(entries, days)) {
            val all = day.entries + lodgings(day.date, entries)
            if (all.isEmpty()) continue
            out += day.date.format(dayFmt)
            out += all.map(::line)
        }
        outOfRange(entries, days).takeIf { it.isNotEmpty() }?.let { out += "行程日期之外:"; out += it.map(::line) }
        unscheduled(entries).takeIf { it.isNotEmpty() }?.let { out += "未排期:"; out += it.map(::line) }
        costs(entries).takeIf { it.isNotEmpty() }?.let { lines ->
            out += "花费合计:" + lines.joinToString("、") { "${it.currency} ${String.format(Locale.ROOT, "%.2f", it.amount)}" }
        }
        return out.joinToString("\n")
    }
}

/** 旅行同行人(TripEntity.travelersJson 的一项)。 */
data class TripTraveler(val id: String, val name: String, val note: String = "", val contactUuid: String? = null) {
    companion object {
        fun decode(json: String): List<TripTraveler> {
            if (json.isBlank()) return emptyList()
            return runCatching {
                val arr = org.json.JSONArray(json)
                (0 until arr.length()).mapNotNull { i ->
                    val o = arr.optJSONObject(i) ?: return@mapNotNull null
                    TripTraveler(
                        o.optString("id"), o.optString("name"), o.optString("note"),
                        o.optString("contactUuid").takeIf { it.isNotBlank() },
                    )
                }
            }.getOrDefault(emptyList())
        }

        fun encode(list: List<TripTraveler>): String {
            val arr = org.json.JSONArray()
            list.forEach {
                arr.put(JSONObject().put("id", it.id).put("name", it.name).put("note", it.note)
                    .apply { it.contactUuid?.let { c -> put("contactUuid", c) } })
            }
            return arr.toString()
        }
    }
}

/** 旅行用品清单分组:按分类首次出现的顺序(同 iOS PackingPlan.grouped)。 */
object PackingPlan {
    val categories = listOf("证件", "钱与卡", "衣物", "电子", "洗护", "药品", "其他")

    fun <T> grouped(items: List<T>, category: (T) -> String): List<Pair<String, List<T>>> {
        val order = mutableListOf<String>()
        val map = linkedMapOf<String, MutableList<T>>()
        for (i in items) {
            val c = category(i).ifBlank { "其他" }
            if (c !in map) order += c
            map.getOrPut(c) { mutableListOf() } += i
        }
        return order.map { it to map.getValue(it) }
    }

    /** 去掉已有的(互相包含也算),同 iOS newSuggestions。 */
    fun newSuggestions(suggested: List<String>, existing: List<String>): List<String> {
        val have = existing.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        return suggested.filter { s ->
            val k = s.trim().lowercase()
            k.isNotEmpty() && have.none { it.contains(k) || k.contains(it) }
        }
    }
}
