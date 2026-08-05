import Foundation

/// 免费公开汇率:接 Frankfurter(https://frankfurter.dev,基于 ECB 每日参考汇率,
/// 无需 API key、不占用 Tavily 额度),供资产总览的多币种换算用。放 LodoCore
/// 是因为这是与平台无关的纯网络请求,和 WebSearchClient 同层。
public enum ExchangeRateClient {
    public enum ExchangeRateError: LocalizedError {
        case api(String)

        public var errorDescription: String? {
            switch self {
            case .api(let m): return "获取汇率失败:\(m)"
            }
        }
    }

    private static let endpoint = "https://api.frankfurter.dev/v1/latest"

    /// 拉取以 `base` 为基准的最新汇率表。失败(离线/接口异常)时抛错,
    /// 调用方(app 层的 ExchangeRateStore)负责退回本地缓存的上一次结果。
    public static func fetchRates(base: String = "USD") async throws -> ExchangeRateTable {
        guard var components = URLComponents(string: endpoint) else {
            throw ExchangeRateError.api("URL 构造失败")
        }
        components.queryItems = [URLQueryItem(name: "from", value: base)]
        guard let url = components.url else { throw ExchangeRateError.api("URL 构造失败") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ExchangeRateError.api("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(200))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExchangeRateError.api("返回格式异常")
        }
        return try parseRatesPayload(root, base: base, fetchedAt: Date())
    }

    /// 从 payload 里解析汇率表(单测入口,不发网络请求)。
    static func parseRatesPayload(
        _ payload: [String: Any], base: String, fetchedAt: Date
    ) throws -> ExchangeRateTable {
        guard let rawRates = payload["rates"] as? [String: Any] else {
            throw ExchangeRateError.api("返回格式异常:缺少 rates")
        }
        var rates: [String: Double] = [:]
        for (code, value) in rawRates {
            if let number = value as? NSNumber {
                rates[code] = number.doubleValue
            } else if let string = value as? String, let number = Double(string) {
                rates[code] = number
            }
        }
        guard !rates.isEmpty else {
            throw ExchangeRateError.api("返回格式异常:rates 为空")
        }
        return ExchangeRateTable(base: base, rates: rates, fetchedAt: fetchedAt)
    }
}
