package com.lodo.app.data

import android.content.Context
import com.lodo.app.core.GeoPoint
import com.lodo.app.ai.AIConfig
import com.lodo.app.core.OSMGeocode
import com.lodo.app.core.PlaceCalibration
import com.lodo.app.core.PlaceRegion
import com.lodo.app.core.RoadRoute
import com.lodo.app.core.TravelDestination
import com.lodo.app.core.TravelGeo
import com.lodo.app.core.TravelItemKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * 旅行地图的联网部分:地名查坐标(OpenStreetMap Nominatim)和路线(OSRM)。
 * 两个服务都是社区公共服务,按使用规定:可识别的 User-Agent、串行、每秒最多 1 次;
 * 发出去的只有地名 + 国家码 / 两端坐标。和 iOS 一样**只认这趟旅行所在国家的结果**,
 * 认不出国家时先验一个城市锚点、用锚点的国家;都认不出就不查(宁可不画也不画错)。
 */
class TravelGeocoder(private val context: Context, private val db: LodoDatabase) {
    private val client = OkHttpClient.Builder().connectTimeout(15, TimeUnit.SECONDS).readTimeout(20, TimeUnit.SECONDS).build()
    private val throttle = Mutex()
    private var lastRequest = 0L
    private val userAgent = "lodo-android/2.0 (https://github.com/Lu-Zhan/lodo)"

    /** 这一轮查不到的(重开 app 会再试;「刷新地点位置」会清掉)。 */
    private val missed = ConcurrentHashMap.newKeySet<String>()
    private val failedLegs = ConcurrentHashMap.newKeySet<String>()

    private suspend fun get(url: String): String? = withContext(Dispatchers.IO) {
        throttle.withLock {
            val wait = 1_100 - (System.currentTimeMillis() - lastRequest)
            if (wait > 0) delay(wait)
            lastRequest = System.currentTimeMillis()
            runCatching {
                client.newCall(Request.Builder().url(url).header("User-Agent", userAgent).build()).execute().use { r ->
                    if (r.isSuccessful) r.body?.string() else null
                }
            }.getOrNull()
        }
    }

    data class GeoContext(val region: String?, val anchor: GeoPoint?)

    /**
     * 每个目的地一份判据(同 iOS geocodeContexts):单目的地时就是原来那一份。
     * 只有第一个目的地会拿旅行名兜底(「东京四日」这类名字只说明主目的地)。
     */
    suspend fun contexts(trip: TripEntity): List<GeoContext> {
        val list = trip.destinations
        if (list.isEmpty()) return listOfNotNull(context(trip.city, trip.country, trip.title))
        return list.mapIndexedNotNull { i, d -> context(d.city, d.country, if (i == 0) trip.title else "") }
    }

    /** 一条行程项按哪几份判据去查:文字里点名了哪个目的地就先查它,其余按填写顺序(同 iOS lookUpWithContext)。 */
    private fun ordered(m: MemoryEntity, trip: TripEntity, ctxs: List<GeoContext>): List<GeoContext> {
        val dests = trip.destinations
        if (ctxs.size <= 1 || dests.size != ctxs.size) return ctxs
        val text = listOfNotNull(m.title, m.travelPlaceName, m.travelNote).joinToString(" ")
        return com.lodo.app.core.TripDestination.order(text, dests).map { ctxs[it] }
    }

    /** 主判据之外的目的地只认离它锚点 500 公里内的结果(lookUp 有锚点时本来就卡 500 公里)。 */
    private suspend fun lookUpAny(queries: List<String>, ctxs: List<GeoContext>): GeoPoint? {
        for (c in ctxs) lookUp(queries, c)?.let { return it }
        return null
    }

    /** 一个目的地的判据:国家码 + 城市锚点(同 iOS geocodeContext)。 */
    private suspend fun context(city: String, country: String, title: String): GeoContext? {
        val region = PlaceRegion.isoCode(listOf(country, city, title))
        val language = if (com.lodo.app.core.CurrentLang.value == com.lodo.app.core.Lang.EN) "en" else "zh"
        for (name in TravelDestination.cityCandidates(city, title)) {
            val queries = listOf(name) + if (name.none { it.code < 128 } && !name.endsWith("市") && !name.endsWith("县")) listOf(name + "市") else emptyList()
            for (q in queries) {
                val places = get(OSMGeocode.searchUrl(q, region, language = language))?.let(OSMGeocode::parse).orEmpty()
                val anchor = OSMGeocode.pick(places, q, region, null, areasOnly = true) ?: continue
                return GeoContext(region ?: anchor.countryCode, anchor.point)
            }
        }
        return region?.let { GeoContext(it, null) }
    }

