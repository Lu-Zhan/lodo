import Foundation

/// AI 思考中那行轮换的状态词。单个词停 `wordDuration` 秒;另有几组"连续剧"
/// (倒计时、米虫吃猫粮、新建文件夹 (2)…),一组里的每一帧各有自己的时长,
/// 整组播完才换下一段。不显示推理原文——那是「已完成 ›」里的东西。
///
/// 纯逻辑:给出"这一轮开始后过了多久 + 本轮种子",算出此刻该显示哪句。
/// 种子决定这一轮从哪一段开始、按什么顺序轮(每轮各不相同,免得每次都从同一句起头)。
public enum AgentThinkingPhrases {
    /// 单个词停留的时长(用户要求放慢到 5 秒一换)。
    public static let wordDuration: TimeInterval = 5

    public struct Frame: Equatable, Sendable {
        public let text: String
        public let duration: TimeInterval
    }

    /// 一段 = 一个词,或者一组连着播的帧。
    public typealias Clip = [Frame]

    /// 此刻该显示的那句。
    public static func text(elapsed: TimeInterval, seed: Int, language: AppLanguage) -> String {
        let order = playlist(seed: seed, language: language)
        let total = order.reduce(0) { $0 + $1.reduce(0) { $0 + $1.duration } }
        guard total > 0 else { return "" }
        var remaining = max(elapsed, 0).truncatingRemainder(dividingBy: total)
        for clip in order {
            for frame in clip {
                if remaining < frame.duration { return frame.text }
                remaining -= frame.duration
            }
        }
        return order.first?.first?.text ?? ""
    }

    /// 按种子打乱后的播放顺序(确定性:同一个种子永远同一个顺序)。
    static func playlist(seed: Int, language: AppLanguage) -> [Clip] {
        var clips = self.clips(language: language)
        // 简单的线性同余发生器做 Fisher–Yates,不依赖系统随机数(要可复现、可单测)。
        var state = UInt64(truncatingIfNeeded: seed) &* 6364136223846793005 &+ 1442695040888963407
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        if clips.count > 1 {
            for i in stride(from: clips.count - 1, to: 0, by: -1) {
                clips.swapAt(i, next(i + 1))
            }
        }
        return clips
    }

    static func clips(language: AppLanguage) -> [Clip] {
        let words = language == .en ? englishWords : chineseWords
        let series = language == .en ? englishSeries : chineseSeries
        return words.map { [Frame(text: $0, duration: wordDuration)] } + series
    }

    private static func frames(_ texts: [String], each duration: TimeInterval) -> Clip {
        texts.map { Frame(text: $0, duration: duration) }
    }

    // MARK: - 中文

    static let chineseWords = [
        "处理中…", "作业中…", "批示中…", "摸鱼中…", "996中…", "思考中…", "感悟中…",
        "琢磨中…", "掐指一算…", "盘算中…", "打工中…", "开会中…",
        "拔萝卜中…", "新建文件夹中…", "薅一下乐多…", "赏月中…", "纠结中…", "擦眼镜中…",
        "假装上班中…", "等待下班中…", "泡杯茶先…", "翻字典中…", "和咖啡对视中…",
        "数羊中…", "转笔中…", "挠头中…", "给脑子充电中…", "找灵感中…",
    ]

    static let chineseSeries: [Clip] = [
        frames(["距离爆炸还有 5s", "距离爆炸还有 4s", "距离爆炸还有 3s",
                "距离爆炸还有 2s", "距离爆炸还有 1s"], each: 1)
            + frames(["💥 嘭!", "开个玩笑,还在想…"], each: 2.5),
        frames(["米虫吃一颗猫粮…", "米虫吃两颗猫粮…", "米虫吃三颗猫粮…", "米虫吃饱了,继续干活…"],
               each: 2.5),
        frames(["新建文件夹…", "新建文件夹 (2)…", "新建文件夹 (3)…", "新建文件夹 (final)…",
                "新建文件夹 (final 真的)…"], each: 2),
        frames(["拔萝卜,嘿咻…", "嘿咻嘿咻…", "拔不动,叫上小花猫…", "拔出来了!"], each: 2.5),
        frames(["加载中 ▓░░░ 25%", "加载中 ▓▓░░ 50%", "加载中 ▓▓▓░ 75%", "加载中 ▓▓▓▓ 99%",
                "卡在 99% 了…"], each: 1.5),
    ]

    // MARK: - English

    static let englishWords = [
        "Processing…", "Working…", "Reviewing…", "Taking a break…", "Working overtime…",
        "Thinking…", "Reflecting…", "Pondering…", "Calculating…", "Planning…",
        "On the clock…", "In a meeting…",
        "Pulling a radish…", "Creating new folder…", "Poking Lodo…", "Moon gazing…",
        "Having second thoughts…", "Wiping glasses…", "Pretending to work…",
        "Waiting for 5 pm…", "Brewing tea first…", "Flipping the dictionary…",
        "Staring at coffee…", "Counting sheep…", "Spinning a pen…", "Scratching head…",
        "Recharging brain…", "Hunting for ideas…",
    ]

    static let englishSeries: [Clip] = [
        frames(["Self-destruct in 5s", "Self-destruct in 4s", "Self-destruct in 3s",
                "Self-destruct in 2s", "Self-destruct in 1s"], each: 1)
            + frames(["💥 Boom!", "Just kidding, still thinking…"], each: 2.5),
        frames(["Michong eats one kibble…", "Michong eats two kibbles…",
                "Michong eats three kibbles…", "Michong is full, back to work…"], each: 2.5),
        frames(["New Folder…", "New Folder (2)…", "New Folder (3)…", "New Folder (final)…",
                "New Folder (final final)…"], each: 2),
        frames(["Pulling the radish, heave…", "Heave-ho…", "Calling the cat for help…",
                "Got it out!"], each: 2.5),
        frames(["Loading ▓░░░ 25%", "Loading ▓▓░░ 50%", "Loading ▓▓▓░ 75%",
                "Loading ▓▓▓▓ 99%", "Stuck at 99%…"], each: 1.5),
    ]
}
