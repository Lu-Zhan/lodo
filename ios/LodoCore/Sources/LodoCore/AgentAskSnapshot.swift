import Foundation

/// AI 反问时给出的一个候选项:简短 label + 一句话说明,recommended 为推荐项
/// (卡片上打「推荐」角标)。
public struct AskOption: Codable, Equatable {
    public var label: String
    /// 选它意味着什么;模型没给时为空字符串,卡片上这一行自然不渲染。
    public var description: String
    public var recommended: Bool

    public init(label: String, description: String = "", recommended: Bool = false) {
        self.label = label
        self.description = description
        self.recommended = recommended
    }
}

/// 一道反问题目。一次反问可以有多道,由询问卡的翻页器逐题作答。
public struct AskQuestion: Codable, Equatable {
    /// ≤6 字的短标签,显示在问题上方(如"提醒时间")。
    public var header: String
    public var question: String
    public var multiSelect: Bool
    public var options: [AskOption]

    public init(header: String = "", question: String, multiSelect: Bool = false,
                options: [AskOption]) {
        self.header = header
        self.question = question
        self.multiSelect = multiSelect
        self.options = options
    }
}

/// AI 助手对话里一次反问的快照——待回答阶段(answers 为空)和已回答阶段
/// (answers 与 questions 等长)都用这一个结构体,序列化成 JSON 存进
/// AgentMessage,供聊天气泡渲染询问卡 / 记录卡(与 AgentTaskSnapshot 同一个套路)。
public struct AgentAskSnapshot: Codable, Equatable {
    public var questions: [AskQuestion]
    /// 与 questions 等长;每题已选的文案(单选也是数组,元素可能是"其他"里手打的)。
    /// 整体为空 = 还没作答。
    public var answers: [[String]]

    public init(questions: [AskQuestion], answers: [[String]] = []) {
        self.questions = questions
        self.answers = answers
    }

    /// 记录卡 / 回传给模型的可读文本:逐题「问:… 答:…」。
    public var transcript: String {
        questions.enumerated().map { index, question in
            let answer = index < answers.count ? answers[index].joined(separator: "、") : ""
            return "问:\(question.question)\n答:\(answer)"
        }.joined(separator: "\n\n")
    }
}
