import Foundation
import Observation

/// 一轮 AI 助手对话的 token 用量与生成速度。AI 助手页导航栏标题下面那行小字读它
/// (原来那儿放的是思考强度——静态设置项,设置页已经有,摆在最显眼的位置每次都一样)。
///
/// 口径:
/// - **整轮累计**。一轮 = 用户发一句话到这轮结束,ReAct 最多 3 次请求,几次相加。
/// - **速度 = 累计输出 token / 累计生成时长**,生成时长按每次请求"第一片增量 → 该次
///   请求结束"累加。**刻意不用整轮墙钟**:中间夹一次联网搜索(纯等待、不产 token)
///   会把速度压到看起来像模型很慢,那不是"token 速度"该表达的东西。
/// - **有 usage 用精确值,没有退回估算**(按增量分片计数),估算态打 `≈`,而且估算态
///   客户端不知道 prompt 多大,这时只报输出那一半。
public struct AIUsage: Equatable, Sendable {
    /// 输入(prompt)token。只有服务端报了 usage 才有。
    public var inputTokens: Int?
    /// 输出 token。精确值缺失时是按增量分片数估的。
    public var outputTokens: Int
    /// 这轮里有请求没报 usage,上面的数字掺了估算值。
    public var isEstimated: Bool
    /// 累计生成时长(只算真正在吐字的那几段)。
    public var generatingSeconds: TimeInterval
    /// 这轮发了几次请求。
    public var requests: Int
    /// 还有请求在进行中。
    public var isStreaming: Bool

