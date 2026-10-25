import LodoCore
import LodoKeyboardUI
import UIKit

/// ✨ 的实现。约定见 `KeyboardExchange`:只读主 app 写的快照,只往收件箱里写,
/// 不碰数据库——写进去的任务和记忆等用户下次打开 lodo 时入库。
///
/// 发给 AI 服务的只有:这次的问题、这个面板里前面几轮对话、从记忆快照里检索到的摘录。
/// **不发任务列表**——键盘里改不了已有任务(只能新建),带上它只是多送出一份隐私。
@MainActor
final class KeyboardLodoServices: LodoServices {
    unowned let controller: UIInputViewController
    /// 一次面板会话里的对话(反问选项、接着问);关掉面板就清。
    private var history: [(role: String, content: String)] = []
    private var snapshot = KeyboardExchange.Snapshot()
    /// 每关一次面板加一:关掉之后才回来的旧请求不能再写历史、写收件箱。
    private var conversation = 0

    init(controller: UIInputViewController) {
        self.controller = controller
        reload()
    }

    /// 每次弹出键盘时调:主 app 在扩展常驻期间可能改了设置、删了记忆。
    func reload() {
        KeyboardExchange.adoptMirroredSettings()
        snapshot = KeyboardExchange.loadSnapshot()
    }

    var hasFullAccess: Bool { controller.hasFullAccess }

    func endConversation() {
        history = []
        conversation += 1
    }

    func ask(_ question: String) async throws -> LodoReply {
        guard hasFullAccess else {
            return LodoReply(text: String(localized: "要先在系统设置里给 lodo 键盘打开「允许完全访问」(设置 → 通用 → 键盘 → 键盘 → lodo)"), insertable: false)
        }
        guard DeepSeekClient.isConfigured else {
            return LodoReply(text: String(localized: "还没在 lodo 里配置 AI 服务。"), insertable: false)
        }
        let session = conversation
        var reasoning = history
        var current = question
        for _ in 0..<3 {
            let result = try await DeepSeekClient.command(
                current, tasks: [], memoryEnabled: true, tracksUsage: false, history: reasoning)
            try checkStillCurrent(session)
            switch result {
            case .toolCall(let thought, .searchMemory(let query)):
                // 历史写法同手机/手表(模型那边看到的是同一种东西)。
                reasoning.append((role: "assistant", content: "思考:\(thought);查记忆:\(query)"))
                reasoning.append((role: "user", content: "记忆检索结果:\n\(KeyboardExchange.observation(for: query, in: snapshot))"))
                current = "(请基于以上记忆检索结果继续处理最初的请求:\(question))"
            case .toolCall:
                return finish(question, LodoReply(text: String(localized: "这个要打开 lodo 去问。"), insertable: false), session)
            case .ask(let questions):
                guard let first = questions.first else { break }
                return finish(question, LodoReply(text: first.question, insertable: false,
                                                  options: first.options.map(\.label)), session)
            case .actions(let actions):
                return finish(question, try await handle(actions, session: session), session)
            }
        }
        throw DeepSeekError.parse(String(localized: "多轮推理超过上限,换个说法试试"))
    }

    /// 面板已经关掉(或换了一轮对话)、请求被取消:这次的结果作废。
    private func checkStillCurrent(_ session: Int) throws {
        try Task.checkCancellation()
        if session != conversation { throw CancellationError() }
    }

    private func finish(_ question: String, _ reply: LodoReply, _ session: Int) -> LodoReply {
        guard session == conversation else { return reply }
        history.append((role: "user", content: question))
        history.append((role: "assistant", content: reply.text))
        history = Array(history.suffix(12))
        return reply
    }

    /// 要写进收件箱的一件事。
    private enum Write {
        case task(ParsedTask)
        case memory(text: String, title: String?, automatic: Bool)
    }

    /// 键盘里只做三类:回答(可插入)、记下任务/记忆(进收件箱,可撤销)、其余一句「去 lodo 里做」。
    /// 顺序:先把要联网的问答都求完 → 确认这轮还作数 → 最后才写收件箱。写到一半失败时,
    /// 已经写进去的照样报告、照样能撤销。
    private func handle(_ actions: [AIAction], session: Int) async throws -> LodoReply {
        var texts: [String] = []
        var writes: [(Write, String)] = []
        var insertable = true
        var elsewhere = false
        var suggestion: String?
        for action in actions {
            switch action {
            case .answer(let text):
                texts.append(text)
            case .askMemory(let q):
                let items = KeyboardExchange.retrieve(q, in: snapshot).map {
                    (uuid: $0.uuid, title: $0.title, summary: $0.summary, tags: $0.tags, excerpt: $0.excerpt)
                }
                if items.isEmpty {
                    texts.append(String(localized: "没有找到相关的记忆。"))
                    insertable = false
                } else {
                    texts.append(try await DeepSeekClient.askMemory(question: q, items: items).0)
                }
            case .create(let task):
                writes.append((.task(task), String(format: String(localized: "已加入任务「%@」"), task.title)))
            case .memorize(let text):
                writes.append((.memory(text: text, title: nil, automatic: false), String(localized: "已收藏到记忆")))
            case .autoMemorize(let title, let text):
                writes.append((.memory(text: text, title: title, automatic: true),
                               String(format: String(localized: "已记下「%@」"), title)))
            case .suggestMemorize(let text):
                // AI 主动建议的收藏不自己存(同主 app:用户点了才存);这里只提示怎么存。
                texts.append(text)
                suggestion = String(localized: "想收藏的话,接着问「收藏这条」。")
            case .rememberPreference:
                break // 偏好文件在主 app 的容器里,键盘写不到;不打扰用户
            default:
                elsewhere = true
            }
        }
        try checkStillCurrent(session)

        var notes: [String] = []
        var queued: [URL] = []
        var failure: String?
        for (write, note) in writes {
            do {
                switch write {
                case .task(let task): queued.append(try KeyboardExchange.queueTask(task))
                case .memory(let text, let title, let automatic):
                    queued.append(try KeyboardExchange.queueMemory(text: text, title: title, automatic: automatic))
                }
                notes.append(note)
            } catch {
                failure = String(format: String(localized: "有一项没存上:%@"), error.localizedDescription)
                break
            }
        }
        if elsewhere { notes.append(String(localized: "修改、删除、行程这类操作要打开 lodo 去做。")) }
        if !queued.isEmpty { notes.append(String(localized: "打开 lodo 后入库。")) }
        if let failure { notes.append(failure) }
        if let suggestion { notes.append(suggestion) }
        if texts.isEmpty {
            insertable = false
            texts.append(notes.isEmpty ? String(localized: "这个要打开 lodo 去做。") : notes.removeFirst())
        }
        let undo: (() -> Bool)? = queued.isEmpty ? nil : {
            queued.map(KeyboardExchange.unqueue).allSatisfy { $0 }
        }
        return LodoReply(text: texts.joined(separator: "\n\n"), insertable: insertable,
                         note: notes.isEmpty ? nil : notes.joined(separator: " "), undo: undo)
    }
}
