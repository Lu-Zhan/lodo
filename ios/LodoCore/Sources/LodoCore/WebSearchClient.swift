import Foundation

/// 联网搜索:接 Tavily(https://tavily.com,专为 AI agent 设计的搜索 API,免费额度
/// 每月 1000 次),供 AI 助手的 web_search ReAct 工具用。key 存钥匙串,复用
/// `KeychainHelper` 按"服务商"分存的机制,把 Tavily 当一个服务商——不单独加一套
/// 存取逻辑。放进 LodoCore 是因为这是与平台无关的纯网络请求,和 DeepSeekClient 同层。
public enum WebSearchClient {
    public struct Result {
        public let title: String
        public let url: String
        public let snippet: String

        public init(title: String, url: String, snippet: String) {
            self.title = title
            self.url = url
            self.snippet = snippet
        }
    }

    public enum WebSearchError: LocalizedError {
        case noKey
        case api(String)

        public var errorDescription: String? {
            switch self {
            case .noKey: return "未配置 Tavily API key,请到「设置」里填写。"
            case .api(let m): return "联网搜索失败:\(m)"
            }
        }
    }

    private static let providerName = "Tavily"
    private static let endpoint = URL(string: "https://api.tavily.com/search")!

    /// 是否已配置 Tavily key;command() 据此决定要不要拼入联网搜索 skill。
    public static var isConfigured: Bool {
        KeychainHelper.apiKey(for: providerName) != nil
    }

    public static func search(_ query: String, maxResults: Int = 5) async throws -> [Result] {
        guard let apiKey = KeychainHelper.apiKey(for: providerName) else {
            throw WebSearchError.noKey
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": apiKey,
            "query": query,
            "search_depth": "basic",
            "max_results": maxResults,
        ] as [String: Any])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw WebSearchError.api("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(body.prefix(200))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResults = root["results"] as? [[String: Any]] else {
            throw WebSearchError.api("返回格式异常")
        }
        return rawResults.compactMap { item -> Result? in
            guard let title = item["title"] as? String, let url = item["url"] as? String else {
                return nil
            }
            return Result(title: title, url: url, snippet: (item["content"] as? String) ?? "")
        }
    }
}
