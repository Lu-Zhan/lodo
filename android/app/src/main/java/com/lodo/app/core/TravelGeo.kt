package com.lodo.app.core

import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.text.Normalizer
import java.time.LocalDate
import java.util.Locale
import kotlin.math.asin
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * 旅行地图的纯逻辑,移植自 iOS 的 PlaceRegion / OSMGeocode / TravelDestination / RoadRoute /
 * TravelMapFraming。安卓没有苹果那条 MKLocalSearch,地名查坐标只走 OpenStreetMap Nominatim,
 * 路线只走 OSRM(routing.openstreetmap.de)——两边都不要 key。
 */

data class GeoPoint(val latitude: Double, val longitude: Double)

object TravelGeo {
    /** 两点大圆距离(米)。 */
    fun distance(a: GeoPoint, b: GeoPoint): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(b.latitude - a.latitude)
        val dLon = Math.toRadians(b.longitude - a.longitude)
        val h = sin(dLat / 2).pow(2) + cos(Math.toRadians(a.latitude)) * cos(Math.toRadians(b.latitude)) * sin(dLon / 2).pow(2)
        return 2 * r * asin(sqrt(h))
    }

    /** 一两公里内步行,再远驾车(同 iOS TravelMapFraming.prefersWalking)。 */
    fun prefersWalking(a: GeoPoint, b: GeoPoint) = distance(a, b) <= 1_500

    /** 路线缓存的键:两端坐标约 1 米精度(同 iOS legKey)。 */
    fun legKey(a: GeoPoint, b: GeoPoint) =
        String.format(Locale.ROOT, "%.5f,%.5f>%.5f,%.5f", a.latitude, a.longitude, b.latitude, b.longitude)

    /**
     * 选中某天时的连线:前一晚住的酒店 → 当天有坐标的地点(按时间)→ 当晚住的酒店
     * (同 iOS TravelPlan.dayRoute)。交通类只画点不连线。
     */
    fun dayRoute(day: LocalDate, entries: List<TravelEntry>): List<TravelEntry> {
        val lodgings = entries.filter { it.kind == TravelItemKind.LODGING && it.hasCoordinate }
        val tonight = lodgings.firstOrNull { TravelPlan.covers(it, day) }
        val morning = lodgings.firstOrNull { TravelPlan.covers(it, day.minusDays(1)) }
        val places = TravelPlan.sorted(entries.filter { it.kind == TravelItemKind.PLACE && it.hasCoordinate && TravelPlan.covers(it, day) })
        return listOfNotNull(morning) + places + listOfNotNull(tonight)
    }
}

/** 从文字里认国家/地区,给出 ISO 码(同 iOS PlaceRegion)。名字表来自 JDK 的地区名(中文/英文)+ 一小组别名。 */
object PlaceRegion {
    private val names: List<Pair<String, String>> by lazy {
        val table = linkedMapOf<String, String>()
        val locales = listOf(Locale.SIMPLIFIED_CHINESE, Locale.TRADITIONAL_CHINESE, Locale.ENGLISH)
        for (code in Locale.getISOCountries()) {
            for (l in locales) {
                val name = Locale("", code).getDisplayCountry(l).lowercase().trim()
                if (name.length >= 2 && name !in table) table[name] = code
            }
        }
        val aliases = mapOf(
            "中国" to "CN", "中國" to "CN", "中华人民共和国" to "CN", "china" to "CN", "prc" to "CN",
            "香港" to "HK", "hong kong" to "HK", "澳门" to "MO", "澳門" to "MO", "macao" to "MO", "macau" to "MO",
            "台湾" to "TW", "台灣" to "TW", "taiwan" to "TW", "韩国" to "KR", "韓國" to "KR", "南韩" to "KR", "korea" to "KR",
            "英国" to "GB", "uk" to "GB", "united kingdom" to "GB", "美国" to "US", "usa" to "US", "united states" to "US",
            "日本" to "JP", "japan" to "JP",
        )
        aliases.forEach { (n, c) -> table[n] = c }
        table.map { it.key to it.value }.sortedByDescending { it.first.length }
    }

    fun isoCode(text: String?): String? {
        val hay = text?.lowercase()?.trim().orEmpty()
        if (hay.isEmpty()) return null
        for ((name, code) in names) {
            if (!hay.contains(name)) continue
            if (name.first().code < 128 && !Regex("(^|[^a-z])" + Regex.escape(name) + "($|[^a-z])").containsMatchIn(hay)) continue
            return code
        }
        return null
    }