    private suspend fun lookUp(queries: List<String>, ctx: GeoContext): GeoPoint? {
        val language = if (com.lodo.app.core.CurrentLang.value == com.lodo.app.core.Lang.EN) "en" else "zh"
        for (q in queries.map { it.trim() }.filter { it.isNotEmpty() }.distinct()) {
            val key = "${ctx.region}|$q"
            if (key in missed) continue
            val places = get(OSMGeocode.searchUrl(q, ctx.region, ctx.anchor, language))?.let(OSMGeocode::parse).orEmpty()
            val hit = OSMGeocode.pick(places, q, ctx.region, ctx.anchor, maxDistance = if (ctx.anchor != null) 500_000.0 else null)
            if (hit != null) return hit.point
            missed += key
        }
        return null
    }

    /** 住宿先查酒店本身,查不到退回它填的地点;地点先查地点名再查标题(同 iOS geocodeQueries)。 */
    private fun queries(m: MemoryEntity): List<String> = when (TravelItemKind.from(m.travelKind)) {
        TravelItemKind.LODGING -> listOf(TravelDestination.lodgingQuery(m.title), m.travelPlaceName.orEmpty())
        else -> listOf(m.travelPlaceName.orEmpty(), m.title)
    }

    private fun locatable(m: MemoryEntity) = m.isTravelItem && TravelItemKind.from(m.travelKind)?.isTransport == false

    /** 打开旅行详情时自动补:没坐标的非交通项,一次最多 25 条。返回补上的条数;null = 认不出目的地。 */
    suspend fun fillMissing(trip: TripEntity, progress: (Int, Int) -> Unit = { _, _ -> }): Int? {
        val todo = db.memoryDao().forTrip(trip.uuid).filter { locatable(it) && it.travelLatitude == null }.take(25)
        if (todo.isEmpty()) return 0
        val ctxs = contexts(trip).ifEmpty { return null }
        var found = 0
        todo.forEachIndexed { i, m ->
            progress(i + 1, todo.size)
            lookUpAny(queries(m), ordered(m, trip, ctxs))?.let { p ->
                db.memoryDao().byUuid(m.uuid)?.let { db.memoryDao().upsert(it.copy(travelLatitude = p.latitude, travelLongitude = p.longitude)) }
                found++
            }
        }
        return found
    }

    data class RelocateResult(
        val updated: Int, val unchanged: Int, val notFound: Int,
        val noDestination: Boolean = false, val aiPicked: Int = 0,
    )

    /** 进度:第几个 / 一共几个;calibrating = 候选都拿齐了,正在等 AI 一次性挑。 */
    data class Progress(val done: Int, val total: Int, val calibrating: Boolean = false)

    /** 「刷新地点位置」:全部非交通项按地名重查,选哪一个由 AI 从 OSM 候选里校准;
     * 查到就覆盖、查不到保留原坐标(同 iOS relocateAll)。 */
    suspend fun relocateAll(trip: TripEntity, config: AIConfig?, progress: (Progress) -> Unit): RelocateResult {
        missed.clear()
        val all = db.memoryDao().forTrip(trip.uuid).filter(::locatable)
        // 一次最多 25 条(Nominatim 每秒 1 次,两路查询);超出的算没查到,如实报。
        val items = all.take(25)
        if (items.isEmpty()) return RelocateResult(0, 0, 0)
        val ctxs = contexts(trip).ifEmpty { return RelocateResult(0, 0, items.size, noDestination = true) }
        val outcomes = calibratedLookUp(items, trip, ctxs, config, progress)
        var updated = 0; var same = 0; var miss = 0; var ai = 0
        for (m in items) {
            val (p, byAi) = outcomes[m.uuid] ?: run { miss++; null } ?: continue
            if (byAi) ai++
            if (m.travelLatitude != null && TravelGeo.distance(p, GeoPoint(m.travelLatitude, m.travelLongitude ?: 0.0)) < 50) same++
            else {
                db.memoryDao().byUuid(m.uuid)?.let { db.memoryDao().upsert(it.copy(travelLatitude = p.latitude, travelLongitude = p.longitude)) }
                updated++
            }
        }
        return RelocateResult(updated, same, miss + (all.size - items.size), aiPicked = ai)
    }

