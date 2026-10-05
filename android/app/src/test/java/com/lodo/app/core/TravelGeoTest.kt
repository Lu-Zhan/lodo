package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime

/** 旅行地图纯逻辑,同 iOS 的 PlaceRegionTests / OSMGeocodeTests / TravelDestinationTests / RoadRouteTests。 */
class TravelGeoTest {
    @Test
    fun regionFromChineseAndEnglish() {
        assertEquals("JP", PlaceRegion.isoCode("日本"))
        assertEquals("JP", PlaceRegion.isoCode(listOf("", null, "Japan trip")))
        assertEquals("CN", PlaceRegion.isoCode("中国"))
        assertNull(PlaceRegion.isoCode("毕业旅行"))
        assertTrue(PlaceRegion.matches("CN", "HK"))
        assertFalse(PlaceRegion.matches("JP", "CN"))
        assertTrue(PlaceRegion.matches("JP", null))
    }

    @Test
    fun destinationCandidates() {
        assertEquals("东京", TravelDestination.stripped("东京四日"))
        assertEquals("京都", TravelDestination.stripped("京都三日游"))
        assertEquals("旅行", TravelDestination.stripped("旅行"))
        assertEquals("新宿", TravelDestination.lodgingQuery("住新宿一带"))
        assertEquals(listOf("大阪", "京都"), TravelDestination.cityCandidates("大阪", "京都之旅"))
    }

    private fun place(name: String, lat: Double, lon: Double, cc: String, importance: Double, type: String = "attraction") =
        OSMGeocode.Place(name, name, GeoPoint(lat, lon), cc, listOf(name), type, importance)

    @Test
    fun nameScoreRejectsPartialWords() {
        assertEquals(1.0, OSMGeocode.nameScore("清水寺", listOf("清水寺")), 0.0)
        assertTrue(OSMGeocode.nameScore("新宿王子酒店", listOf("酒店")) < OSMGeocode.MIN_NAME_SCORE)
        assertEquals(1.0, OSMGeocode.nameScore("Senso-ji", listOf("Sensō-ji")), 0.0)
    }

    @Test
    fun pickPrefersNearAnchorThenImportance() {
        val kyoto = GeoPoint(35.01, 135.77)
        val fukuoka = place("清水寺", 33.59, 130.40, "JP", 0.6)
        val famous = place("清水寺", 34.99, 135.78, "JP", 0.5)
        val china = place("清水寺", 30.2, 120.1, "CN", 0.9)
        assertEquals(famous, OSMGeocode.pick(listOf(fukuoka, famous, china), "清水寺", "JP", kyoto))
        assertEquals(fukuoka, OSMGeocode.pick(listOf(fukuoka, famous, china), "清水寺", "JP", null))
        assertNull(OSMGeocode.pick(listOf(china), "清水寺", "JP", null))
    }

    @Test
    fun parseNominatimAndOsrm() {
        val json = """[{"lat":"35.71","lon":"139.79","name":"浅草寺","display_name":"浅草寺, 台東区","addresstype":"place_of_worship",
            "importance":0.55,"address":{"country_code":"jp"},"namedetails":{"name:en":"Senso-ji"}}]"""
        val p = OSMGeocode.parse(json).single()
        assertEquals("JP", p.countryCode)
        assertTrue("Senso-ji" in p.names)
        val route = """{"code":"Ok","routes":[{"distance":1000,"duration":600,"geometry":{"coordinates":[[139.7,35.7],[139.8,35.8]]}},
            {"distance":800,"duration":690,"geometry":{"coordinates":[[139.7,35.7],[139.75,35.75],[139.8,35.8]]}}]}"""
        assertEquals(800.0, RoadRoute.choose(RoadRoute.parse(route))!!.distance, 0.0)
        assertTrue(RoadRoute.url(GeoPoint(35.7, 139.7), GeoPoint(35.8, 139.8)).contains("routed-car"))
    }

