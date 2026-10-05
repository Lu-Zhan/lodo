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
