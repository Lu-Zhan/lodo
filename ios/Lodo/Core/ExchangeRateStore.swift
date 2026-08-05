import Foundation
import LodoCore

/// 汇率缓存:资产总览出现时按需刷新,24 小时内的缓存直接用;离线或请求失败时
/// 退回上一次成功缓存的结果,不会让总览因为一次网络波动就从"有总额"变成
/// "什么都看不到"。以 USD 为基准拉取一份覆盖约 30 种货币的汇率表(见
/// ExchangeRateClient),任意两种受支持货币间的换算都靠这一份表算,不用
/// 分别请求每个币种对。
@MainActor
@Observable
final class ExchangeRateStore {
    static let shared = ExchangeRateStore()

    private(set) var table: ExchangeRateTable?
    private(set) var isRefreshing = false

    private static let cacheKey = "exchangeRateTableCache"
    private static let refreshInterval: TimeInterval = 24 * 3600
    private static let base = "USD"

    private init() {
        table = Self.loadCache()
    }

    /// 从未成功拉取过汇率(离线首次启动),资产总览据此展示"汇率不可用"提示。
    var isUnavailable: Bool { table == nil }

    func convert(_ amount: Double, from: String, to: String) -> Double? {
        table?.convert(amount, from: from, to: to)
    }

    /// 缓存过期或不存在时才真的发请求;资产总览每次出现都可以放心调用,
    /// 内部按新鲜度和"是否已经在刷新"短路,不会并发重复发请求。
    func refreshIfNeeded() async {
        if let table, Date().timeIntervalSince(table.fetchedAt) < Self.refreshInterval { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let fresh = try? await ExchangeRateClient.fetchRates(base: Self.base) else { return }
        table = fresh
        Self.saveCache(fresh)
    }

    private static func loadCache() -> ExchangeRateTable? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(ExchangeRateTable.self, from: data)
    }

    private static func saveCache(_ table: ExchangeRateTable) {
        guard let data = try? JSONEncoder().encode(table) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