    @Test
    fun dayRouteFromHotelBackToHotel() {
        val d1 = LocalDate.of(2026, 11, 10)
        val hotel = TravelEntry("h", TravelItemKind.LODGING, "酒店", start = d1.atTime(15, 0), end = d1.plusDays(2).atTime(11, 0), latitude = 1.0, longitude = 1.0)
        val a = TravelEntry("a", TravelItemKind.PLACE, "A", start = LocalDateTime.of(2026, 11, 11, 9, 0), latitude = 2.0, longitude = 2.0)
        val b = TravelEntry("b", TravelItemKind.PLACE, "B", start = LocalDateTime.of(2026, 11, 11, 14, 0), latitude = 3.0, longitude = 3.0)
        val noCoord = TravelEntry("c", TravelItemKind.PLACE, "C", start = LocalDateTime.of(2026, 11, 11, 16, 0))
        assertEquals(listOf("h", "a", "b", "h"), TravelGeo.dayRoute(d1.plusDays(1), listOf(b, hotel, noCoord, a)).map { it.id })
        assertEquals(listOf("h"), TravelGeo.dayRoute(d1, listOf(hotel)).map { it.id })
    }
}

/** AI 校准选点的纯逻辑,同 iOS PlaceCalibrationTests。 */
class PlaceCalibrationTest {
    private fun p(id: String, lat: Double, lon: Double, name: String = id) =
        OSMGeocode.Place(name, "$name, 东京", GeoPoint(lat, lon), "JP", listOf(name), "attraction", 0.5, id)

    @Test
    fun queriesStripBracketsAndLodgingWords() {
        assertEquals(listOf("浅草寺", "浅草"), PlaceCalibration.queries("浅草寺(雷门)", "浅草", false))
        assertEquals(listOf("新宿"), PlaceCalibration.queries("住新宿一带", "新宿", true))
    }

    @Test
    fun mergeTakesFromBothListsAndDedupes() {
        val a = (1..6).map { p("a$it", 35.0 + it, 139.0) }
        val b = listOf(p("a1", 36.0, 139.0), p("b1", 35.0, 140.0), p("b2", 35.0, 141.0))
        val merged = PlaceCalibration.merge(listOf(a, b))
        assertEquals(PlaceCalibration.MAX_CANDIDATES, merged.size)
        assertTrue(merged.any { it.id == "b1" } && merged.any { it.id == "b2" })
        assertEquals(merged.size, merged.map { it.id }.toSet().size)
    }

    @Test
    fun promptAndParse() {
        val item = PlaceCalibration.Item("U-1", "清水寺", "清水寺", "地点", "第 2 天 10:00", "",
            listOf(PlaceCalibration.Candidate("清水寺", "京都", "temple", 0.6, 3.0), PlaceCalibration.Candidate("清水寺", "福冈", "temple", 0.4, 500.0)))
        val prompt = PlaceCalibration.prompt("旅行:京都", listOf(item))
        assertTrue(prompt.contains("[id:U-1] 地点「清水寺」 · 第 2 天 10:00"))
        assertTrue(prompt.contains("  2. 清水寺 — 福冈 · 类型 temple · 知名度 0.40 · 距目的地 500 km"))
        val other = item.copy(id = "U-2")
        val choices = PlaceCalibration.parse(org.json.JSONObject(
            """{"choices":[{"id":"[id:u-1]","pick":"1"},{"id":"U-2","pick":null},{"id":"U-3","pick":1}]}"""), listOf(item, other))
        assertEquals(PlaceCalibration.Choice.Pick(0), choices["U-1"])
        assertEquals(PlaceCalibration.Choice.None, choices["U-2"])
        assertEquals(2, choices.size)
        assertTrue(PlaceCalibration.parse(org.json.JSONObject("""{"choices":[{"id":"U-1","pick":9}]}"""), listOf(item)).isEmpty())
    }
}