    public init(inputTokens: Int? = nil, outputTokens: Int = 0, isEstimated: Bool = true,
                generatingSeconds: TimeInterval = 0, requests: Int = 0,
                isStreaming: Bool = false) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.isEstimated = isEstimated
        self.generatingSeconds = generatingSeconds
        self.requests = requests
        self.isStreaming = isStreaming
    }

    /// 分母小于这个值不给速度:刚吐出第一片时除出来的是个天文数字,晃一下反而碍眼。
    public static let minimumSpeedWindow: TimeInterval = 0.2

    public var tokensPerSecond: Double? {
        guard outputTokens > 0, generatingSeconds >= Self.minimumSpeedWindow else { return nil }
        return Double(outputTokens) / generatingSeconds
    }

    /// 标题行上那截小字;没什么可报的时候返回 nil(调用方退回展示「联网搜索」)。
    /// 进行中**只报速度**:输入 token 要等服务端最后那片 usage 才知道,先显示 0
    /// 再跳成真数字不如干脆不显示。
    public var badge: String? {
        var parts: [String] = []
        if !isStreaming, outputTokens > 0 {
            if let inputTokens, !isEstimated {
                parts.append("↑\(Self.formatCount(inputTokens)) ↓\(Self.formatCount(outputTokens))")
            } else {
                parts.append("↓≈\(Self.formatCount(outputTokens))")
            }
        }
        if let speed = tokensPerSecond {
            parts.append("\(Int(speed.rounded())) tok/s")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 千位缩写:1000 以下原样,1 万以下留一位小数(`1.1k`,整数不留 `.0`),
    /// 再往上取整(`12k`)——导航栏那行放不下更多位数。
    public static func formatCount(_ value: Int) -> String {
        guard value >= 1000 else { return "\(value)" }
        guard value < 10_000 else { return "\((value + 500) / 1000)k" }
        let text = String(format: "%.1f", Double(value) / 1000)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "k"
    }
}

/// `AIUsage` 的累加器。纯值类型、时间由调用方传入(沿用 `StreamThrottle` 那套
/// `now: Date = Date()` 注入惯例),离线单测见 `AIUsageTests`。
public struct AIUsageAccumulator {
    /// 进行中的数字往 UI 推的节流间隔。比 `StreamThrottle.interval` 松一档:
    /// 那个是逐字揭示,这个只是让一个数字跳动,跳太快反而读不出来。
    public static let publishInterval: TimeInterval = 0.25

    // 已结束请求的累计
    private var exactInput: Int?
    private var exactOutput = 0
    private var estimatedOutput = 0
    private var missingExact = false
    private var generatingSeconds: TimeInterval = 0
    private var requests = 0

    // 进行中那次请求
    private var requestStart: Date?
    private var requestFirstDelta: Date?
    private var requestDeltas = 0
    private var requestInput: Int?
    private var requestOutput: Int?

    private var lastPublish: Date?

    public init() {}

    /// 开一次请求。流式那条路不用显式调(第一片增量会隐式开),非流式那条要,
    /// 因为它一片增量都没有、只能拿整次请求的耗时当生成时长。
    public mutating func beginRequest(at now: Date = Date()) {
        guard requestStart == nil else { return }
        requestStart = now
    }

    /// 收到一片增量(content 和 reasoning 各算一片 ≈ 一个 token,量级够用)。
    /// 返回值 = 这一片之后该不该把数字推给 UI(内部按 `publishInterval` 节流)。
    public mutating func markDelta(at now: Date = Date()) -> Bool {
        if requestStart == nil { requestStart = now }
        if requestFirstDelta == nil { requestFirstDelta = now }
        requestDeltas += 1
        guard let last = lastPublish else {
            lastPublish = now
            return true
        }
        guard now.timeIntervalSince(last) >= Self.publishInterval else { return false }
        lastPublish = now
        return true
    }

    /// 服务端报上来的精确 usage。同一次请求里报多次按最后一次算。
    public mutating func report(inputTokens: Int?, outputTokens: Int?, at now: Date = Date()) {
        if requestStart == nil { requestStart = now }
        if let inputTokens { requestInput = inputTokens }
        if let outputTokens { requestOutput = outputTokens }
    }

    /// 这次请求结束,折进累计。没开过请求是空操作。
    public mutating func endRequest(at now: Date = Date()) {
        guard let start = requestStart else { return }
        if let output = requestOutput {
            exactOutput += output
            if let input = requestInput { exactInput = (exactInput ?? 0) + input }
        } else {
            // 没报 usage:用分片计数兜底,并记下"这轮掺了估算值"。
            estimatedOutput += requestDeltas
            missingExact = true
        }
        generatingSeconds += max(0, now.timeIntervalSince(requestFirstDelta ?? start))
        requests += 1
        clearRequest()
    }

    /// 丢掉进行中那次请求的计数(流式失败要退回一次性请求时用:同一次逻辑请求
    /// 不能在这儿数一遍、在 `cloudRequest` 里再数一遍)。
    public mutating func discardRequest() {
        clearRequest()
    }

    private mutating func clearRequest() {
        requestStart = nil
        requestFirstDelta = nil
        requestDeltas = 0
        requestInput = nil
        requestOutput = nil
    }

    /// 当前快照。进行中那次请求按分片估算先算进去(否则一轮对话从头到尾都是 0)。
    public func snapshot(at now: Date = Date()) -> AIUsage {
        var output = exactOutput + estimatedOutput
        var seconds = generatingSeconds
        var estimated = missingExact
        if let start = requestStart {
            output += requestOutput ?? requestDeltas
            if requestOutput == nil, requestDeltas > 0 { estimated = true }
            if let first = requestFirstDelta {
                seconds += max(0, now.timeIntervalSince(first))
            } else if requestOutput != nil {
                seconds += max(0, now.timeIntervalSince(start))
            }
        }
        return AIUsage(inputTokens: exactInput, outputTokens: output,
                       isEstimated: estimated, generatingSeconds: seconds,
                       requests: requests, isStreaming: requestStart != nil)
    }
}

/// 进程内的用量观察点:`DeepSeekClient` 往里写,AI 助手页标题行读。
/// 不持久化——这是可重算的瞬时观测值,重启从空开始正合适(同
/// `NotificationBudgetState` 的定位)。
///
/// 只在网络请求那条上下文里更新,和 `onStream` 回调同一条路,没有额外的并发入口。
@Observable public final class AIUsageMonitor {
    public static let shared = AIUsageMonitor()

    /// 进行中或最近一轮的用量;nil = 这次运行还没发过 AI 助手请求。
    public private(set) var turn: AIUsage?

    private var accumulator = AIUsageAccumulator()
    /// 有人显式开了一轮(`route()`)。没开就来报数的(Watch 直接调 command)
    /// 按"一次请求就是一轮"处理,别往上一轮里加。
    private var turnOpen = false
    private var implicitTurn = false

    public init() {}

    public func beginTurn() {
        accumulator = AIUsageAccumulator()
        turnOpen = true
        implicitTurn = false
        // 这里**不清 turn**:新一轮还没数出东西之前先留着上一轮的数字,
        // 免得这行小字闪回「联网搜索」再闪成速度。第一片增量一到就被顶掉。
    }

    public func endTurn(at now: Date = Date()) {
        // 中途抛错的请求没人调 endRequest,在这儿兜底折进累计。
        accumulator.endRequest(at: now)
        turnOpen = false
        implicitTurn = false
        publish(at: now)
    }

    public func beginRequest(at now: Date = Date()) {
        openTurnIfNeeded()
        accumulator.beginRequest(at: now)
    }

    public func noteDelta(at now: Date = Date()) {
        openTurnIfNeeded()
        guard accumulator.markDelta(at: now) else { return }
        publish(at: now)
    }

    public func report(inputTokens: Int?, outputTokens: Int?, at now: Date = Date()) {
        openTurnIfNeeded()
        accumulator.report(inputTokens: inputTokens, outputTokens: outputTokens, at: now)
    }

    public func endRequest(at now: Date = Date()) {
        accumulator.endRequest(at: now)
        publish(at: now)
        if implicitTurn { turnOpen = false; implicitTurn = false }
    }

    public func discardRequest() {
        accumulator.discardRequest()
    }

    #if DEBUG
    /// 截图验证用:直接摆一轮完成态的数字,不走网络。
    public func seed(_ usage: AIUsage) { turn = usage }
    #endif

    private func openTurnIfNeeded() {
        guard !turnOpen else { return }
        beginTurn()
        implicitTurn = true
    }

    private func publish(at now: Date) {
        let snapshot = accumulator.snapshot(at: now)
        // 新一轮还没数出东西:留着上一轮的数字(见 beginTurn 的注释)。
        if snapshot.badge == nil, turnOpen, turn != nil { return }
        turn = snapshot.badge == nil ? nil : snapshot
    }
}
