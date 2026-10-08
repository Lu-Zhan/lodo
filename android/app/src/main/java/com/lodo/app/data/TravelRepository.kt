package com.lodo.app.data

import com.lodo.app.ai.DeepSeekClient
import com.lodo.app.ai.TripEdit
import com.lodo.app.ai.TripPlanItem
import com.lodo.app.ai.TripPlanProposal
import com.lodo.app.core.TransportDetails
import com.lodo.app.core.TravelEntry
import com.lodo.app.core.TravelItemKind
import com.lodo.app.core.TravelPlan
import com.lodo.app.ui.L
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.temporal.ChronoUnit
import kotlin.math.abs

fun MemoryEntity.travelEntry(): TravelEntry? {
    if (!isTravelItem) return null
    val kind = TravelItemKind.from(travelKind) ?: return null
    val transport = if (kind.isTransport) TransportDetails.decode(travelFlightData) else null
    // 交通的时刻和归日按出发地/到达地的当地时间(同 iOS TravelPlan.localDay);没填时区按手机时区。
    fun local(ms: Long?, tz: String?) = ms?.let {
        val zone = tz?.let { id -> runCatching { java.time.ZoneId.of(id) }.getOrNull() } ?: java.time.ZoneId.systemDefault()
        java.time.Instant.ofEpochMilli(it).atZone(zone).toLocalDateTime()
    }
    return TravelEntry(
        id = uuid, kind = kind, title = title, note = travelNote ?: summary,
        start = local(travelStartMillis, transport?.departureTimeZone), end = local(travelEndMillis, transport?.arrivalTimeZone),
        price = travelPrice, currency = travelCurrency ?: "CNY", placeName = travelPlaceName,
        originName = travelOriginName, code = travelCode, latitude = travelLatitude, longitude = travelLongitude,
        transport = transport,
        hasAttachment = kindEnum == MemoryKind.LINK,
    )
}

/** 写入一份规划的记录(写进哪次旅行、是不是那次新建的、建了哪几项),撤销靠它。 */
data class TripPlanRecord(val tripUuid: String, val createdTrip: Boolean, val itemUuids: List<String>) {
    fun toJson(): JSONObject = JSONObject().put("tripUuid", tripUuid).put("createdTrip", createdTrip)
        .put("itemUuids", JSONArray(itemUuids))

    companion object {
        fun from(o: JSONObject?) = o?.let {
            TripPlanRecord(it.getString("tripUuid"), it.optBoolean("createdTrip"),
                it.optJSONArray("itemUuids")?.let { a -> (0 until a.length()).map { i -> a.getString(i) } } ?: emptyList())
        }
    }
}

/** 一次 edit_trip 的结果:删掉/改掉那几项的整份快照 + 新增的 uuid + 没改成的(同 iOS TripEditRecord)。 */
data class TripEditRecord(
    val tripUuid: String,
    val tripTitle: String,
    val summary: String,
    val removed: List<MemoryEntity>,
    val addedUuids: List<String>,
    val addedTitles: List<String>,
    val updatedBefore: List<MemoryEntity>,
    val updatedTitles: List<String>,
    val skipped: List<String>,
    val reverted: Boolean = false,
) {
    val hasChanges get() = removed.isNotEmpty() || addedUuids.isNotEmpty() || updatedBefore.isNotEmpty()

    val transcript: String
        get() {
            val parts = mutableListOf("调整「$tripTitle」:$summary")
            if (removed.isNotEmpty()) parts += "删掉 " + removed.joinToString("、") { it.title }
            if (addedTitles.isNotEmpty()) parts += "新增 " + addedTitles.joinToString("、")
            if (updatedTitles.isNotEmpty()) parts += "修改 " + updatedTitles.joinToString("、")
            if (skipped.isNotEmpty()) parts += "没改成:" + skipped.joinToString("、")
            if (reverted) parts += "(已撤销)"
            return parts.joinToString(";")
        }

    fun toJson(): String = JSONObject().put("tripUuid", tripUuid).put("tripTitle", tripTitle).put("summary", summary)
        .put("removed", JSONArray(removed.map { it.toJson() })).put("addedUuids", JSONArray(addedUuids))
        .put("addedTitles", JSONArray(addedTitles)).put("updatedBefore", JSONArray(updatedBefore.map { it.toJson() }))
        .put("updatedTitles", JSONArray(updatedTitles)).put("skipped", JSONArray(skipped)).put("reverted", reverted).toString()

    companion object {
        fun decode(json: String?): TripEditRecord? = json?.let {
            runCatching {
                val o = JSONObject(it)
                fun strs(k: String) = o.optJSONArray(k)?.let { a -> (0 until a.length()).map { i -> a.getString(i) } } ?: emptyList()
                fun mems(k: String) = o.optJSONArray(k)?.let { a -> (0 until a.length()).map { i -> memoryFromJson(a.getJSONObject(i)) } } ?: emptyList()
                TripEditRecord(o.getString("tripUuid"), o.optString("tripTitle"), o.optString("summary"), mems("removed"),
                    strs("addedUuids"), strs("addedTitles"), mems("updatedBefore"), strs("updatedTitles"), strs("skipped"),
                    o.optBoolean("reverted"))
            }.getOrNull()
        }
    }
}

