import Foundation

/// 从一段文字里认出国家/地区(ISO 3166-1 alpha-2),纯离线、不发请求。
///
/// 为什么需要它:地名搜索(`MKLocalSearch`)会按设备所在地做区域偏置,搜「秋葉原」
/// 返回的第一条可能是中国境内一家同名店铺——实测在国内网络上,Apple 的地理服务
/// 只给中国大陆数据,搜日本地名一律落在国内,反查日本坐标直接报错。没有"这趟旅行
/// 应该在哪个国家"这个判据,那些结果看不出对错,整趟行程就画到了中国地图上。
///
/// 判据只能离线拿:要靠地理服务反过来确认"日本在哪"的话,在同一个受限环境里
/// 一样查不到。这里的名字表整个来自系统的 `Locale` 本地化数据(292 个 ISO 地区,
/// 中/英两套名字),不是手写的国家清单。
public enum PlaceRegion {
    /// 一次性建好的「名字 → ISO 码」表,按名字长度倒序——先试最长的,
    /// 「中国香港特别行政区」不会被「中国」抢先匹配掉。
    private static let names: [(name: String, code: String)] = buildNames()

    private static func buildNames() -> [(name: String, code: String)] {
        var table: [String: String] = [:]
        // 中文(简/繁)+ 英文三套本地化名字。日文的「日本」和中文同形,韩文等
        // 少数语言没覆盖——旅行的国家字段是用户按应用内语言填的,中英够用。
        let locales = [Locale(identifier: "zh_Hans"), Locale(identifier: "zh_Hant"),
                       Locale(identifier: "en")]
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            // 只要两字母国家/地区码。数字码("419" 拉丁美洲这类大区)不是国家,
            // 拿来和 `isoCountryCode` 比对没有意义。
            guard code.count == 2, code.allSatisfy({ $0.isLetter }) else { continue }
            for locale in locales {
                guard let name = locale.localizedString(forRegionCode: code) else { continue }
                let key = normalized(name)
                // 一个名字对应多个码时(理论上不该有)保留先来的那个。
                guard key.count >= 2, table[key] == nil else { continue }
                table[key] = code.uppercased()
            }
        }
        // CLDR 给的名字不总是用户会写的那个:中国大陆的标准名就是「中国大陆」,
        // 用户写的却是「中国」;港澳台的标准名带「中国…特别行政区」前缀。补一小组
        // 别名,匹配是"文字里包含这个名字",所以这几条必须显式给。
        let aliases: [String: String] = [
            "中国": "CN", "中國": "CN", "中华人民共和国": "CN", "中華人民共和國": "CN",
            "china": "CN", "prc": "CN",
            "香港": "HK", "hong kong": "HK", "澳门": "MO", "澳門": "MO", "macao": "MO",
            "macau": "MO", "台湾": "TW", "台灣": "TW", "taiwan": "TW",
            "韩国": "KR", "韓國": "KR", "南韩": "KR", "korea": "KR",
            "英国": "GB", "英國": "GB", "uk": "GB", "united kingdom": "GB",
            "美国": "US", "美國": "US", "usa": "US", "united states": "US",
        ]
        for (name, code) in aliases { table[normalized(name)] = code }
        return table.map { (name: $0.key, code: $0.value) }
            .sorted { $0.name.count > $1.name.count }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 文字里出现的国家/地区码(找不到返回 nil)。传进来的可以是旅行的国家字段、
    /// 城市字段,也可以是「北海道四日游」这样只有名字的标题。
    ///
    /// 匹配的是"文字里包含某个国家名",所以「日本料理」也会算成 JP——用在旅行
    /// 上正是想要的(那趟旅行确实在日本),不是在做严格的地名解析。
    /// 拉丁字母的名字要求两侧是非字母,免得「Mali」把「Malibu」算进来。
    public static func isoCode(in text: String) -> String? {
        let haystack = normalized(text)
        guard !haystack.isEmpty else { return nil }
        for entry in names where haystack.contains(entry.name) {
            if entry.name.first?.isASCII == true {
                guard hasWordBoundary(entry.name, in: haystack) else { continue }
            }
            return entry.code
        }
        return nil
    }

    /// 几段文字按先后顺序试,取第一个认出来的(旅行的国家字段优先于标题)。
    public static func isoCode(in candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            if let code = isoCode(in: candidate) { return code }
        }
        return nil
    }

    private static func hasWordBoundary(_ needle: String, in haystack: String) -> Bool {
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            let beforeOK = range.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: range.lowerBound)].isLetter
            let afterOK = range.upperBound == haystack.endIndex
                || !haystack[range.upperBound].isLetter
            if beforeOK, afterOK { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// 两个地区码算不算"同一个地方"。
    ///
    /// **中国大陆/香港/澳门/台湾互认**:用户在国家栏里写「中国」时,一个香港的
    /// 地点不该被当成搜岔了给扔掉(CLDR 里它们是四个独立的 ISO 地区,日常语义上
    /// 不是)。跨这四者的误判代价也小——都在同一片地方,不会出现"日本的行程画到
    /// 东北"那种离谱位置。
    public static func matches(_ expected: String?, _ actual: String?) -> Bool {
        guard let expected = expected?.uppercased(), !expected.isEmpty else { return true }
        // 结果没带地区码时不当作对不上:判不出来就别拦(宁可少拦,不误杀)。
        guard let actual = actual?.uppercased(), !actual.isEmpty else { return true }
        if expected == actual { return true }
        let greaterChina: Set<String> = ["CN", "HK", "MO", "TW"]
        return greaterChina.contains(expected) && greaterChina.contains(actual)
    }
}
