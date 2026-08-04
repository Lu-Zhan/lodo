import Foundation
import Contacts
import SwiftData
import LodoCore

/// 系统通讯录(CNContactStore)与记忆库"联系人"条目(MemoryItem.contactTagName)
/// 之间的双向桥接:导入(单个/批量,均在写入前按手机号/邮箱去重)、导出
/// (单个/批量,同样按手机号/邮箱去重,避免重复运行产生重复的系统联系人)。
/// 只负责数据映射与去重判断,系统选择器/新建联系人确认页的 UIKit 桥接在
/// ContactPickerView.swift / ContactExportView.swift。
@MainActor
enum ContactsBridge {
    static let keysToFetch: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactNoteKey as CNKeyDescriptor,
        CNContactImageDataKey as CNKeyDescriptor,
    ]

    enum AccessResult {
        case granted
        case denied
    }

    /// 请求通讯录读写权限;`.limited`(iOS 18 起用户可选择只共享部分联系人)
    /// 也当作可用,选择器/回调只会看到用户已授权的那部分。
    static func requestAccess() async -> AccessResult {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return .granted
        case .notDetermined:
            let granted = (try? await store.requestAccess(for: .contacts)) ?? false
            return granted ? .granted : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// 通讯录里的全部联系人("一次性导入"用),读不到的字段留空。
    static func fetchAllContacts() -> [CNContact] {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        var contacts: [CNContact] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            contacts.append(contact)
        }
        return contacts
    }

    // MARK: - 导入(系统联系人 → 记忆库)

    /// 批量导入,按手机号/邮箱与已有联系人条目去重(命中任一即跳过,不新建、
    /// 也不覆盖更新——去重只是"别导入两遍",不是"同步")。
    static func importContacts(
        _ cnContacts: [CNContact], context: ModelContext
    ) -> (imported: Int, skipped: Int) {
        let existing = (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []
        var knownPhones = Set(existing.filter(\.isContact).compactMap(\.contactPhone))
        var knownEmails = Set(existing.filter(\.isContact).compactMap(\.contactEmail))

        var imported = 0
        var skipped = 0
        for cnContact in cnContacts {
            let phone = cnContact.phoneNumbers.first?.value.stringValue
            let email = cnContact.emailAddresses.first.map { $0.value as String }
            if isDuplicate(phone: phone, email: email, knownPhones: knownPhones, knownEmails: knownEmails) {
                skipped += 1
                continue
            }
            guard let item = MemoryPipeline.saveContact(
                name: displayName(for: cnContact), nickname: cnContact.nickname,
                phone: phone ?? "", email: email ?? "",
                birthday: cnContact.birthday?.date, preferences: "", note: cnContact.note,
                avatarData: cnContact.imageData, attachmentFileURLs: [], context: context
            ) else { continue }
            imported += 1
            if let phone, !phone.isEmpty { knownPhones.insert(phone) }
            if let email, !email.isEmpty { knownEmails.insert(email) }
            _ = item
        }
        return (imported, skipped)
    }

    private static func displayName(for cnContact: CNContact) -> String {
        let formatted = CNContactFormatter.string(from: cnContact, style: .fullName)
        if let formatted, !formatted.isEmpty { return formatted }
        return cnContact.nickname
    }

    // MARK: - 导出(记忆库 → 系统联系人)

    /// 单个导出用的可编辑联系人草稿,交给系统的新建联系人确认页
    /// (CNContactViewController)展示,用户还能在保存前改字段。
    static func makeMutableContact(from item: MemoryItem) -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = item.title
        if let nickname = item.contactNickname { contact.nickname = nickname }
        if let phone = item.contactPhone, !phone.isEmpty {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                                    value: CNPhoneNumber(stringValue: phone))]
        }
        if let email = item.contactEmail, !email.isEmpty {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }
        if let birthday = item.contactBirthday {
            contact.birthday = Calendar.current.dateComponents([.year, .month, .day], from: birthday)
        }
        let noteParts = [item.summary, item.contactPreferences].compactMap { $0 }.filter { !$0.isEmpty }
        if !noteParts.isEmpty { contact.note = noteParts.joined(separator: "\n") }
        if let avatarURL = MemoryPipeline.contactAvatarURL(of: item),
           let data = try? Data(contentsOf: avatarURL) {
            contact.imageData = data
        }
        return contact
    }

    /// 批量导出:静默写入(CNSaveRequest,无逐条确认 UI——批量场景没法对每条都
    /// 弹一次系统确认页),按手机号/邮箱与系统通讯录里现有联系人去重。
    static func exportContacts(
        _ items: [MemoryItem]
    ) -> (exported: Int, skipped: Int, failed: Int) {
        let store = CNContactStore()
        let existing = fetchAllContacts()
        var knownPhones = Set(existing.compactMap { $0.phoneNumbers.first?.value.stringValue })
        var knownEmails = Set(existing.compactMap { $0.emailAddresses.first.map { $0.value as String } })

        var exported = 0
        var skipped = 0
        var failed = 0
        for item in items {
            if isDuplicate(phone: item.contactPhone, email: item.contactEmail,
                            knownPhones: knownPhones, knownEmails: knownEmails) {
                skipped += 1
                continue
            }
            let mutable = makeMutableContact(from: item)
            let saveRequest = CNSaveRequest()
            saveRequest.add(mutable, toContainerWithIdentifier: nil)
            do {
                try store.execute(saveRequest)
                exported += 1
                if let phone = item.contactPhone, !phone.isEmpty { knownPhones.insert(phone) }
                if let email = item.contactEmail, !email.isEmpty { knownEmails.insert(email) }
            } catch {
                failed += 1
            }
        }
        return (exported, skipped, failed)
    }

    private static func isDuplicate(
        phone: String?, email: String?, knownPhones: Set<String>, knownEmails: Set<String>
    ) -> Bool {
        if let phone, !phone.isEmpty, knownPhones.contains(phone) { return true }
        if let email, !email.isEmpty, knownEmails.contains(email) { return true }
        return false
    }
}