    /** 单条重查(先清掉它的「查不到」缓存),同样走 AI 校准;查不到保留原坐标,返回 false。 */
    suspend fun locate(trip: TripEntity, uuid: String, config: AIConfig?): Boolean {
        val m = db.memoryDao().byUuid(uuid) ?: return false
        val ctxs = contexts(trip).ifEmpty { return false }
        ctxs.forEach { c -> queries(m).forEach { missed -= "${c.region}|${it.trim()}" } }
        val (p, _) = calibratedLookUp(listOf(m), trip, ctxs, config) {}[m.uuid] ?: return false
        db.memoryDao().upsert(m.copy(travelLatitude = p.latitude, travelLongitude = p.longitude))
        return true
    }

    /** 一个查询词在 OSM 上的候选:过国家和名字校验,离锚点 200 公里内的排前面(同 iOS osmCandidates)。 */
    private suspend fun candidates(query: String, ctx: GeoContext): List<OSMGeocode.Place> {
        val q = query.trim()
        if (q.isEmpty() || (ctx.region == null && ctx.anchor == null)) return emptyList()
        val language = if (com.lodo.app.core.CurrentLang.value == com.lodo.app.core.Lang.EN) "en" else "zh"
        val places = get(OSMGeocode.searchUrl(q, ctx.region, ctx.anchor, language))?.let(OSMGeocode::parse).orEmpty()
        val valid = places.filter {
            PlaceRegion.matches(ctx.region, it.countryCode) && OSMGeocode.nameScore(q, it.names) >= OSMGeocode.MIN_NAME_SCORE &&
                (ctx.region != null || ctx.anchor == null || TravelGeo.distance(ctx.anchor, it.point) <= 500_000)
        }
        val anchor = ctx.anchor ?: return valid
        val near = valid.filter { TravelGeo.distance(anchor, it.point) <= OSMGeocode.NEARBY }
        return near + valid.filter { it !in near }
    }

    /**
     * AI 校准选点(同 iOS calibratedLookUp):每条先从 OSM 拿候选(标题和地点名两路合并),整趟
     * **一次**交给模型挑。退路:没候选 → 原来的自动查;没配 AI / 请求失败 / 没给结论 → 按知名度自动挑;
     * **AI 明说都不对 → 算没找到**(不再退回自动挑,那等于把否掉的又选回来)。
     * 返回每条的坐标和是不是 AI 挑的;每条的候选和结论写进 Logcat(tag TravelGeocode)。
     */
    private suspend fun calibratedLookUp(
        items: List<MemoryEntity>, trip: TripEntity, ctxs: List<GeoContext>, config: AIConfig?, progress: (Progress) -> Unit,
    ): Map<String, Pair<GeoPoint, Boolean>> {
        val out = linkedMapOf<String, Pair<GeoPoint, Boolean>>()
        val pending = mutableListOf<Pair<MemoryEntity, List<OSMGeocode.Place>>>()
        val ctxOf = mutableMapOf<String, GeoContext>()
        items.forEachIndexed { i, m ->
            val order = ordered(m, trip, ctxs)
            // 候选按排第一的目的地拿;它那边一条都没有再试下一个目的地。
            var ctx = order.first()
            var lists = emptyList<List<OSMGeocode.Place>>()
            for (c in order) {
                ctx = c
                lists = PlaceCalibration.queries(m.title, m.travelPlaceName.orEmpty(), m.travelKind == TravelItemKind.LODGING.raw).map { candidates(it, c) }
                if (lists.any { it.isNotEmpty() }) break
            }
            ctxOf[m.uuid] = ctx
            val merged = PlaceCalibration.merge(lists)
            if (merged.isNotEmpty()) pending += m to merged
            else lookUpAny(queries(m), order)?.let { out[m.uuid] = it to false }
            progress(Progress(i + 1, items.size))
        }
        if (pending.isEmpty()) return out
        val start = trip.startMillis.toLocalDateTime().toLocalDate()
        val calItems = pending.map { (m, places) ->
            PlaceCalibration.Item(
                id = m.uuid, title = m.title, place = m.travelPlaceName.orEmpty(),
                kind = if (m.travelKind == TravelItemKind.LODGING.raw) "住宿" else "地点",
                time = m.travelStartMillis?.toLocalDateTime()?.let { t ->
                    "第 ${java.time.temporal.ChronoUnit.DAYS.between(start, t.toLocalDate()) + 1} 天 " +
                        t.format(java.time.format.DateTimeFormatter.ofPattern("HH:mm"))
                },
                note = m.travelNote ?: m.summary,
                candidates = places.map { p ->
                    PlaceCalibration.Candidate(p.name, p.displayName, p.addressType, p.importance,
                        ctxOf[m.uuid]?.anchor?.let { TravelGeo.distance(it, p.point) / 1000 })
                },
            )
        }
        var choices: Map<String, PlaceCalibration.Choice> = emptyMap()
        if (config != null && !config.apiKey.isNullOrBlank()) {
            progress(Progress(items.size, items.size, calibrating = true))
            val fmt = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd")
            val tripLine = "旅行:${trip.title};目的地:${trip.destinationLabel.ifEmpty { "未填" }};" +
                "日期:${trip.startMillis.toLocalDateTime().format(fmt)} 至 ${trip.endMillis.toLocalDateTime().format(fmt)}"
            choices = runCatching { com.lodo.app.ai.DeepSeekClient.calibratePlaces(config, tripLine, calItems) }
                .onFailure { android.util.Log.w("TravelGeocode", "AI calibration failed: ${it.message}") }
                .getOrDefault(emptyMap())
        }
        for ((m, places) in pending) {
            val choice = choices[m.uuid]
            android.util.Log.i("TravelGeocode", "${m.title}: ${places.size} candidates, " + when (choice) {
                is PlaceCalibration.Choice.Pick -> "AI → #${choice.index + 1} ${places[choice.index].displayName}"
                PlaceCalibration.Choice.None -> "AI → none"
                null -> "auto"
            })
            places.forEachIndexed { i, p -> android.util.Log.i("TravelGeocode", "  #${i + 1} ${p.name} [${p.addressType} ${p.importance}] ${p.displayName}") }
            when (choice) {
                is PlaceCalibration.Choice.Pick -> out[m.uuid] = places[choice.index].point to true
                PlaceCalibration.Choice.None -> {}
                null -> (ctxOf[m.uuid]!!.let { c -> OSMGeocode.pick(places, queries(m).firstOrNull { it.isNotBlank() } ?: m.title, c.region, c.anchor) } ?: places.first())
                    .let { out[m.uuid] = it.point to false }
            }
        }
        return out
    }

