package com.lodo.app.core

import org.json.JSONArray
import org.json.JSONObject

/** 侧边栏布局。标识由调用方传入 AppSection.name,不依赖 UI 或 Android。 */
data class SidebarLayout(val items: List<Item>) {
    data class Item(val id: String, val visible: Boolean = true)

    fun encode(): String = JSONArray().apply {
        items.forEach { item ->
            put(JSONObject().put("id", item.id).put("visible", item.visible))
        }
    }.toString()

    /** 把一项移到目标项的位置,中间的项顺移;隐藏状态跟着标识走。 */
    fun move(id: String, targetId: String): SidebarLayout {
        val from = items.indexOfFirst { it.id == id }
        val to = items.indexOfFirst { it.id == targetId }
        if (from < 0 || to < 0 || from == to) return this
        return copy(items = items.toMutableList().apply { add(to, removeAt(from)) })
    }

    fun setVisible(id: String, visible: Boolean): SidebarLayout =
        copy(items = items.map { if (it.id == id) it.copy(visible = visible) else it })

    companion object {
        fun defaults(defaultIds: List<String>): SidebarLayout =
            SidebarLayout(defaultIds.distinct().map { Item(it) })

        /** 未知/重复标识跳过(首条有效记录优先),缺失项按默认顺序追加。坏 JSON 回退默认值。 */
        fun decode(json: String?, defaultIds: List<String>): SidebarLayout {
            val known = defaultIds.toSet()
            val seen = mutableSetOf<String>()
            val items = mutableListOf<Item>()
            val array = runCatching { JSONArray(json.orEmpty()) }.getOrNull()
            if (array != null) {
                for (index in 0 until array.length()) {
                    val value = array.optJSONObject(index) ?: continue
                    val id = value.opt("id") as? String ?: continue
                    if (id !in known || !seen.add(id)) continue
                    items += Item(id, value.opt("visible") as? Boolean ?: true)
                }
            }
            defaultIds.forEach { if (seen.add(it)) items += Item(it) }
            return SidebarLayout(items)
        }
    }
}
