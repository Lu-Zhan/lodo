import SwiftUI
import UIKit
import LodoCore

/// 键盘整体:普通模式是候选栏 + 按键区;点了 AI 键,键盘整体长高一截,
/// 最上面多出一行 AI 对话框(输入框 / 问题标题),下面的候选栏照常可用,
/// 在对话框里打拼音也能选字。选项层、结果卡**盖在按键区上**,不会再额外撑高。
/// 高度由 KeyboardViewController 按 `aiOpen` 切换(`KeyboardLayout`)。
struct KeyboardRoot: View {
    @ObservedObject var state: KeyboardState
    @Namespace private var aiKeySpace

    var body: some View {
        VStack(spacing: 0) {
            if state.aiOpen {
                AIDialogRow(state: state, aiKeySpace: aiKeySpace)
                    .frame(height: KeyboardLayout.aiRowHeight)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            CandidateBar(state: state, aiKeySpace: aiKeySpace)
                .frame(height: KeyboardLayout.candidateBarHeight)
                .zIndex(1)
            ZStack {
                KeyArea(state: state)
                    // 按键在选项层/结果卡后面仍然隐约可见,但不接收点击。
                    .allowsHitTesting(!coversKeys)
                if coversKeys {
                    KeyboardOverlay(state: state)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
        }
        .animation(KeyboardMotion.standard, value: coversKeys)
        .animation(KeyboardMotion.standard, value: state.aiOpen)
        .animation(KeyboardMotion.standard, value: state.toast)
    }

    private var coversKeys: Bool {
        state.aiOpen && (state.card != nil || (state.showingOptions && state.hasPendingQuestion))
    }
}

/// 键盘各段高度。普通模式 = 候选栏 + 按键区;AI 模式再加一行对话框。
enum KeyboardLayout {
    static let candidateBarHeight: CGFloat = 40
    static let aiRowHeight: CGFloat = 52
    /// 四行按键:竖屏每行 52(系统键盘的节距),横屏压扁。
    static let portraitKeysHeight: CGFloat = 212
    static let landscapeKeysHeight: CGFloat = 152

    static func height(landscape: Bool, aiOpen: Bool) -> CGFloat {
        candidateBarHeight + (landscape ? landscapeKeysHeight : portraitKeysHeight)
            + (aiOpen ? aiRowHeight : 0)
    }
}

enum KeyboardMotion {
    static var standard: Animation? {
        UIAccessibility.isReduceMotionEnabled ? nil : .snappy(duration: 0.25)
    }
}

// MARK: - AI 对话框行

/// AI 模式下最上面那一行:输入框(或问题标题 / 结果卡抬头)+ 右上角 ✕。
private struct AIDialogRow: View {
    @ObservedObject var state: KeyboardState
    let aiKeySpace: Namespace.ID

    var body: some View {
        KeyboardGlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                leading
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                AIKey(state: state)
                    .matchedGeometryEffect(id: "aiKey", in: aiKeySpace)
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.top, 6)
        }
    }

    @ViewBuilder private var leading: some View {
        if state.showingOptions, let question = state.currentQuestion {
            QuestionTitle(question: question, index: state.questionIndex, total: state.questions.count)
        } else if state.card != nil {
            Label("lodo AI", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            AIInputField(state: state)
        }
    }
}

// MARK: - 候选栏

private struct CandidateBar: View {
    @ObservedObject var state: KeyboardState
    let aiKeySpace: Namespace.ID

    var body: some View {
        HStack(spacing: 8) {
            leading
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // 普通模式下 AI 键在候选栏右端(也就是键盘右上角);AI 模式下它
            // 挪到更上面那行对话框的右端,仍然是整块键盘的右上角。
            if !state.aiOpen {
                AIKey(state: state)
                    .matchedGeometryEffect(id: "aiKey", in: aiKeySpace)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
    }

    @ViewBuilder private var leading: some View {
        if let toast = state.toast {
            ToastPill(text: toast)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else if state.composing {
            CandidateStrip(state: state)
        } else if let status = state.backgroundStatus {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// 右上角的 AI 键:普通模式是 ✨,进了 AI 模式变成 ✕(退出回普通输入)。
private struct AIKey: View {
    @ObservedObject var state: KeyboardState

    var body: some View {
        Button {
            state.toggleAI()
        } label: {
            Image(systemName: state.aiOpen ? "xmark" : "sparkles")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(state.aiOpen ? AnyShapeStyle(.primary) : AnyShapeStyle(KeyboardColors.accent))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                .keyboardGlass(Circle(), interactive: true)
                .overlay(alignment: .topTrailing) {
                    // 选项层被收起、问题还没答:角上一个小点提醒还有件事等着决定。
                    if !state.aiOpen && state.hasPendingQuestion {
                        Circle().fill(KeyboardColors.accent)
                            .frame(width: 8, height: 8)
                            .offset(x: 1, y: -1)
                    }
                }
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(KeyboardPressStyle())
        .accessibilityLabel(state.aiOpen ? "退出 AI" : "lodo AI")
    }
}

/// AI 输入框:键盘自己的按键往这里打字,不进宿主 app。
private struct AIInputField: View {
    @ObservedObject var state: KeyboardState

    var body: some View {
        HStack(spacing: 6) {
            if state.hasPendingQuestion {
                Button {
                    state.showOptions()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(KeyboardPressStyle())
                .accessibilityLabel("回到选项")
            }
            if state.busy {
                ProgressView().controlSize(.small)
                Text("正在思考…").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 1) {
                    if state.aiText.isEmpty {
                        BlinkingCaret()
                        Text(state.answeringOther ? "写下你的回答…" : "问问 AI,或让它记下一件事")
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(state.aiText)
                            .truncationMode(.head)
                        BlinkingCaret()
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !state.aiText.isEmpty {
                    Button {
                        state.submitInput()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(KeyboardColors.onAccent)
                            .frame(width: 28, height: 28)
                            .background(KeyboardColors.accent, in: Circle())
                    }
                    .buttonStyle(KeyboardPressStyle())
                    .accessibilityLabel("发送")
                }
            }
        }
        .font(.body)
        .padding(.leading, state.hasPendingQuestion ? 4 : 14)
        .padding(.trailing, 4)
        .frame(height: 40)
        .keyboardGlass(Capsule())
    }
}

private struct BlinkingCaret: View {
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(KeyboardColors.accent)
            .frame(width: 2, height: 20)
            .opacity(visible ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.5).repeatForever()) { visible = false }
            }
    }
}

private struct QuestionTitle: View {
    let question: AskQuestion
    let index: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !question.header.isEmpty || total > 1 {
                Text([question.header, total > 1 ? "\(index + 1)/\(total)" : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(question.question)
                .font(.subheadline.weight(.semibold))
                .lineLimit(question.header.isEmpty && total <= 1 ? 2 : 1)
                .minimumScaleFactor(0.85)
        }
    }
}

private struct ToastPill: View {
    let text: String

    var body: some View {
        Label(text, systemImage: text == "等下再决定" ? "clock" : "checkmark")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .keyboardGlass(Capsule())
    }
}

private struct CandidateStrip: View {
    @ObservedObject var state: KeyboardState

    var body: some View {
        HStack(spacing: 10) {
            Text(state.ime.committed + state.ime.raw)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(state.ime.candidates.enumerated()), id: \.offset) { index, word in
                        Button {
                            state.select(word)
                        } label: {
                            Text(word)
                                .font(.system(size: 20))
                                .foregroundStyle(index == 0 ? KeyboardColors.accent : .primary)
                                .padding(.horizontal, 10)
                                .frame(height: KeyboardLayout.candidateBarHeight)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(KeyboardPressStyle())
                    }
                }
            }
        }
    }
}

// MARK: - 覆盖层(选项 / 结果卡)

private struct KeyboardOverlay: View {
    @ObservedObject var state: KeyboardState

    var body: some View {
        Group {
            if let card = state.card {
                ResultPanel(card: card, state: state)
            } else if let question = state.currentQuestion {
                OptionPanel(question: question, state: state)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 半透明的一层:按键还隐约看得见,提醒这是临时盖上去的。
        .background(.ultraThinMaterial.opacity(0.92))
    }
}

/// 参考 app 里的 AgentAskCard:逐项「字母 + 标题 + 一句话说明」,推荐项打角标;
/// 最后一行是输入框,写选项之外的回答。
private struct OptionPanel: View {
    let question: AskQuestion
    @ObservedObject var state: KeyboardState

    var body: some View {
        KeyboardGlassGroup(spacing: 6) {
            VStack(spacing: 6) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                            optionRow(option, letter: Self.letter(index))
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                HStack(spacing: 6) {
                    Button {
                        state.writeOther()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(KeyboardColors.accent)
                            Text("其他,自己写…")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .font(.body)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .keyboardGlass(Capsule(), interactive: true)
                    }
                    .buttonStyle(KeyboardPressStyle())
                    if question.multiSelect {
                        Button {
                            state.confirmPicked()
                        } label: {
                            Text("确定")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(KeyboardColors.onAccent)
                                .padding(.horizontal, 18)
                                .frame(height: 40)
                                .keyboardGlass(Capsule(), interactive: true, tint: KeyboardColors.accent)
                        }
                        .buttonStyle(KeyboardPressStyle())
                        .disabled(state.picked.isEmpty)
                        .opacity(state.picked.isEmpty ? 0.5 : 1)
                    }
                }
            }
        }
    }

    static func letter(_ index: Int) -> String {
        index < 26 ? String(UnicodeScalar(UInt8(65 + index))) : "\(index + 1)"
    }

    private func optionRow(_ option: AskOption, letter: String) -> some View {
        let selected = state.picked.contains(option.label)
        return Button {
            state.pick(option)
        } label: {
            HStack(spacing: 10) {
                Text(letter)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(selected ? KeyboardColors.onAccent : KeyboardColors.accent)
                    .frame(width: 24, height: 24)
                    .background(selected ? KeyboardColors.accent : KeyboardColors.accent.opacity(0.15),
                                in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if option.recommended {
                            Text("推荐")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(KeyboardColors.accent.opacity(0.15), in: Capsule())
                                .foregroundStyle(KeyboardColors.accent)
                        }
                    }
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KeyboardColors.accent)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 44)
            .keyboardGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(KeyboardPressStyle())
    }
}

private struct ResultPanel: View {
    let card: KeyboardCard
    @ObservedObject var state: KeyboardState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(showsIndicators: false) {
                Text(card.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 8) {
                if !card.note.isEmpty {
                    Text(card.note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let action = card.action {
                    Button {
                        state.perform(action)
                    } label: {
                        Text(Self.title(action))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Self.isPrimary(action) ? KeyboardColors.onAccent : Color.primary)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .keyboardGlass(Capsule(), interactive: true,
                                           tint: Self.isPrimary(action) ? KeyboardColors.accent : nil)
                    }
                    .buttonStyle(KeyboardPressStyle())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .keyboardGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    static func title(_ action: KeyboardCardAction) -> String {
        switch action {
        case .insert: "插入"
        case .undo: "撤销"
        case .confirmCreates: "确认添加"
        case .saveSuggestion: "收藏这条"
        }
    }

    /// 撤销是次要操作,不给强调色。
    static func isPrimary(_ action: KeyboardCardAction) -> Bool {
        if case .undo = action { return false }
        return true
    }
}

// MARK: - 按键区

private struct KeyArea: View {
    @ObservedObject var state: KeyboardState

    private static let letters: [[String]] = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { $0.map(String.init) }
    private static let numbers: [[String]] = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", "：", "；", "（", "）", "¥", "@", "“", "”"],
        ["。", "，", "、", "？", "！", "."],
    ]
    private static let symbols: [[String]] = [
        ["【", "】", "｛", "｝", "#", "%", "^", "*", "+", "="],
        ["_", "—", "\\", "｜", "～", "《", "》", "$", "&", "·"],
        ["…", "，", "^_^", "？", "！", "‘"],
    ]

    var body: some View {
        GeometryReader { proxy in
            let metrics = KeyMetrics(size: proxy.size)
            VStack(spacing: 0) {
                let rows = state.page == 0 ? Self.letters : state.page == 1 ? Self.numbers : Self.symbols
                row(rows[0], metrics: metrics)
                if state.page == 0 {
                    // 第二行九个键,两头各缩进半个键,和系统键盘一样;缩进的那半格仍归 a/l 接收点击。
                    HStack(spacing: 0) {
                        ForEach(Array(rows[1].enumerated()), id: \.offset) { index, key in
                            letterKey(key, metrics: metrics,
                                      width: metrics.cell * (index == 0 || index == 8 ? 1.5 : 1),
                                      alignment: index == 0 ? .trailing : index == 8 ? .leading : .center)
                        }
                    }
                } else {
                    row(rows[1], metrics: metrics)
                }
                thirdRow(rows[2], metrics: metrics)
                bottomRow(metrics: metrics)
            }
            .padding(.bottom, metrics.bottomPadding)
        }
    }

    private func row(_ keys: [String], metrics: KeyMetrics) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                letterKey(key, metrics: metrics, width: metrics.cell)
            }
        }
    }

    private func thirdRow(_ keys: [String], metrics: KeyMetrics) -> some View {
        let side = metrics.cell * 1.5
        let middle = (metrics.width - side * 2) / CGFloat(keys.count)
        return HStack(spacing: 0) {
            if state.page == 0 {
                KeyCell(metrics: metrics, width: side, visualWidth: metrics.cell * 1.3, alignment: .leading,
                        style: state.shift ? .letter : .function, onPress: { state.shiftTap() }) {
                    Image(systemName: state.locked ? "capslock.fill" : state.shift ? "shift.fill" : "shift")
                        .font(.system(size: 18, weight: .medium))
                }
            } else {
                KeyCell(metrics: metrics, width: side, visualWidth: metrics.cell * 1.3, alignment: .leading,
                        style: .function, onRelease: { state.page = state.page == 1 ? 2 : 1 }) {
                    Text(state.page == 1 ? "#+=" : "123").font(.system(size: 16))
                }
            }
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                letterKey(key, metrics: metrics, width: middle)
            }
            KeyCell(metrics: metrics, width: side, visualWidth: metrics.cell * 1.3, alignment: .trailing,
                    style: .function, repeats: true, onPress: { state.delete() }) {
                Image(systemName: "delete.left")
                    .font(.system(size: 18, weight: .regular))
            }
            .accessibilityLabel("删除")
        }
    }

    private func bottomRow(metrics: KeyMetrics) -> some View {
        let small = metrics.cell * 1.25
        let punct = metrics.cell
        let returnWidth = metrics.cell * 2.25
        let fixed = small * (state.needsGlobe ? 2 : 1) + punct * 2 + returnWidth
        return HStack(spacing: 0) {
            KeyCell(metrics: metrics, width: small, style: .function,
                    onRelease: { state.page = state.page == 0 ? 1 : 0 }) {
                Text(state.page == 0 ? "123" : "拼音").font(.system(size: 16))
            }
            if state.needsGlobe {
                KeyCell(metrics: metrics, width: small, style: .function, onRelease: {}) {
                    GlobeKey(target: state.inputModeTarget)
                }
                .accessibilityLabel("下一个键盘")
            }
            letterKey("，", metrics: metrics, width: punct, callout: false) { state.punctuation("，") }
            KeyCell(metrics: metrics, width: metrics.width - fixed, style: .letter,
                    onRelease: { state.space() }) {
                Text("空格").font(.system(size: 16))
            }
            letterKey("。", metrics: metrics, width: punct, callout: false) { state.punctuation("。") }
            KeyCell(metrics: metrics, width: returnWidth, style: returnStyle, onRelease: { state.enter() }) {
                Text(returnTitle).font(.system(size: 16))
            }
        }
    }

    private var returnTitle: String {
        if state.composing { return "确认" }
        if state.aiOpen { return "发送" }
        switch state.returnKeyType {
        case .send: return "发送"
        case .search, .google, .yahoo: return "搜索"
        case .go, .route, .join: return "前往"
        case .done: return "完成"
        case .next: return "下一项"
        case .continue: return "继续"
        default: return "换行"
        }
    }

    private var returnStyle: KeyStyle {
        if state.composing { return .function }
        if state.aiOpen { return .accent }
        return state.returnKeyType == .default ? .function : .primary
    }

    private func letterKey(_ key: String, metrics: KeyMetrics, width: CGFloat,
                           alignment: Alignment = .center, callout: Bool = true,
                           action: (() -> Void)? = nil) -> some View {
        let shown = state.shift && state.page == 0 ? key.uppercased() : key
        return KeyCell(metrics: metrics, width: width, visualWidth: metrics.cell, alignment: alignment,
                       style: .letter, callout: callout ? shown : nil,
                       onRelease: action ?? { state.type(key) }) {
            Text(shown).font(.system(size: key.count > 1 ? 16 : 23, weight: .regular))
        }
    }
}

/// 按键尺寸按系统键盘的比例算:一格 = 宽度的 1/10,按键可见部分四周各留半个间隙,
/// 间隙本身仍归相邻按键接收点击(系统键盘就是这样,手指落在缝里不会落空)。
private struct KeyMetrics {
    let width: CGFloat
    let cell: CGFloat
    let rowHeight: CGFloat
    let hGap: CGFloat = 6
    let vGap: CGFloat
    let bottomPadding: CGFloat = 3

    init(size: CGSize) {
        width = size.width
        cell = size.width / 10
        rowHeight = (size.height - bottomPadding) / 4
        vGap = rowHeight > 48 ? 11 : 7
    }
}

private enum KeyStyle { case letter, function, primary, accent }

private struct KeyCell<Label: View>: View {

    let metrics: KeyMetrics
    let width: CGFloat
    var visualWidth: CGFloat?
    var alignment: Alignment = .center
    let style: KeyStyle
    var callout: String?
    var repeats = false
    /// 按下即触发(删除、Shift);其余按键和系统一样松手才上屏。
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    @ViewBuilder let label: () -> Label

    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    init(metrics: KeyMetrics, width: CGFloat, visualWidth: CGFloat? = nil, alignment: Alignment = .center,
         style: KeyStyle, callout: String? = nil, repeats: Bool = false,
         onPress: (() -> Void)? = nil, onRelease: (() -> Void)? = nil,
         @ViewBuilder label: @escaping () -> Label) {
        self.metrics = metrics; self.width = width; self.visualWidth = visualWidth
        self.alignment = alignment; self.style = style; self.callout = callout
        self.repeats = repeats; self.onPress = onPress; self.onRelease = onRelease; self.label = label
    }

    var body: some View {
        let keyWidth = min(width, visualWidth ?? width) - metrics.hGap
        let keyHeight = metrics.rowHeight - metrics.vGap
        let shape = RoundedRectangle(cornerRadius: KeyboardColors.keyRadius, style: .continuous)
        label()
            .foregroundStyle(foreground)
            .frame(width: keyWidth, height: keyHeight)
            .background {
                shape.fill(background)
                    .shadow(color: KeyboardColors.keyShadow, radius: 0, x: 0, y: 1)
            }
            .overlay(alignment: .bottom) {
                if pressed, let callout {
                    Text(callout)
                        .font(.system(size: 32, weight: .regular))
                        .frame(width: keyWidth + 14, height: keyHeight + 8)
                        .background(shape.fill(KeyboardColors.letterKey)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1))
                        .offset(y: -keyHeight - 4)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, metrics.hGap / 2)
            .frame(width: width, height: metrics.rowHeight, alignment: alignment)
            .contentShape(Rectangle())
            .zIndex(pressed ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        UIDevice.current.playInputClick()
                        onPress?()
                        if repeats { startRepeat() }
                    }
                    .onEnded { _ in
                        pressed = false
                        repeatTask?.cancel()
                        onRelease?()
                    })
    }

    private func startRepeat() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            while !Task.isCancelled {
                onPress?()
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private var background: Color {
        switch style {
        case .letter: pressed && callout == nil ? KeyboardColors.functionKey : KeyboardColors.letterKey
        case .function: pressed ? KeyboardColors.letterKey : KeyboardColors.functionKey
        case .primary: pressed ? KeyboardColors.functionKey : .accentColor
        case .accent: pressed ? KeyboardColors.functionKey : KeyboardColors.accent
        }
    }

    private var foreground: Color {
        switch style {
        case .letter, .function: .primary
        case .primary: pressed ? .primary : .white
        case .accent: pressed ? .primary : KeyboardColors.onAccent
        }
    }
}

/// 🌐 必须交给系统的 handleInputModeList 处理(长按弹出键盘列表)。
private struct GlobeKey: UIViewRepresentable {
    weak var target: UIInputViewController?

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "globe",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18)), for: .normal)
        button.tintColor = .label
        if let target {
            button.addTarget(target, action: #selector(UIInputViewController.handleInputModeList(from:with:)),
                             for: .allTouchEvents)
        }
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
