package com.lodo.app.contacts

import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.ContactsContract

data class ImportedContact(val name: String, val phone: String?, val email: String?)

/**
 * 通讯录导入/导出的单个人脉子集,对应 iOS ContactsBridge.swift 的核心
 * 路径——只做"选择导入"(系统通讯录选择器,不需要 READ_CONTACTS 权限,选择器
 * 本身在系统进程里运行)和"单个导出"(ACTION_INSERT 确认页,不需要
 * WRITE_CONTACTS 权限,系统联系人 app 自己负责写入)。批量导入/导出在 iOS
 * 上需要通讯录权限 + 去重逻辑,这一轮 Android 先做零权限的单个路径,批量的
 * 留待后续跟进。
 */
object ContactsBridge {
    fun read(context: Context, contactUri: Uri): ImportedContact? {
        val resolver = context.contentResolver
        val contactId = ContentUris.parseId(contactUri)

        var name = ""
        resolver.query(contactUri, arrayOf(ContactsContract.Contacts.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) name = cursor.getString(0).orEmpty() }
        if (name.isEmpty()) return null

        var phone: String? = null
        resolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
            "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} = ?",
            arrayOf(contactId.toString()), null,
        )?.use { cursor -> if (cursor.moveToFirst()) phone = cursor.getString(0) }

        var email: String? = null
        resolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Email.ADDRESS),
            "${ContactsContract.CommonDataKinds.Email.CONTACT_ID} = ?",
            arrayOf(contactId.toString()), null,
        )?.use { cursor -> if (cursor.moveToFirst()) email = cursor.getString(0) }

        return ImportedContact(name, phone, email)
    }

    /** 与 iOS 单个导出走 CNContactViewController(forNewContact:) 确认页同一个
     * 思路:系统联系人 app 打开一个预填好的新建页,用户看一眼再保存。 */
    fun exportIntent(name: String, phone: String?, email: String?): Intent {
        val intent = Intent(Intent.ACTION_INSERT).setType(ContactsContract.Contacts.CONTENT_TYPE)
        intent.putExtra(ContactsContract.Intents.Insert.NAME, name)
        phone?.let { intent.putExtra(ContactsContract.Intents.Insert.PHONE, it) }
        email?.let { intent.putExtra(ContactsContract.Intents.Insert.EMAIL, it) }
        return intent
    }
}
