import SwiftUI
import LodoCore

/// AI 信息不足时的询问卡(参考 Claude app 的提问卡片):一次可以问多道题,
/// 顶部翻页器逐题作答,每个选项是「标题 + 一句话说明」,推荐项打角标,
/// 底部还有一个"其他"自由输入。答完最后一题点"完成"把答案交回去。
/// 只用 SwiftUI 系统控件,不自绘。
struct AgentAskCard: View {
    let snapshot: AgentAskSnapshot
    /// 每题的答案,与 snapshot.questions 等长。
    let onSubmit: ([[String]]) -> Void
    let onCancel: () -> Void

    @State private var currentIndex = 0
    /// 逐题的已选 label;单选题也是数组(只放一个),方便和多选统一处理。
    @State private var picked: [Set<String>]
    /// 逐题"其他"输入框里的文字;非空时算作这题的一个答案。
    @State private var otherText: [String]

    init(snapshot: AgentAskSnapshot, onSubmit: @escaping ([[String]]) -> Void,
         onCancel: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _picked = State(initialValue: Array(repeating: [], count: snapshot.questions.count))
        _otherText = State(initialValue: Array(repeating: "", count: snapshot.questions.count))
    }

    private var question: AskQuestion { snapshot.questions[currentIndex] }
    private var isLastQuestion: Bool { currentIndex == snapshot.questions.count - 1 }

    /// 当前题的答案:选中的选项 + "其他"里手打的内容(有才算)。
    private func answers(at index: Int) -> [String] {
        let selected = snapshot.questions[index].options
            .map(\.label).filter { picked[index].contains($0) }
        let other = otherText[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return other.isEmpty ? selected : selected + [other]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if snapshot.questions.count > 1 { pager }
            questionHeader
            optionList
            otherField
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary,
                    in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
    }

    /// 「‹ 第 N / M 题 ›」;到头的方向直接禁用,不做循环翻页。
    private var pager: some View {
        HStack(spacing: 12) {
            Button {
                currentIndex -= 1
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(currentIndex == 0)

            Text("第 \(currentIndex + 1) / \(snapshot.questions.count) 题")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                currentIndex += 1
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            // 往后翻同样要求当前题已经答了,免得跳过去以后回不到"能提交"的状态。
            .disabled(isLastQuestion || answers(at: currentIndex).isEmpty)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var questionHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if !question.header.isEmpty {
                    Text(question.header)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(question.question)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("跳过提问")
        }
    }

    private var optionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                if index > 0 { Divider() }
                optionRow(option)
            }
        }
    }

    private func optionRow(_ option: AskOption) -> some View {
        let isSelected = picked[currentIndex].contains(option.label)
        return Button {
            toggle(option.label)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if option.recommended {
                            Text("推荐")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15),
                                            in: Capsule())
                                .foregroundStyle(.tint)
                        }
                    }
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 单选题选中即替换,多选题累加;两种都允许再点一下取消选择。
    private func toggle(_ label: String) {
        if picked[currentIndex].contains(label) {
            picked[currentIndex].remove(label)
            return
        }
        if question.multiSelect {
            picked[currentIndex].insert(label)
        } else {
            picked[currentIndex] = [label]
            // 单选题选了现成选项就把"其他"清掉,避免同时给出两个答案。
            otherText[currentIndex] = ""
        }
    }

    private var otherField: some View {
        TextField("其他", text: $otherText[currentIndex], axis: .vertical)
            .textFieldStyle(.plain)
            .font(.subheadline)
            .lineLimit(1...3)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // 圆角跟着气泡/卡片走(bubbleRadius),聊天页里这一块的形状语言只有一种。
            .background(.fill.tertiary,
                        in: RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous))
            .onChange(of: otherText[currentIndex]) { _, newValue in
                // 单选题手打了内容就顶掉已选项,和 toggle() 的规则对称。
                if !question.multiSelect,
                   !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    picked[currentIndex] = []
                }
            }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button {
                if isLastQuestion {
                    Haptics.success()
                    onSubmit((0..<snapshot.questions.count).map { answers(at: $0) })
                } else {
                    currentIndex += 1
                }
            } label: {
                Label(isLastQuestion ? "完成" : "下一项",
                      systemImage: isLastQuestion ? "checkmark" : "arrow.right")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 4)
                    .frame(height: 32)
            }
            .glassProminentButton()
            .buttonBorderShape(.capsule)
            // 最后一题要求前面每题都答过(可以翻回去补),中间题只看当前这题。
            .disabled(isLastQuestion
                      ? (0..<snapshot.questions.count).contains { answers(at: $0).isEmpty }
                      : answers(at: currentIndex).isEmpty)
        }
    }
}

/// 答完后留在对话里的记录卡(参考图二):细边框、不填充,逐题「问题(灰)+ 答案」。
/// 历史消息里那张还没答完的询问卡也退化成这个只读形态。
struct AgentAskRecordCard: View {
    let snapshot: AgentAskSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(snapshot.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.question)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    let answer = index < snapshot.answers.count
                        ? snapshot.answers[index].joined(separator: "、") : ""
                    Text(answer.isEmpty ? "未回答" : answer)
                        .font(.subheadline)
                        .foregroundStyle(answer.isEmpty ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: DesignMetrics.bubbleRadius, style: .continuous)
                .stroke(.separator))
    }
}
