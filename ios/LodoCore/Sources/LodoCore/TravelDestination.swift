import Foundation

/// 从旅行的城市字段和名字里猜"目的地城市"叫什么,给地名查询找锚点用
/// (纯逻辑,`TravelDestinationTests`)。
///
/// AI 规划出来的旅行、早期手建的旅行常常只有一个名字——「东京四日」「京都三日游」
/// 「北海道7天自由行」——城市和国家两栏都空着。拿整个名字去搜城市一条都搜不到,
/// 「刷新地点位置」于是连锚点都找不到、整步跳过,地图上什么都不变。
/// 这里把名字尾巴上的天数、「游/之旅/自由行」之类去掉,剩下的就是城市名。
public enum TravelDestination {
    /// 名字尾巴上要去掉的词,长的在前(先去「自由行」再去「行」)。
    private static let suffixes = [
        "自由行", "之旅", "旅行", "行程", "攻略", "旅游", "度假", "出游",
        "游", "行", "日", "天", "晚", "夜", "周", "趟",
    ]
    private static let numerals = Set("0123456789０１２３４５６７８９一二三四五六七八九十两半")

    /// 候选城市名,按可信度排:城市字段在前,名字去尾巴后的在后;去重、去空。
    public static func cityCandidates(city: String, title: String) -> [String] {
        var result: [String] = []
        func add(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { return }
            result.append(trimmed)
        }
        add(city)
        add(stripped(title))
        return result
    }

    /// 反复去掉尾巴上的天数词和标点,直到去不动为止:「京都三日游」→「京都三日」→「京都三」→「京都」。
    /// 第一个空白/标点之前的部分才是地名(「东京 · 四日」「大阪-奈良」取「东京」「大阪」)。
    static func stripped(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = text.firstIndex(where: { $0.isWhitespace || ($0.isPunctuation && $0 != "'") || $0 == "·" }) {
            text = String(text[..<cut])
        }
        var changed = true
        while changed, !text.isEmpty {
            changed = false
            if let last = text.last, numerals.contains(last) {
                text.removeLast()
                changed = true
                continue
            }
            // 删完至少留两个字:城市名几乎没有单字的,「旅行」不该被删成「旅」。
            for suffix in suffixes where text.hasSuffix(suffix) && text.count - suffix.count >= 2 {
                text.removeLast(suffix.count)
                changed = true
                break
            }
        }
        return text
    }

    /// 住宿拿去查位置的名字:AI 规划的住宿写成「住新宿一带」「入住京都站附近」,
    /// 去掉「住/入住/住在」和「一带/附近/周边」才是能查的地名。去完为空就原样返回。
    public static func lodgingQuery(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["入住", "住在", "住"] where text.hasPrefix(prefix) && text.count > prefix.count {
            text.removeFirst(prefix.count)
            break
        }
        for suffix in ["一带", "附近", "周边", "周围", "区域"] where text.hasSuffix(suffix) && text.count > suffix.count {
            text.removeLast(suffix.count)
            break
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
