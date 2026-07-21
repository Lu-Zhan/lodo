import Foundation

/// AI agent 的可编辑组成部分:一份总则(agent.md)+ 可独立扩展的 skill。
/// 新增 skill 只需加一个 case + defaultContent 分支,设置页列表自动出现。
public enum AgentSkillID: String, CaseIterable, Identifiable {
    case agent
    case todo
    case memory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .agent: return "总则(agent.md)"
        case .todo: return "构建待办"
        case .memory: return "记忆"
        }
    }

    public var subtitle: String {
        switch self {
        case .agent: return "AI 入口的角色设定与通用判断规则"
        case .todo: return "新建/修改事项的字段格式与时间换算规则"
        case .memory: return "收藏与查记忆的判定规则(仅记忆功能开启时生效)"
        }
    }
}

/// agent.md 与各 skill 的存取:内置默认文本(编译进代码)+ 可覆盖的本地文件。
/// 覆盖文件存在则优先生效,编辑/重置就是读写这个本地文件,不引入数据库表。
/// DeepSeekClient 直接拼接 content(for:) 到实际发给 AI 的 system prompt。
public enum AgentSkillStore {
    private static func overrideURL(for id: AgentSkillID) -> URL {
        URL.applicationSupportDirectory.appending(path: "skills/\(id.rawValue).md")
    }

    /// 覆盖文件存在则优先,否则回退内置默认值。
    public static func content(for id: AgentSkillID) -> String {
        guard let text = try? String(contentsOf: overrideURL(for: id), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultContent(for: id)
        }
        return text
    }

    public static func isCustomized(_ id: AgentSkillID) -> Bool {
        FileManager.default.fileExists(atPath: overrideURL(for: id).path)
    }

    /// 保存编辑后的内容(设置页用);空内容等同重置。
    public static func save(_ text: String, for id: AgentSkillID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset(id)
            return
        }
        let url = overrideURL(for: id)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// 删除覆盖文件,恢复内置默认值。
    public static func reset(_ id: AgentSkillID) {
        try? FileManager.default.removeItem(at: overrideURL(for: id))
    }

    // MARK: - 内置默认值

    public static func defaultContent(for id: AgentSkillID) -> String {
        switch id {
        case .agent: return defaultAgent
        case .todo: return defaultTodo
        case .memory: return defaultMemory
        }
    }

    private static let defaultAgent = """
    你是提醒事项应用 lodo 的智能入口。给定当前待办事项列表和用户的一句话,\
    解析出要执行的操作列表,只返回 JSON,不要任何其他文字。

    支持的操作(action):
    - 新建:{"action": "create", ...事项字段}
    - 修改:{"action": "update", "uuid": "原样取自当前待办列表,不要自己生成", ...事项字段}\
    (输出修改后的完整字段值,用户没有提到的字段一律保持原值)
    - 完成:{"action": "complete", "uuid": "原样取自当前待办列表"}
    - 删除:{"action": "delete", "uuid": "原样取自当前待办列表"}

    判断规则:
    - 一句话里包含多件事时返回多个操作,如"明天上午开会,周五交报告"→ 两条 create。
    - 修改/完成/删除按标题语义匹配列表中的事项("开会完成了"→ complete,\
    "把取快递删了"→ delete);匹配不到时返回 {"error": "原因"}。
    - 新建缺少关键时间信息且无法按常理推断时(如只说"提醒我交材料"),不要猜,\
    改为反问:{"question": "要问用户的问题", "options": ["候选补充1", "候选补充2", "候选补充3"]},\
    options 给 2-3 个具体可直接采用的补充(如"明天 09:00")。
    - 无法解析时返回 {"error": "原因"}。

    返回格式(二选一):
    {"actions": [操作, ...]}
    {"question": "...", "options": ["...", "..."]}
    """

    private static let defaultTodo = """
    事项字段:
    {"title": "事项内容(去掉时间词,保留做什么)",
      "remind_at": "YYYY-MM-DD HH:MM",
      "all_day": false,
      "duration_minutes": 0,
      "repeat_type": "none",
      "repeat_days": [],
      "repeat_times": []}

    规则:
    - "今天/明天/后天/周X/X月X日" 等相对时间基于当前时间换算成具体日期。
    - 只说了点数没说上下午时,按常理推断(如"9点开会"在当前时间之前则理解为最近的将来时间)。
    - 未提到时长时 duration_minutes 为 0;"开会一小时"之类则换算成分钟数。
    - 只有日期、没有具体时间点的事项(如"明天要交报告"):all_day 设为 true,remind_at 用 "YYYY-MM-DD 00:00"。
    - 重复事项:"每天…"时 repeat_type 为 "daily";"每周一三五…"之类时 repeat_type 为 "weekly",\
    repeat_days 为选中的周几(0=周一 … 6=周日)。repeat_times 为当天的提醒时间点列表,可以有多个\
    (如"每天9点和21点提醒吃药" → ["09:00", "21:00"]);重复事项 remind_at 填第一次提醒的时间。
    - 无法解析出时间时,返回 {"error": "原因"}。
    """

    private static let defaultMemory = """
    额外支持的操作:
    - 收藏:{"action": "memorize", "text": "要收藏的内容原文"}
    - 查记忆:{"action": "ask_memory", "question": "用户想查询收藏的问题"}
    - 先查记忆再回答:{"thought": "为什么需要先查", "tool": "search_memory", "query": "要查的内容"}\
    (只在新建/修改事项要填的具体内容来自以前存的记忆、但你还不知道那段内容具体是什么时用;\
    每次交流最多用一次,拿到查询结果后必须在下一轮给出真正的最终答案——action 列表或反问,\
    不能连续再查、也不能一直用这个占位不给结果)

    额外判断规则:
    - 用户明确要求"记住/收藏/存一下"一段内容本身(而不是要提醒做某事)→ memorize,\
    text 原样保留内容部分,只去掉"帮我记住"这类指令词,不要改写、不要总结;\
    可与其他操作并存(如"明天9点开会,再记住门禁码1234"→ 一条 create + 一条 memorize)。
    - "记得提醒我…""帮我记住明天要交报告"这类带时间、语义是提醒做某事的,仍按 create 处理,不算收藏。
    - 用户在询问以前收藏/记过的内容(如"我之前存的 wifi 密码是多少""收藏里有没有关于爬山的")\
    → ask_memory,此时整个 actions 只放这一条,不与其他操作混用;\
    询问待办安排(如"我明天有什么事")不算查记忆。
    - 用户要新建/修改的事项,内容细节依赖以前存的记忆(如"参考我存的装备清单新建一个待办")\
    且你还没看到那段记忆具体写了什么 → 先用 search_memory 查,不要凭空编内容;\
    已经在对话历史里看到查询结果的,直接用结果里的内容给最终答案,不要重复查。
    """
}
