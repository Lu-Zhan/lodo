import Foundation
import Security

/// AI 服务商 API key 的 Keychain 存取(按服务商分开存,切换服务商不丢 key)。
/// 放进 LodoCore 是为了让 Watch App 也能直接读取(经由 iCloud 钥匙串同步过来的)key,
/// 不需要在 Watch 上重新输入一遍。
public enum KeychainHelper {
    private static let service = "com.lodo.app"
    /// 旧版单一 DeepSeek key 的账户名,读取时兼容。
    private static let legacyAccount = "deepseek-api-key"

    /// kSecAttrSynchronizableAny 兼容老版本存的非同步 key(升级后不会读不到);
    /// 新存的 key 通过 iCloud 钥匙串同步,Watch App 不用重新输入一遍。
    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
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
    public static func apiKey(for provider: String) -> String? {
        read(account: "api-key-\(provider)")
            ?? (provider == "DeepSeek" ? read(account: legacyAccount) : nil)
    }

    public static func save(_ key: String, for provider: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = "api-key-\(provider)"
        SecItemDelete(query(account: account) as CFDictionary)
        if provider == "DeepSeek" {
            SecItemDelete(query(account: legacyAccount) as CFDictionary)
        }
        guard !trimmed.isEmpty else { return }
        var q = query(account: account)
        q[kSecAttrSynchronizable as String] = true
        q[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    /// 当前选中服务商的 key(原有调用点继续可用)。
    public static var apiKey: String? { apiKey(for: AppSettings.aiProvider) }

    public static func save(_ key: String) {
        save(key, for: AppSettings.aiProvider)
    }

    /// 实际发请求要用的 key:开了"使用内置 API Key"且当前是 DeepSeek 服务商、
    /// 又真的内置了 key 时优先用内置的;否则退回钥匙串里用户自己存的 key。
    /// DeepSeekClient 发请求统一走这个,不直接读 apiKey——Settings 页面的
    /// "已保存"状态判断则仍然只看钥匙串本身(apiKey),不受这个开关影响,
    /// 保持"钥匙串里存的是什么"和"这次请求实际用的是什么"两件事分开显示。
    public static var effectiveAPIKey: String? {
        if AppSettings.useBuiltInKey, AppSettings.aiProvider == "DeepSeek",
           let builtIn = BuiltInAPIKey.deepSeek, !builtIn.isEmpty {
            return builtIn
        }
        return apiKey
    }
}