/** 旅行:旅行本身是 TripEntity,行程项是打了「旅行」标签的记忆条目(同 iOS TravelStore)。 */
class TravelRepository(private val db: LodoDatabase, private val memories: MemoryRepository) {
    private val trips get() = db.tripDao()
    private val mem get() = db.memoryDao()

    fun observeTrips() = trips.observeAll()
    fun observeTrip(uuid: String) = trips.observe(uuid)
    fun observeItems(tripUuid: String) = mem.observeForTrip(tripUuid)
    fun observePacking(tripUuid: String) = trips.observePacking(tripUuid)
    suspend fun allTrips() = trips.all()
    suspend fun trip(uuid: String) = trips.byUuid(uuid)

    /** 只返回有行程类型的行程项(旅行文件不算)。 */
    suspend fun entries(tripUuid: String): List<TravelEntry> = mem.forTrip(tripUuid).mapNotNull { it.travelEntry() }

    suspend fun saveTrip(trip: TripEntity) = trips.upsert(trip)

    /** 删旅行:行程项一起删,文件只摘下不删(同 iOS),清单一起删。 */
    suspend fun deleteTrip(uuid: String) {
        for (m in mem.forTrip(uuid)) {
            if (m.isTravelItem) memories.delete(m.uuid) else mem.upsert(m.copy(travelTripUuid = null))
        }
        trips.deletePackingForTrip(uuid)
        trips.delete(uuid)
    }

    fun newItem(tripUuid: String, item: TripPlanItem): MemoryEntity {
        val source = listOfNotNull(item.title, item.placeName, item.code, item.note.takeIf { it.isNotBlank() }).joinToString(" · ")
        return MemoryEntity.create(
            kind = MemoryKind.TEXT, sourceText = source, title = item.title, summary = item.note,
            tags = listOf(MemoryEntity.travelTagName), status = MemoryStatus.READY,
        ).copy(
            travelTripUuid = tripUuid, travelKind = item.kind.raw,
            travelStartMillis = item.start?.toEpochMillis(), travelEndMillis = item.end?.toEpochMillis(),
            travelPlaceName = item.placeName, travelCode = item.code, travelPrice = item.price,
            travelCurrency = item.currency, travelNote = item.note,
        )
    }

    suspend fun saveItem(item: MemoryEntity) = mem.upsert(item)
    suspend fun deleteItem(uuid: String) = memories.delete(uuid)

    /** 按名字挑旅行:完全一致 > 包含;名字为空挑正在进行的、最近要出发的、最近结束的(同 iOS pickTrip)。 */
    suspend fun pickTrip(name: String): TripEntity? {
        val all = trips.all()
        val n = name.trim()
        if (n.isNotEmpty()) {
            all.firstOrNull { it.title.equals(n, true) }?.let { return it }
            all.firstOrNull { it.title.contains(n, true) || n.contains(it.title, true) }?.let { return it }
            all.firstOrNull { it.city.isNotBlank() && n.contains(it.city) }?.let { return it }
        }
        return featured(all)
    }