    fun isoCode(candidates: List<String?>): String? = candidates.firstNotNullOfOrNull { isoCode(it) }

    /** 大陆/港澳台互认;判不出来就别拦(同 iOS matches)。 */
    fun matches(expected: String?, actual: String?): Boolean {
        val e = expected?.uppercase()?.takeIf { it.isNotEmpty() } ?: return true
        val a = actual?.uppercase()?.takeIf { it.isNotEmpty() } ?: return true
        if (e == a) return true
        val gc = setOf("CN", "HK", "MO", "TW")
        return e in gc && a in gc
    }
}

/** 旅行名/城市名 → 候选城市;住宿「住新宿一带」→「新宿」(同 iOS TravelDestination)。 */
object TravelDestination {
    private val suffixes = listOf("自由行", "之旅", "旅行", "行程", "攻略", "旅游", "度假", "出游", "游", "行", "日", "天", "晚", "夜", "周", "趟")
    private val numerals = "0123456789０１２３４５６７８９一二三四五六七八九十两半".toSet()

    fun cityCandidates(city: String, title: String): List<String> =
        listOf(city.trim(), stripped(title)).filter { it.isNotEmpty() }.distinct()

    fun stripped(title: String): String {
        var t = title.trim()
        val cut = t.indexOfFirst { it.isWhitespace() || it == '·' || (!it.isLetterOrDigit() && it != '\'') }
        if (cut >= 0) t = t.substring(0, cut)
        var changed = true
        while (changed && t.isNotEmpty()) {
            changed = false
            if (t.last() in numerals) { t = t.dropLast(1); changed = true; continue }
            for (s in suffixes) if (t.endsWith(s) && t.length - s.length >= 2) { t = t.dropLast(s.length); changed = true; break }
        }
        return t
    }

    fun lodgingQuery(title: String): String {
        var t = title.trim()
        for (p in listOf("入住", "住在", "住")) if (t.startsWith(p) && t.length > p.length) { t = t.drop(p.length); break }
        for (s in listOf("一带", "附近", "周边", "周围", "区域")) if (t.endsWith(s) && t.length > s.length) { t = t.dropLast(s.length); break }
        return t.trim()
    }
}

/** OpenStreetMap Nominatim:拼请求、解析、名字校验、按知名度挑(同 iOS OSMGeocode)。 */
object OSMGeocode {
    data class Place(
        val name: String, val displayName: String, val point: GeoPoint, val countryCode: String?,
        val names: List<String>, val addressType: String, val importance: Double,
        /** OSM 的 osm_type + osm_id,合并两路候选时去重用。 */
        val id: String = "",
    )

    const val MIN_NAME_SCORE = 0.6
    const val NEARBY = 200_000.0
    val areaTypes = setOf("city", "town", "village", "municipality", "county", "state", "province", "region",
        "city_district", "district", "borough", "prefecture", "suburb", "quarter", "neighbourhood")

    fun countryCodes(region: String?): String? {
        val r = region?.uppercase()?.takeIf { it.isNotEmpty() } ?: return null
        return if (r in setOf("CN", "HK", "MO", "TW")) "cn,hk,mo,tw" else r.lowercase()
    }

    fun searchUrl(query: String, region: String?, anchor: GeoPoint? = null, language: String = "zh", limit: Int = 8): String {
        val p = mutableListOf(
            "q" to query, "format" to "jsonv2", "addressdetails" to "1", "namedetails" to "1",
            "limit" to "$limit", "accept-language" to language,
        )
        countryCodes(region)?.let { p += "countrycodes" to it }
        anchor?.let { a ->
            p += "viewbox" to listOf(a.longitude - 1, a.latitude + 1, a.longitude + 1, a.latitude - 1)
                .joinToString(",") { String.format(Locale.ROOT, "%.4f", it) }
        }
        return "https://nominatim.openstreetmap.org/search?" + p.joinToString("&") { (k, v) -> k + "=" + URLEncoder.encode(v, "UTF-8") }
    }

