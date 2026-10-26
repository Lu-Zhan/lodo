#if os(iOS)
import UIKit
import LodoKeyboardModel

/// 一颗键画成什么样,由控制器按当前状态(shift、中英、回车类型)给出。
struct KeyFace {
    var title: NSAttributedString?
    var symbol: String?
    var font: UIFont
    var prominent = false
    var accessibility: String
    /// 右下角的小字(中文时空格上的「拼」,同系统)。
    var corner: String? = nil
}

@MainActor
protocol KeyAreaDelegate: AnyObject {
    func keyArea(trigger action: KeyAction)
    /// 空格横拖要不要进光标模式(拼到一半、面板里都不行:那时照常打空格)。
    func keyAreaCanMoveCursor() -> Bool
    func keyArea(moveCursorBy offset: Int)
    func keyAreaPlayClick(for action: KeyAction)
    /// 删除连删的每一下(轻一点的震动)。
    func keyAreaRepeatFeedback()
}

/// 整块键区:摆键帽、收所有触摸。触摸不交给每颗键各自处理——那样多指快打、按住滑到隔壁键、
/// 点在键缝里都会丢键。
final class KeyAreaView: UIView {
    weak var delegate: KeyAreaDelegate?
    var metrics = KeyboardMetrics.phonePortrait
    /// iPad 和横屏手机不弹气泡(系统也不弹)。
    var showsCallouts = true

    private(set) var placed: [PlacedKey] = []
    private var keyViews: [KeyView] = []
    private let callout = CalloutView()
    /// 地球键的位置(键区坐标)。按钮本身由控制器常驻在最上层:它必须是真的 UIControl
    /// (`handleInputModeList(from:with:)` 要拿它的触摸事件),展开候选、看 AI 回答时也不能跟着键区藏起来。
    private(set) var globeFrame: CGRect?

    private struct Press {
        var index: Int
        let start: CGPoint
        /// 按下的时刻(`UITouch.timestamp`),rollover 时按它的先后提交。
        let began: TimeInterval
        var cursorMode = false
        var cursorAnchorX: CGFloat = 0
        /// 按住超过门槛:松手执行长按动作。
        var held = false
    }
    private var presses: [UITouch: Press] = [:]
    private var repeatTimer: Timer?
    private var repeatCount = 0
    /// 每根手指自己的长按计时器:别的手指松开不能取消它。
    private var holdTimers: [UITouch: Timer] = [:]
    static let holdDelay: TimeInterval = 0.4

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        callout.isHidden = true
        addSubview(callout)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 换一页键(或者宽度变了)。键帽视图按需重建。
    func setRows(_ rows: [[Key]], face: (Key) -> KeyFace) {
        setPlaced(KeyboardFrames.place(rows, width: bounds.width, metrics: metrics), face: face)
    }

    /// 键位已经算好(九宫格不是一行行排的)。
    func setPlaced(_ newPlaced: [PlacedKey], face: (Key) -> KeyFace) {
        if newPlaced.map(\.key) != placed.map(\.key) {
            cancelAllPresses()
            keyViews.forEach { $0.removeFromSuperview() }
            keyViews = newPlaced.map { KeyView(key: $0.key) }
            keyViews.forEach { insertSubview($0, belowSubview: callout) }
        }
        placed = newPlaced
        globeFrame = nil
        for (i, p) in placed.enumerated() {
            let v = keyViews[i]
            v.frame = p.frame
            v.layer.cornerRadius = metrics.cornerRadius
            let f = face(p.key)
            v.configure(title: f.title, symbol: f.symbol, font: f.font, prominent: f.prominent,
                        hint: p.key.holdHint, corner: f.corner, accessibility: f.accessibility)
            let action = p.key.action
            v.onActivate = { [weak self] in self?.delegate?.keyArea(trigger: action) }
            if action == .nextKeyboard {
                globeFrame = p.hitFrame
                v.isAccessibilityElement = false // 辅助功能走上层那颗真按钮
            }
        }
    }