    fun featured(all: List<TripEntity>, now: LocalDateTime = LocalDateTime.now()): TripEntity? {
        val today = now.toLocalDate()
        fun start(t: TripEntity) = t.startMillis.toLocalDateTime().toLocalDate()
        fun end(t: TripEntity) = t.endMillis.toLocalDateTime().toLocalDate()
        return all.firstOrNull { !today.isBefore(start(it)) && !today.isAfter(end(it)) }
            ?: all.filter { start(it).isAfter(today) }.minByOrNull { start(it) }
            ?: all.maxByOrNull { end(it) }
    }

    fun days(trip: TripEntity): List<LocalDate> =
        TravelPlan.days(trip.startMillis.toLocalDateTime().toLocalDate(), trip.endMillis.toLocalDateTime().toLocalDate())

    /** read_trip:读到的摘要;一条旅行都没有时如实说。 */
    suspend fun readTrip(name: String, includeIds: Boolean): String {
        val trip = pickTrip(name) ?: return "用户还没有记录任何旅行。"
        val entries = entries(trip.uuid)
        var text = TravelPlan.promptSummary(trip.title, days(trip), entries, includeIds)
        val f = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd")
        text = "旅行「${trip.title}」${trip.startMillis.toLocalDateTime().format(f)} 至 ${trip.endMillis.toLocalDateTime().format(f)}" +
            (if (trip.destinations.isNotEmpty()) ",目的地 ${trip.destinationLabel}" else "") +
            "\n" + text
        val travelers = com.lodo.app.core.TripTraveler.decode(trip.travelersJson)
        if (travelers.isNotEmpty()) text += "\n同行人:" + travelers.joinToString("、") { it.name }
        val others = trips.all().filter { it.uuid != trip.uuid }.take(8)
        if (others.isNotEmpty()) text += "\n其他旅行:" + others.joinToString("、") { it.title }
        return text
    }

    /** 写入规划:旅行名完全一致就写进那次(日期不动),否则新建一次(同 iOS applyPlan)。 */
    suspend fun applyPlan(plan: TripPlanProposal): TripPlanRecord {
        val existing = trips.all().firstOrNull { it.title.trim().equals(plan.tripTitle.trim(), true) }
        val trip = existing ?: TripEntity(
            title = plan.tripTitle, startMillis = plan.startDate.atStartOfDay().toEpochMillis(),
            endMillis = plan.endDate.atStartOfDay().toEpochMillis(), city = plan.city ?: "", country = plan.country ?: "",
            notes = plan.summary,
        )
        if (existing == null) trips.upsert(trip)
        else if (existing.city.isBlank() && existing.country.isBlank() && (plan.city != null || plan.country != null)) {
            trips.upsert(existing.copy(city = plan.city ?: "", country = plan.country ?: ""))
        }
        val created = plan.items.map { newItem(trip.uuid, it).also { item -> mem.upsert(item) }.uuid }
        return TripPlanRecord(trip.uuid, existing == null, created)
    }

    /** 撤销写入:删掉那次写入的行程项;旅行是那次新建的且删完变空才连旅行一起删。 */
    suspend fun revertPlan(record: TripPlanRecord) {
        record.itemUuids.forEach { memories.delete(it) }
        if (record.createdTrip && mem.forTrip(record.tripUuid).isEmpty()) {
            trips.deletePackingForTrip(record.tripUuid)
            trips.delete(record.tripUuid)
        }
    }

