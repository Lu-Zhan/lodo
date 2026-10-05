package com.lodo.app.data

import org.json.JSONObject

/*
 * 实体 ↔ JSON:AI 结果卡片的撤销快照和 zip 备份共用这一份。新字段一律用 opt 系列和 has 判断兜底,
 * 老备份/老快照缺字段照样能读(同 iOS BackupData 的 decodeIfPresent)。
 */

internal fun JSONObject.str(key: String): String? = if (!has(key) || isNull(key)) null else optString(key)
internal fun JSONObject.dbl(key: String): Double? = if (!has(key) || isNull(key)) null else optDouble(key).takeIf { !it.isNaN() }
internal fun JSONObject.lng(key: String): Long? = if (!has(key) || isNull(key)) null else optLong(key)
internal fun JSONObject.int(key: String): Int? = if (!has(key) || isNull(key)) null else optInt(key)
private fun Any?.orNull(): Any = this ?: JSONObject.NULL

fun TaskEntity.toJson(): JSONObject = JSONObject()
    .put("uuid", uuid).put("title", title)
    .put("remindAtMillis", remindAtMillis).put("durationMinutes", durationMinutes)
    .put("allDay", allDay).put("repeatType", repeatType)
    .put("repeatDays", repeatDays).put("repeatTimes", repeatTimes)
    .put("status", status).put("phase", phase)
    .put("nextRemindAtMillis", nextRemindAtMillis).put("createdAtMillis", createdAtMillis)
    .put("doneAtMillis", doneAtMillis.orNull()).put("ignoreStreak", ignoreStreak)
    .put("pinned", pinned).put("pinnedAtMillis", pinnedAtMillis.orNull()).put("project", project)

fun taskFromJson(o: JSONObject) = TaskEntity(
    uuid = o.getString("uuid"), title = o.getString("title"),
    remindAtMillis = o.getLong("remindAtMillis"), durationMinutes = o.optInt("durationMinutes"),
    allDay = o.optBoolean("allDay"), repeatType = o.optString("repeatType", "none"),
    repeatDays = o.optString("repeatDays"), repeatTimes = o.optString("repeatTimes"),
    status = o.optString("status", "pending"), phase = o.optString("phase", "start"),
    nextRemindAtMillis = o.optLong("nextRemindAtMillis", o.getLong("remindAtMillis")),
    createdAtMillis = o.optLong("createdAtMillis", o.getLong("remindAtMillis")),
    doneAtMillis = o.lng("doneAtMillis"), ignoreStreak = o.optInt("ignoreStreak", 0),
    pinned = o.optBoolean("pinned", false), pinnedAtMillis = o.lng("pinnedAtMillis"),
    project = o.optString("project", ""),
)

fun MemoryEntity.toJson(): JSONObject = JSONObject()
    .put("uuid", uuid).put("kind", kind).put("title", title).put("summary", summary)
    .put("tags", tags).put("sourceText", sourceText).put("urlString", urlString.orNull())
    .put("status", status).put("createdAtMillis", createdAtMillis)
    .put("assetValue", assetValue.orNull()).put("assetCurrency", assetCurrency.orNull())
    .put("assetLiability", assetLiability.orNull()).put("assetInterestRate", assetInterestRate.orNull())
    .put("contactNickname", contactNickname.orNull()).put("contactPhone", contactPhone.orNull())
    .put("contactEmail", contactEmail.orNull()).put("contactBirthdayMillis", contactBirthdayMillis.orNull())
    .put("contactPreferences", contactPreferences.orNull())
    .put("assetUpdatedAtMillis", assetUpdatedAtMillis.orNull())
    .put("travelTripUuid", travelTripUuid.orNull()).put("travelKind", travelKind.orNull())
    .put("travelStartMillis", travelStartMillis.orNull()).put("travelEndMillis", travelEndMillis.orNull())
    .put("travelPlaceName", travelPlaceName.orNull()).put("travelOriginName", travelOriginName.orNull())
    .put("travelCode", travelCode.orNull()).put("travelPrice", travelPrice.orNull())
    .put("travelCurrency", travelCurrency.orNull()).put("travelLatitude", travelLatitude.orNull())
    .put("travelLongitude", travelLongitude.orNull()).put("travelFlightData", travelFlightData.orNull())
    .put("travelNote", travelNote.orNull())
    .put("menuSourceLanguage", menuSourceLanguage.orNull()).put("menuTargetLanguage", menuTargetLanguage.orNull())
    .put("menuCurrency", menuCurrency.orNull())

