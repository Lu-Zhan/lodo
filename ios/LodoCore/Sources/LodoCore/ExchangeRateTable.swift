import Foundation

/// 一份汇率快照:以 `base` 为基准货币,`rates[X]` 表示 1 个 base 兑换多少个 X
/// (与 Frankfurter/ECB 的 "amount":1, "base":"USD" 语义一致)。`rates` 里补了
/// `base` 自身 = 1.0,换算时不用对 base 特判。纯数据 + 纯函数,可离线单测,
/// 网络请求本身在 ExchangeRateClient。
public struct ExchangeRateTable: Codable, Equatable {
    public let base: String
    public let rates: [String: Double]
    public let fetchedAt: Date

    public init(base: String, rates: [String: Double], fetchedAt: Date) {
        self.base = base
        var withBase = rates
        withBase[base] = 1.0
        self.rates = withBase
        self.fetchedAt = fetchedAt
    }

    /// 把 `amount`(单位是 `from` 货币)换算成 `to` 货币;任一方不在汇率表里
    /// 时返回 nil(调用方决定怎么降级,比如从汇总里排除、单独提示)。
    public func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let fromRate = rates[from], fromRate > 0, let toRate = rates[to] else { return nil }
        return amount / fromRate * toRate
    }
}