    fun parse(json: String): List<Place> = runCatching {
        val arr = JSONArray(json)
        (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val lat = o.optString("lat").toDoubleOrNull() ?: return@mapNotNull null
            val lon = o.optString("lon").toDoubleOrNull() ?: return@mapNotNull null
            val names = mutableListOf<String>()
            o.optString("name").takeIf { it.isNotEmpty() }?.let { names += it }
            o.optJSONObject("namedetails")?.let { d -> d.keys().forEach { k -> d.optString(k).takeIf { it.isNotEmpty() }?.let { names += it } } }
            val display = o.optString("display_name")
            Place(names.firstOrNull() ?: display.substringBefore(","), display, GeoPoint(lat, lon),
                o.optJSONObject("address")?.optString("country_code")?.uppercase()?.takeIf { it.isNotEmpty() },
                names, o.optString("addresstype"), o.optDouble("importance", 0.0).takeIf { !it.isNaN() } ?: 0.0,
                o.optString("osm_type") + (if (o.has("osm_id")) o.opt("osm_id").toString() else "$lat,$lon"))
        }
    }.getOrDefault(emptyList())

    /** 繁→简转换(安卓上由 app 注入 ICU 的 Hant-Hans;core 不碰 Android 类,单测里为恒等)。
     * OSM 里日本地名常是「築地場外市場」这类写法,不转就和「筑地场外市场」对不上(同 iOS normalize)。 */
    @Volatile
    var toSimplified: (String) -> String = { it }

    fun normalize(text: String): String =
        Normalizer.normalize(toSimplified(text.lowercase()), Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").filter { it.isLetterOrDigit() }

    /** 结果名字要覆盖查询词 60% 以上;是查询词的一截时那一截得占一半以上(「酒店」不能算对上「新宿王子酒店」)。 */
    fun nameScore(query: String, names: List<String>): Double {
        val q = normalize(query)
        if (q.isEmpty()) return 0.0
        return names.maxOfOrNull { name ->
            val n = normalize(name)
            when {
                n.isEmpty() -> 0.0
                n.contains(q) -> 1.0
                q.contains(n) && n.length * 2 >= q.length -> 1.0
                else -> { val pool = n.toSet(); q.count { it in pool }.toDouble() / q.length }
            }
        } ?: 0.0
    }

    /** 同名地点按知名度挑:有锚点时先在 200 公里内取最有名的,附近没有才在全部里取(同 iOS pick)。 */
    fun pick(places: List<Place>, query: String, region: String?, anchor: GeoPoint?, maxDistance: Double? = null, areasOnly: Boolean = false): Place? {
        val candidates = places.filter {
            PlaceRegion.matches(region, it.countryCode) && nameScore(query, it.names) >= MIN_NAME_SCORE &&
                (!areasOnly || it.addressType in areaTypes)
        }
        fun best(list: List<Place>) = list.fold(null as Place?) { b, p -> if (b == null || p.importance > b.importance) p else b }
        if (anchor == null) return best(candidates)
        val near = candidates.filter { TravelGeo.distance(anchor, it.point) <= NEARBY }
        val chosen = best(near.ifEmpty { candidates }) ?: return null
        if (maxDistance != null && TravelGeo.distance(anchor, chosen.point) > maxDistance) return null
        return chosen
    }
}

/**
 * AI 校准选点(同 iOS PlaceCalibration):每个地点从 OSM 拿一组过了国家和名字校验的候选
 * (标题和地点名两路都搜、合在一起,最多 8 个),整趟一次交给模型,每条回一个编号或 null。
 */
object PlaceCalibration {
    const val MAX_CANDIDATES = 8

    /** 标题去掉括号里的补充、住宿去掉「住…一带」,再加上地点名;去重。 */
    fun queries(title: String, place: String, isLodging: Boolean): List<String> {
        var t = title.replace(Regex("[（(【\\[][^）)】\\]]*[）)】\\]]"), "")
        if (isLodging) t = TravelDestination.lodgingQuery(t)
        return listOf(t, place).map { it.trim() }.filter { it.isNotEmpty() }.distinct()
    }

    /** 两路候选按轮流配额合并,按 OSM id 和约 100 米的位置去重,最多 8 个。 */
    fun merge(lists: List<List<OSMGeocode.Place>>): List<OSMGeocode.Place> {
        val perList = if (lists.size > 1) maxOf(1, MAX_CANDIDATES / lists.size) else MAX_CANDIDATES
        val ids = mutableSetOf<String>()
        val spots = mutableSetOf<String>()
        val result = mutableListOf<OSMGeocode.Place>()
        fun add(p: OSMGeocode.Place): Boolean {
            val spot = String.format(Locale.ROOT, "%.3f,%.3f", p.point.latitude, p.point.longitude)
            if (result.size >= MAX_CANDIDATES || (p.id.isNotEmpty() && p.id in ids) || spot in spots) return false
            if (p.id.isNotEmpty()) ids += p.id
            spots += spot
            result += p
            return true
        }
        val leftovers = mutableListOf<OSMGeocode.Place>()
        for (list in lists) {
            var taken = 0
            for (p in list) if (taken < perList && add(p)) taken++ else leftovers += p
        }
        leftovers.forEach { add(it) }
        return result
    }