    suspend fun setManual(uuid: String, point: GeoPoint) {
        db.memoryDao().byUuid(uuid)?.let { db.memoryDao().upsert(it.copy(travelLatitude = point.latitude, travelLongitude = point.longitude)) }
    }

    // ---------------- 路线 ----------------

    private val routeFile get() = File(context.filesDir, "travel-routes.json")
    private val routeCache: LinkedHashMap<String, List<GeoPoint>> by lazy { loadRoutes() }

    private fun loadRoutes(): LinkedHashMap<String, List<GeoPoint>> {
        val map = LinkedHashMap<String, List<GeoPoint>>()
        runCatching {
            val o = JSONObject(routeFile.readText())
            o.keys().forEach { k ->
                val flat = o.getJSONArray(k)
                map[k] = (0 until flat.length() / 2).map { GeoPoint(flat.getDouble(it * 2), flat.getDouble(it * 2 + 1)) }
            }
        }
        return map
    }

    private fun saveRoutes() = runCatching {
        val o = JSONObject()
        routeCache.forEach { (k, pts) -> o.put(k, JSONArray().apply { pts.forEach { put(it.latitude); put(it.longitude) } }) }
        routeFile.writeText(o.toString())
    }

    /** 已记下的路线(地点没动就直接画,重开 app 也不再请求)。 */
    fun cachedLeg(a: GeoPoint, b: GeoPoint): List<GeoPoint>? = synchronized(routeCache) { routeCache[TravelGeo.legKey(a, b)] }

    /** 规划一段真实路线;失败返回 null(调用方退回虚线直线,失败的这一轮不再试)。最多缓存 500 段。 */
    suspend fun leg(a: GeoPoint, b: GeoPoint): List<GeoPoint>? {
        val key = TravelGeo.legKey(a, b)
        cachedLeg(a, b)?.let { return it }
        if (key in failedLegs) return null
        val option = get(RoadRoute.url(a, b))?.let { RoadRoute.choose(RoadRoute.parse(it)) }
        if (option == null) { failedLegs += key; return null }
        synchronized(routeCache) {
            routeCache[key] = option.points
            while (routeCache.size > 500) routeCache.remove(routeCache.keys.first())
        }
        saveRoutes()
        return option.points
    }
}