    /** 执行 edit_trip:航班不删不改、带附件的不删,都记进 skipped(同 iOS applyEdit)。 */
    suspend fun applyEdit(edit: TripEdit): TripEditRecord {
        val all = trips.all()
        val idsInEdit = edit.removeIds + edit.updates.map { it.id }
        val byId = idsInEdit.firstNotNullOfOrNull { id -> mem.byUuid(id)?.takeIf { it.isTravelItem } }
        val trip = byId?.travelTripUuid?.let { trips.byUuid(it) } ?: pickTrip(edit.tripTitle)
            ?: throw IllegalStateException(L("找不到要调整的旅行", "Trip not found"))
        val items = mem.forTrip(trip.uuid).filter { it.isTravelItem }.associateBy { it.uuid }
        val skipped = mutableListOf<String>()
        val removed = mutableListOf<MemoryEntity>()
        for (id in edit.removeIds) {
            val m = items[com.lodo.app.ai.canonicalId(id, items.keys) ?: ""]
            when {
                m == null -> skipped += L("找不到要删的那一项", "An item to remove wasn't found")
                m.travelKind == TravelItemKind.FLIGHT.raw -> skipped += L("航班「${m.title}」不能在这里删", "Flight \"${m.title}\" can't be removed here")
                m.kindEnum == MemoryKind.LINK -> skipped += L("「${m.title}」带附件,没删", "\"${m.title}\" has an attachment, kept")
                else -> { removed += m; memories.delete(m.uuid) }
            }
        }
        val before = mutableListOf<MemoryEntity>()
        val updatedTitles = mutableListOf<String>()
        for (u in edit.updates) {
            val m = items[com.lodo.app.ai.canonicalId(u.id, items.keys) ?: ""]
            if (m == null) { skipped += L("找不到要改的那一项", "An item to update wasn't found"); continue }
            // 航班的时刻座位来自订单不让改,但可以补费用和备注("机票花了 3200")。
            if (m.travelKind == TravelItemKind.FLIGHT.raw && !u.touchesOnlyCostOrNote) {
                skipped += L("航班「${m.title}」不能在这里改", "Flight \"${m.title}\" can't be edited here"); continue
            }
            var start = m.travelStartMillis
            var end = m.travelEndMillis
            u.start?.let { s ->
                val ms = s.toEpochMillis()
                // 只挪开始时间没给结束时间时保持原时长。
                if (u.end == null && start != null && end != null) end = ms + (end - start)
                start = ms
            }
            u.end?.let { end = it.toEpochMillis() }
            val placeChanged = u.placeName != null && u.placeName != m.travelPlaceName
            val updated = m.copy(
                title = u.title ?: m.title, travelNote = u.note ?: m.travelNote, summary = u.note ?: m.summary,
                travelStartMillis = start, travelEndMillis = end, travelPlaceName = u.placeName ?: m.travelPlaceName,
                travelLatitude = if (placeChanged) null else m.travelLatitude,
                travelLongitude = if (placeChanged) null else m.travelLongitude,
                travelPrice = u.price ?: m.travelPrice,
                // 给了价格没给币种:沿用原来的币种。
                travelCurrency = u.currency ?: m.travelCurrency,
            )
            mem.upsert(updated)
            before += m
            // 改了费用时结果卡片上把金额写出来,不然"改了 X"看不出改的是什么。
            updatedTitles += if (u.price != null) {
                "${updated.title} · ${formatPrice(u.price, updated.travelCurrency)}"
            } else {
                updated.title
            }
        }
        val added = edit.additions.map { newItem(trip.uuid, it).also { item -> mem.upsert(item) } }
        return TripEditRecord(trip.uuid, trip.title, edit.summary, removed, added.map { it.uuid }, added.map { it.title },
            before, updatedTitles, skipped)
    }

    private fun formatPrice(price: Double, currency: String?): String {
        val amount = if (price % 1.0 == 0.0) price.toLong().toString() else String.format(java.util.Locale.US, "%.2f", price)
        return listOfNotNull(amount, currency).joinToString(" ")
    }

    suspend fun revertEdit(record: TripEditRecord) {
        record.addedUuids.forEach { memories.delete(it) }
        record.updatedBefore.forEach { mem.upsert(it) }
        record.removed.forEach { mem.upsert(it) }
    }

