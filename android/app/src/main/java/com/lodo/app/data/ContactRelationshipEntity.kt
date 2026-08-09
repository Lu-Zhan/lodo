package com.lodo.app.data

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.UUID

/**
 * 人脉之间的关系,对应 iOS ContactRelationship:无向单条边,靠 uuid 互相引用
 * (不是外键/Room @Relationship),与仓库里其余多值/跨记录引用(TaskEntity 的
 * tags、聊天附件 attachmentMemoryUUIDs)同一个思路——删除某条记忆时才需要
 * 联动清理引用它的边,不需要数据库层面的级联约束。
 */
@Entity(tableName = "contact_relationships", indices = [Index(value = ["fromUuid"]), Index(value = ["toUuid"])])
data class ContactRelationshipEntity(
    @PrimaryKey val uuid: String,
    val fromUuid: String,
    val toUuid: String,
    /** 关系描述,自由文本,如"同事"/"家人"/"高中同学"。 */
    val label: String,
) {
    companion object {
        fun create(fromUuid: String, toUuid: String, label: String) = ContactRelationshipEntity(
            uuid = UUID.randomUUID().toString(), fromUuid = fromUuid, toUuid = toUuid, label = label,
        )
    }
}