    // MARK: - 触摸

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            // 前面还有按着、松手才生效的键就来了新的一指:按按下的先后把它们先提交掉
            // (快打时两指会重叠;按住空格再点字母,空格得在字母前面)。
            let pending = presses.filter { placed.indices.contains($0.value.index)
                && Self.firesOnRelease(placed[$0.value.index].key.action) && !$0.value.cursorMode }
                .sorted { $0.value.began < $1.value.began }
            for (other, _) in pending {
                // 前一颗提交时可能换了页(123 / 中英),换页会清掉所有按着的记录,这里要重新取。
                guard let current = presses[other] else { continue }
                finish(other, current, trigger: true)
            }
            // **提交完再判断落点**:换页之后 `placed` 已经是新的一页,用旧下标会按错键甚至越界。
            guard let i = KeyboardFrames.key(at: touch.location(in: self), in: placed) else { continue }
            presses[touch] = Press(index: i, start: touch.location(in: self), began: touch.timestamp)
            press(i, touch: touch)
        }
    }

    /// 松手才生效的键(删除、shift 按下就生效,地球键交给系统)。
    static func firesOnRelease(_ action: KeyAction) -> Bool {
        switch action {
        case .delete, .shift, .nextKeyboard: false
        default: true
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard var p = presses[touch], placed.indices.contains(p.index) else { continue }
            let point = touch.location(in: self)
            let action = placed[p.index].key.action
            if action == .space {
                // 在空格上横着拖:移动光标,每 9pt 一个字。不允许挪的时候不进这个模式,松手照常是空格。
                if !p.cursorMode, abs(point.x - p.start.x) > 12, delegate?.keyAreaCanMoveCursor() == true {
                    p.cursorMode = true
                    p.cursorAnchorX = point.x
                    keyViews[p.index].isPressed = true
                }
                if p.cursorMode {
                    let steps = Int((point.x - p.cursorAnchorX) / 9)
                    if steps != 0 {
                        delegate?.keyArea(moveCursorBy: steps)
                        p.cursorAnchorX += CGFloat(steps) * 9
                    }
                }
                presses[touch] = p
                continue
            }
            // 字符键按住滑到隔壁:改按隔壁那颗(系统键盘也是这样纠正按偏)。长按已经生效的不换。
            guard !p.held, placed[p.index].key.showsCallout,
                  let j = KeyboardFrames.key(at: point, in: placed), j != p.index, placed[j].key.showsCallout else { continue }
            release(p.index)
            p.index = j
            p.held = false
            presses[touch] = p
            press(j, touch: touch, clicks: false)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let p = presses[touch] else { continue }
            finish(touch, p, trigger: true)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let p = presses[touch] else { continue }
            finish(touch, p, trigger: false)
        }
    }

    private func press(_ i: Int, touch: UITouch, clicks: Bool = true) {
        let key = placed[i].key
        keyViews[i].isPressed = true
        if clicks { delegate?.keyAreaPlayClick(for: key.action) }
        if key.showsCallout && showsCallouts, let text = keyViews[i].accessibilityLabel {
            callout.show(text, over: placed[i].frame, in: bounds, cornerRadius: metrics.cornerRadius)
        }
        holdTimers.removeValue(forKey: touch)?.invalidate()
        if let hint = key.holdHint, key.holdAction != nil {
            // 按住到门槛:气泡里换成长按的那个字,松手执行长按动作。
            holdTimers[touch] = Timer.scheduledTimer(withTimeInterval: Self.holdDelay, repeats: false) { [weak self, weak touch] _ in
                MainActor.assumeIsolated {
                    guard let self, let touch, var p = self.presses[touch], p.index == i,
                          self.placed.indices.contains(i) else { return }
                    p.held = true
                    self.presses[touch] = p
                    self.callout.show(hint, over: self.placed[i].frame, in: self.bounds, cornerRadius: self.metrics.cornerRadius)
                }
            }
        }
        switch key.action {
        case .delete:
            // 删除:按下就删一个,按住 0.45 秒后连删,连删十几下之后改成按词删。
            delegate?.keyArea(trigger: .delete)
            startRepeat()
        case .shift:
            delegate?.keyArea(trigger: .shift) // shift 按下即生效,按住 shift 打字才跟手
        default:
            break
        }
    }

    private func release(_ i: Int) {
        if keyViews.indices.contains(i) { keyViews[i].isPressed = false }
        callout.isHidden = true
    }

    private func finish(_ touch: UITouch, _ p: Press, trigger: Bool) {
        presses[touch] = nil
        holdTimers.removeValue(forKey: touch)?.invalidate()
        guard placed.indices.contains(p.index) else { return }
        release(p.index)
        let key = placed[p.index].key
        switch key.action {
        case .delete:
            stopRepeat()
        case .shift, .nextKeyboard:
            break
        case .space where p.cursorMode:
            break
        default:
            guard trigger else { return }
            delegate?.keyArea(trigger: p.held ? (key.holdAction ?? key.action) : key.action)
        }
    }

    private func cancelAllPresses() {
        for (touch, p) in presses { finish(touch, p, trigger: false) }
        presses = [:]
        holdTimers.values.forEach { $0.invalidate() }
        holdTimers = [:]
        stopRepeat()
    }

    /// 截图用:不经触摸,直接摆出按住这颗键的样子。
    func debugHold(_ action: KeyAction) {
        guard let i = placed.firstIndex(where: { $0.key.action == action }) else { return }
        keyViews[i].isPressed = true
        if let text = keyViews[i].accessibilityLabel {
            callout.show(text, over: placed[i].frame, in: bounds, cornerRadius: metrics.cornerRadius)
        }
    }

    private func startRepeat() {
        stopRepeat()
        repeatCount = 0
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRepeat(interval: 0.09, action: .delete) }
        }
    }

    private func scheduleRepeat(interval: TimeInterval, action: KeyAction) {
        repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.delegate?.keyArea(trigger: action)
                self.delegate?.keyAreaRepeatFeedback()
                self.repeatCount += 1
                if action == .delete, self.repeatCount == 12 {
                    self.repeatTimer?.invalidate()
                    self.scheduleRepeat(interval: 0.22, action: .deleteWord)
                }
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}
#endif
