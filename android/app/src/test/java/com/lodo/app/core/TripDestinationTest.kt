package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Test

class TripDestinationTest {
    @Test fun firstStaysInColumnsExtrasInJson() {
        val (city, country, json) = TripDestination.split(listOf(
            TripDestination("", ""), TripDestination("北海道", "日本"), TripDestination(" 上海 ", "中国"),
        ))
        assertEquals("北海道", city)
        assertEquals("日本", country)
        assertEquals(listOf(TripDestination("北海道", "日本"), TripDestination("上海", "中国")), TripDestination.all(city, country, json))
    }

    @Test fun oldDataWithoutExtrasStillWorks() {
        assertEquals(listOf(TripDestination("东京", "")), TripDestination.all("东京", "", ""))
        assertEquals(emptyList<TripDestination>(), TripDestination.all("", "", "not json"))
        assertEquals("", TripDestination.split(listOf(TripDestination("东京", "日本"))).third)
    }

    @Test fun namedDestinationGoesFirst() {
        val list = listOf(TripDestination("札幌", "日本"), TripDestination("上海", "中国"))
        assertEquals(listOf(1, 0), TripDestination.order("上海外滩", list))
        assertEquals(listOf(0, 1), TripDestination.order("小樽运河", list))
        assertEquals("札幌 · 日本 / 上海 · 中国", TripDestination.summary(list))
    }
}
