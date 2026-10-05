package com.lodo.app.core

import org.json.JSONArray
import org.json.JSONObject

/**
 * 一次旅行的多个目的地(同 iOS `TripDestination.swift`)。**第一个仍是 trip 的 city/country 两列**,
 * 第二个起存 `extraDestinations`(JSON),老代码、老备份、只给一对 city/country 的 plan_trip 照旧可用。
 */
data class TripDestination(val city: String, val country: String) {
    val isEmpty get() = city.isBlank() && country.isBlank()
    val label get() = listOf(city, country).filter { it.isNotBlank() }.joinToString(" · ")

    companion object {
        fun all(city: String, country: String, extraJson: String): List<TripDestination> =
            (listOf(TripDestination(city.trim(), country.trim())) + decodeExtras(extraJson)).filter { !it.isEmpty }

        fun decodeExtras(json: String): List<TripDestination> = runCatching {
            val a = JSONArray(json)
            (0 until a.length()).mapNotNull { a.optJSONObject(it) }
                .map { TripDestination(it.optString("city").trim(), it.optString("country").trim()) }
                .filter { !it.isEmpty }
        }.getOrDefault(emptyList())

        /** 写回:空的丢掉、后面的往前挪;返回 (city, country, extraJson)。 */
        fun split(list: List<TripDestination>): Triple<String, String, String> {
            val clean = list.map { TripDestination(it.city.trim(), it.country.trim()) }.filter { !it.isEmpty }
            val first = clean.firstOrNull() ?: TripDestination("", "")
            val extras = clean.drop(1)
            val json = if (extras.isEmpty()) "" else JSONArray().also { a ->
                extras.forEach { a.put(JSONObject().put("city", it.city).put("country", it.country)) }
            }.toString()
            return Triple(first.city, first.country, json)
        }

        /** 整趟的目的地文字(列表、卡片、喂给 AI 的摘要都用它)。 */
        fun summary(list: List<TripDestination>) = list.joinToString(" / ") { it.label }

        /**
         * 一条行程项先去哪个目的地查(同 iOS lookUpWithContext 的第一步):文字里点名了哪个目的地就是它,
         * 否则按填写顺序。返回下标顺序。
         */
        fun order(text: String, list: List<TripDestination>): List<Int> {
            val named = list.indices.filter { i ->
                val d = list[i]
                (d.city.isNotBlank() && text.contains(d.city)) || (d.country.isNotBlank() && text.contains(d.country))
            }
            return named + list.indices.filter { it !in named }
        }
    }
}
