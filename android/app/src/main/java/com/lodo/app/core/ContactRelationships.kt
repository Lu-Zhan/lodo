package com.lodo.app.core

/**
 * 人脉关系边"新建或更新"的判定逻辑,与 iOS MemoryPipeline.upsertContactRelationship
 * 同一个思路:同一对联系人(不分 from/to 顺序)已有边时复用它的 uuid(只改 label,
 * 不新插入一条),不存在时才生成新 uuid。用 <T> + 访问器闭包保持和
 * core/MemorySearch.rank 一样"不引 Room/Android 依赖"的写法,方便纯 JVM 单测。
 */
object ContactRelationships {
    /** 返回应该被 upsert 的目标 uuid。 */
    fun <T> resolveUpsertUuid(
        existing: List<T>,
        fromUuid: String,
        toUuid: String,
        uuidOf: (T) -> String,
        fromOf: (T) -> String,
        toOf: (T) -> String,
        newUuid: () -> String,
    ): String {
        val match = existing.firstOrNull { edge ->
            (fromOf(edge) == fromUuid && toOf(edge) == toUuid) ||
                (fromOf(edge) == toUuid && toOf(edge) == fromUuid)
        }
        return match?.let(uuidOf) ?: newUuid()
    }
}