    data class Candidate(val name: String, val address: String, val type: String, val importance: Double, val distanceKm: Double?)
    data class Item(val id: String, val title: String, val place: String, val kind: String, val time: String?, val note: String, val candidates: List<Candidate>)

    sealed interface Choice {
        data class Pick(val index: Int) : Choice
        data object None : Choice
    }

    fun prompt(trip: String, items: List<Item>): String {
        val lines = mutableListOf(trip, "", "要定位的地点(同一天的地点一般离得不远):")
        for (item in items) {
            var head = "[id:${item.id}] ${item.kind}「${item.title}」"
            if (item.place.isNotEmpty() && item.place != item.title) head += "(地点:${item.place})"
            item.time?.let { head += " · $it" }
            item.note.trim().takeIf { it.isNotEmpty() }?.let { head += " · 备注:${it.take(60)}" }
            lines += head
            item.candidates.forEachIndexed { i, c ->
                var line = "  ${i + 1}. ${c.name} — ${c.address}"
                if (c.type.isNotEmpty()) line += " · 类型 ${c.type}"
                line += String.format(Locale.ROOT, " · 知名度 %.2f", c.importance)
                c.distanceKm?.let { line += String.format(Locale.ROOT, " · 距目的地 %.0f km", it) }
                lines += line
            }
        }
        return lines.joinToString("\n")
    }

    /** {"choices": [{"id", "pick"}]} → 每条的结论;pick 为 null/0 = 都不对,越界的丢掉。 */
    fun parse(payload: JSONObject, items: List<Item>): Map<String, Choice> {
        val arr = payload.optJSONArray("choices") ?: return emptyMap()
        val byId = items.associateBy { it.id.lowercase() }
        val result = linkedMapOf<String, Choice>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            var raw = o.optString("id").trim().removePrefix("[").removeSuffix("]").trim()
            if (raw.lowercase().startsWith("id:")) raw = raw.drop(3).trim()
            val item = byId[raw.lowercase()] ?: continue
            if (item.id in result) continue
            val pick = when (val v = o.opt("pick")) {
                is Number -> v.toInt()
                is String -> v.trim().toIntOrNull()
                else -> null
            }
            when {
                pick == null || pick == 0 -> result[item.id] = Choice.None
                pick in 1..item.candidates.size -> result[item.id] = Choice.Pick(pick - 1)
            }
        }
        return result
    }
}

/** OSRM 路线:请求、解析、在耗时不超过最快 20% 的里取最短(同 iOS RoadRoute)。 */
object RoadRoute {
    data class Option(val distance: Double, val duration: Double, val points: List<GeoPoint>)

    fun url(from: GeoPoint, to: GeoPoint): String {
        val profile = if (TravelGeo.prefersWalking(from, to)) "foot" else "car"
        val pts = listOf(from, to).joinToString(";") { String.format(Locale.ROOT, "%.6f,%.6f", it.longitude, it.latitude) }
        return "https://routing.openstreetmap.de/routed-$profile/route/v1/driving/$pts?overview=full&geometries=geojson&alternatives=true"
    }

    fun parse(json: String): List<Option> = runCatching {
        val o = JSONObject(json)
        if (o.optString("code") != "Ok") return emptyList()
        val routes = o.getJSONArray("routes")
        (0 until routes.length()).mapNotNull { i ->
            val r = routes.getJSONObject(i)
            val coords = r.optJSONObject("geometry")?.optJSONArray("coordinates") ?: return@mapNotNull null
            val pts = (0 until coords.length()).mapNotNull { j ->
                coords.optJSONArray(j)?.takeIf { it.length() >= 2 }?.let { GeoPoint(it.getDouble(1), it.getDouble(0)) }
            }
            if (pts.size < 2) null else Option(r.optDouble("distance"), r.optDouble("duration"), pts)
        }
    }.getOrDefault(emptyList())

    fun choose(options: List<Option>): Option? {
        val fastest = options.minOfOrNull { it.duration } ?: return null
        return options.filter { it.duration <= fastest * 1.2 }.minByOrNull { it.distance }
    }
}
