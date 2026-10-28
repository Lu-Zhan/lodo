import Foundation

/// 快捷输入:整串正好打成 rq / sj / xq / nl 时,候选里插上今天的日期、此刻的时间、星期、农历。
/// 思路来自雾凇拼音(rime-ice)的日期时间脚本,它是 GPL,这里是自己写的,没有拿它的代码。
/// 只认全拼整串:rq 本身还是「日期」「人群」的简拼,词典候选照常在前面。
enum QuickPhrases {
    static func texts(for input: String, now: Date, calendar: Calendar = .current) -> [String] {
        switch input {
        case "rq": return [format("y年M月d日", now, calendar), format("M月d日", now, calendar) + " " + weekday(now, calendar),
                           format("yyyy-MM-dd", now, calendar)]
        case "sj": return [format("HH:mm", now, calendar), format("yyyy-MM-dd HH:mm", now, calendar)]
        case "xq": return [weekday(now, calendar), "星期" + String(weekday(now, calendar).dropFirst())]
        case "nl": return lunar(now, calendar)
        default: return []
        }
    }

    private static func format(_ pattern: String, _ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// 周一 … 周日。
    private static func weekday(_ date: Date, _ calendar: Calendar) -> String {
        var greg = Calendar(identifier: .gregorian)
        greg.timeZone = calendar.timeZone
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return "周" + names[greg.component(.weekday, from: date) - 1]
    }

    /// 农历九月十九、丙午年九月十九。月份(含闰月)交给系统的中国历法,日子自己写成「初一…三十」。
    private static func lunar(_ date: Date, _ calendar: Calendar) -> [String] {
        var chinese = Calendar(identifier: .chinese)
        chinese.timeZone = calendar.timeZone
        let f = DateFormatter()
        f.calendar = chinese
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "MMMM"
        let month = f.string(from: date)
        f.dateFormat = "U"
        let year = f.string(from: date)
        let day = chineseDay(chinese.component(.day, from: date))
        return ["农历" + month + day, year + "年" + month + day]
    }

    static func chineseDay(_ d: Int) -> String {
        let digits = ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        switch d {
        case 1...10: return "初" + digits[d]
        case 11...19: return "十" + digits[d - 10]
        case 20: return "二十"
        case 21...29: return "廿" + digits[d - 20]
        default: return "三十"
        }
    }
}
