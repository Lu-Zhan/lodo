import Foundation
import Security

/// AI 服务商 API key 的 Keychain 存取(按服务商分开存,切换服务商不丢 key)。
enum KeychainHelper {
    private static let service = "com.lodo.app"
    /// 旧版单一 DeepSeek key 的账户名,读取时兼容。
    private static let legacyAccount = "deepseek-api-key"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(account: String) -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// 指定服务商的 key;DeepSeek 读不到新存储时回退旧账户。
    static func apiKey(for provider: String) -> String? {
        read(account: "api-key-\(provider)")
            ?? (provider == "DeepSeek" ? read(account: legacyAccount) : nil)
    }

    static func save(_ key: String, for provider: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = "api-key-\(provider)"
        SecItemDelete(query(account: account) as CFDictionary)
        if provider == "DeepSeek" {
            SecItemDelete(query(account: legacyAccount) as CFDictionary)
        }
        guard !trimmed.isEmpty else { return }
        var q = query(account: account)
        q[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    /// 当前选中服务商的 key(原有调用点继续可用)。
    static var apiKey: String? { apiKey(for: AppSettings.aiProvider) }

    static func save(_ key: String) {
        save(key, for: AppSettings.aiProvider)
    }
}
