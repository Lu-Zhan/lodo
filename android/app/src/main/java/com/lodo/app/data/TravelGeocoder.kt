package com.lodo.app.data

import android.content.Context
import com.lodo.app.core.GeoPoint
import com.lodo.app.core.OSMGeocode
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

    /** 这趟旅行的判据:国家码 + 城市锚点(同 iOS geocodeContext)。 */
    suspend fun context(trip: TripEntity): GeoContext? {
        val region = PlaceRegion.isoCode(listOf(trip.country, trip.city, trip.title))
        val language = if (com.lodo.app.core.CurrentLang.value == com.lodo.app.core.Lang.EN) "en" else "zh"
        for (name in TravelDestination.cityCandidates(trip.city, trip.title)) {
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
        val ctx = context(trip) ?: return null
        var found = 0
        todo.forEachIndexed { i, m ->
            progress(i + 1, todo.size)
            lookUp(queries(m), ctx)?.let { p ->
                db.memoryDao().byUuid(m.uuid)?.let { db.memoryDao().upsert(it.copy(travelLatitude = p.latitude, travelLongitude = p.longitude)) }
                found++
            }
        }
        return found
    }

    data class RelocateResult(val updated: Int, val unchanged: Int, val notFound: Int, val noDestination: Boolean = false)

    /** 「刷新地点位置」:全部非交通项按地名重查,查到就覆盖、查不到保留原坐标(同 iOS relocateAll)。 */
    suspend fun relocateAll(trip: TripEntity, progress: (Int, Int) -> Unit): RelocateResult {
        missed.clear()
        val items = db.memoryDao().forTrip(trip.uuid).filter(::locatable)
        val ctx = context(trip) ?: return RelocateResult(0, 0, items.size, noDestination = true)
        var updated = 0; var same = 0; var miss = 0
        items.forEachIndexed { i, m ->
            progress(i + 1, items.size)
            val p = lookUp(queries(m), ctx)
            when {
                p == null -> miss++
                m.travelLatitude != null && TravelGeo.distance(p, GeoPoint(m.travelLatitude, m.travelLongitude ?: 0.0)) < 50 -> same++
                else -> {
                    db.memoryDao().byUuid(m.uuid)?.let { db.memoryDao().upsert(it.copy(travelLatitude = p.latitude, travelLongitude = p.longitude)) }
                    updated++
                }
            }
        }
        return RelocateResult(updated, same, miss)
    }

    /** 单条重查(先清掉它的「查不到」缓存);查不到保留原坐标,返回 false。 */
    suspend fun locate(trip: TripEntity, uuid: String): Boolean {
        val m = db.memoryDao().byUuid(uuid) ?: return false
        val ctx = context(trip) ?: return false
        queries(m).forEach { missed -= "${ctx.region}|${it.trim()}" }
        val p = lookUp(queries(m), ctx) ?: return false
        db.memoryDao().upsert(m.copy(travelLatitude = p.latitude, travelLongitude = p.longitude))
        return true
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