fun memoryFromJson(o: JSONObject) = MemoryEntity(
    uuid = o.getString("uuid"), kind = o.optString("kind", "text"), title = o.optString("title"),
    summary = o.optString("summary"), tags = o.optString("tags"), sourceText = o.optString("sourceText"),
    urlString = o.str("urlString"), status = o.optString("status", "ready"),
    createdAtMillis = o.optLong("createdAtMillis", System.currentTimeMillis()),
    assetValue = o.dbl("assetValue"), assetCurrency = o.str("assetCurrency"),
    assetLiability = o.dbl("assetLiability"), assetInterestRate = o.dbl("assetInterestRate"),
    contactNickname = o.str("contactNickname"), contactPhone = o.str("contactPhone"),
    contactEmail = o.str("contactEmail"), contactBirthdayMillis = o.lng("contactBirthdayMillis"),
    contactPreferences = o.str("contactPreferences"), assetUpdatedAtMillis = o.lng("assetUpdatedAtMillis"),
    travelTripUuid = o.str("travelTripUuid"), travelKind = o.str("travelKind"),
    travelStartMillis = o.lng("travelStartMillis"), travelEndMillis = o.lng("travelEndMillis"),
    travelPlaceName = o.str("travelPlaceName"), travelOriginName = o.str("travelOriginName"),
    travelCode = o.str("travelCode"), travelPrice = o.dbl("travelPrice"), travelCurrency = o.str("travelCurrency"),
    travelLatitude = o.dbl("travelLatitude"), travelLongitude = o.dbl("travelLongitude"),
    travelFlightData = o.str("travelFlightData"), travelNote = o.str("travelNote"),
    menuSourceLanguage = o.str("menuSourceLanguage"), menuTargetLanguage = o.str("menuTargetLanguage"),
    menuCurrency = o.str("menuCurrency"),
)

fun FinanceEntity.toJson(): JSONObject = JSONObject()
    .put("uuid", uuid).put("kind", kind).put("title", title).put("amount", amount.orNull())
    .put("currency", currency).put("cadence", cadence).put("dayOfMonth", dayOfMonth.orNull())
    .put("statementDay", statementDay.orNull()).put("institution", institution)
    .put("endDateMillis", endDateMillis.orNull()).put("notes", notes).put("remindEnabled", remindEnabled)
    .put("sortIndex", sortIndex).put("updatedAtMillis", updatedAtMillis).put("createdAtMillis", createdAtMillis)

fun financeFromJson(o: JSONObject) = FinanceEntity(
    uuid = o.getString("uuid"), kind = o.optString("kind", "income"), title = o.optString("title"),
    amount = o.dbl("amount"), currency = o.optString("currency", "CNY"), cadence = o.optString("cadence", "monthly"),
    dayOfMonth = o.int("dayOfMonth"), statementDay = o.int("statementDay"), institution = o.optString("institution"),
    endDateMillis = o.lng("endDateMillis"), notes = o.optString("notes"), remindEnabled = o.optBoolean("remindEnabled", true),
    sortIndex = o.optInt("sortIndex"), updatedAtMillis = o.optLong("updatedAtMillis", System.currentTimeMillis()),
    createdAtMillis = o.optLong("createdAtMillis", System.currentTimeMillis()),
)

fun TripEntity.toJson(): JSONObject = JSONObject()
    .put("uuid", uuid).put("title", title).put("emoji", emoji).put("startMillis", startMillis)
    .put("endMillis", endMillis).put("city", city).put("country", country).put("notes", notes)
    .put("travelersJson", travelersJson).put("createdAtMillis", createdAtMillis)

fun tripFromJson(o: JSONObject) = TripEntity(
    uuid = o.getString("uuid"), title = o.optString("title"), emoji = o.optString("emoji"),
    startMillis = o.getLong("startMillis"), endMillis = o.optLong("endMillis", o.getLong("startMillis")),
    city = o.optString("city"), country = o.optString("country"), notes = o.optString("notes"),
    travelersJson = o.optString("travelersJson"), createdAtMillis = o.optLong("createdAtMillis", System.currentTimeMillis()),
)

fun PackingEntity.toJson(): JSONObject = JSONObject()
    .put("uuid", uuid).put("tripUuid", tripUuid).put("title", title).put("category", category)
    .put("packed", packed).put("sortIndex", sortIndex).put("createdAtMillis", createdAtMillis)

fun packingFromJson(o: JSONObject) = PackingEntity(
    uuid = o.getString("uuid"), tripUuid = o.getString("tripUuid"), title = o.optString("title"),
    category = o.optString("category", "其他"), packed = o.optBoolean("packed"), sortIndex = o.optInt("sortIndex"),
    createdAtMillis = o.optLong("createdAtMillis", System.currentTimeMillis()),
)

fun MenuDishEntity.toJson(): JSONObject = JSONObject()
    .put("uuid", uuid).put("menuUuid", menuUuid).put("originalName", originalName)
    .put("translatedName", translatedName).put("intro", intro).put("category", category)
    .put("price", price.orNull()).put("selected", selected).put("sortIndex", sortIndex)

fun menuDishFromJson(o: JSONObject) = MenuDishEntity(
    uuid = o.getString("uuid"), menuUuid = o.getString("menuUuid"), originalName = o.optString("originalName"),
    translatedName = o.optString("translatedName"), intro = o.optString("intro"), category = o.optString("category"),
    price = o.dbl("price"), selected = o.optBoolean("selected"), sortIndex = o.optInt("sortIndex"),
)

fun NewsFeedEntity.toJson(): JSONObject = JSONObject()
    .put("uuid", uuid).put("title", title).put("url", url).put("siteUrl", siteUrl).put("kind", kind)
    .put("enabled", enabled).put("createdAtMillis", createdAtMillis)

fun newsFeedFromJson(o: JSONObject) = NewsFeedEntity(
    uuid = o.getString("uuid"), title = o.optString("title"), url = o.getString("url"), siteUrl = o.optString("siteUrl"),
    kind = o.optString("kind", "news"), enabled = o.optBoolean("enabled", true),
    createdAtMillis = o.optLong("createdAtMillis", System.currentTimeMillis()),
)