    /** 已有的同一班(航班号相同、出发相差 20 小时内),导入新截图时更新而不是新建(同 iOS existingFlight)。 */
    suspend fun existingTransport(tripUuid: String, item: DeepSeekClient.ParsedTravelItem): MemoryEntity? {
        val code = item.code?.replace(" ", "")?.uppercase() ?: return null
        if (!item.kind.isTransport) return null
        return mem.forTrip(tripUuid).firstOrNull { m ->
            m.travelCode?.replace(" ", "")?.uppercase() == code && (item.start == null || m.travelStartMillis == null ||
                abs(ChronoUnit.HOURS.between(m.travelStartMillis.toLocalDateTime(), item.start)) < 20)
        }
    }

    /** 导入订单(确认过的):同一班合并补充信息,基本信息只在原来空着时才填;其余新建。 */
    suspend fun importItems(tripUuid: String, parsed: List<DeepSeekClient.ParsedTravelItem>): Int {
        var count = 0
        for (p in parsed) {
            val existing = existingTransport(tripUuid, p)
            if (existing != null) {
                val old = TransportDetails.decode(existing.travelFlightData) ?: TransportDetails()
                val merged = p.transport?.let { old.merged(it) } ?: old
                mem.upsert(existing.copy(
                    travelFlightData = merged.toJson(),
                    travelStartMillis = existing.travelStartMillis ?: p.start?.toEpochMillis(),
                    travelEndMillis = existing.travelEndMillis ?: p.end?.toEpochMillis(),
                    travelPlaceName = existing.travelPlaceName ?: p.placeName,
                    travelOriginName = existing.travelOriginName ?: p.originName,
                    travelPrice = existing.travelPrice ?: p.price,
                    travelCurrency = existing.travelCurrency ?: p.currency,
                ))
            } else {
                val item = newItem(tripUuid, TripPlanItem(p.kind, p.title, p.note, p.start, p.end, p.placeName, p.price, p.currency, p.code))
                    .copy(travelOriginName = p.originName, travelFlightData = p.transport?.toJson())
                mem.upsert(item)
            }
            count++
        }
        return count
    }

    // ---- 文件(和记忆库是同一份) ----

    suspend fun attachMemory(tripUuid: String, memoryUuid: String) {
        mem.byUuid(memoryUuid)?.let { m ->
            val tags = (m.tagsList + MemoryEntity.travelTagName).distinct()
            mem.upsert(m.copy(travelTripUuid = tripUuid, tags = joinCsv(tags)))
        }
    }

    suspend fun detachFile(memoryUuid: String) {
        mem.byUuid(memoryUuid)?.let { mem.upsert(it.copy(travelTripUuid = null)) }
    }

    // ---- 行李清单 ----

    suspend fun addPacking(tripUuid: String, titles: List<Pair<String, String>>) {
        val start = trips.packing(tripUuid).size
        titles.forEachIndexed { i, (title, category) ->
            trips.upsertPacking(PackingEntity(tripUuid = tripUuid, title = title, category = category, sortIndex = start + i))
        }
    }

    suspend fun togglePacked(item: PackingEntity) = trips.upsertPacking(item.copy(packed = !item.packed))
    suspend fun deletePacking(uuid: String) = trips.deletePacking(uuid)
    suspend fun packing(tripUuid: String) = trips.packing(tripUuid)

    /** 给 AI 的旅行摘要(备注生成 / 行李建议用)。 */
    suspend fun aiSummary(trip: TripEntity): String {
        val f = java.time.format.DateTimeFormatter.ofPattern("yyyy-MM-dd")
        return "旅行:${trip.title}\n日期:${trip.startMillis.toLocalDateTime().format(f)} 至 ${trip.endMillis.toLocalDateTime().format(f)}\n" +
            "目的地:${trip.destinationLabel.ifEmpty { "未填" }}\n" +
            TravelPlan.promptSummary(trip.title, days(trip), entries(trip.uuid))
    }
}
