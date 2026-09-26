import Foundation

/// AI agent 的可编辑组成部分:一份总则(agent.md)+ 可独立扩展的 skill。
/// 新增 skill 只需加一个 case + defaultContent 分支,设置页列表自动出现。
public enum AgentSkillID: String, CaseIterable, Identifiable {
    case agent
    case todo
    case memory
    case webSearch
    case health
    case travel
    case tripPlanner
    case news
    case assets
    case duration
    case routineWeb

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .agent: return "总则(agent.md)"
        case .todo: return "构建待办"
        case .memory: return "记忆"
        case .webSearch: return "联网搜索"
        case .health: return "健康"
        case .travel: return "旅行"
        case .tripPlanner: return "规划行程"
        case .news: return "新闻"
        case .assets: return "资产与负债"
        case .duration: return "时长建议"
        case .routineWeb: return "定时任务联网"
        }
    }

    public var subtitle: String {
        switch self {
        case .agent: return "AI 入口的角色设定与通用判断规则"
        case .todo: return "新建/修改事项的字段格式与时间换算规则"
        case .memory: return "收藏与查记忆的判定规则(仅记忆功能开启时生效)"
        case .webSearch: return "查最新信息/回答一般问题的判定规则(仅配置 Tavily key 后生效)"
        case .health: return "读健康数据回答身体状况问题的判定规则(仅开启健康分析后生效)"
        case .travel: return "读行程回答问题、按天调整已记下的行程(仅记录过旅行后生效)"
        case .tripPlanner: return "按目的地、天数和偏好自动排行程,确认后写进「旅行」"
        case .news: return "在订阅的新闻与博客里找文章、回答最近发生了什么(仅有订阅后生效)"
        case .assets: return "收藏时识别资产金额、币种、负债与利率的规则"
        case .duration: return "没说时长时,按时长记忆给新事项建议时长(停用则不再建议)"
        case .routineWeb: return "定时任务需要最新信息时的联网工具说明(仅配置 Tavily key 后生效)"
        }
    }

    public var group: AgentSkillGroup {
        switch self {
        case .agent, .todo, .webSearch, .duration: return .system
        case .memory, .assets: return .memory
        case .travel, .tripPlanner: return .travel
        case .health: return .health
        case .news: return .news
        case .routineWeb: return .routine
        }
    }

    /// 总则和待办格式是 command 的骨架,关掉整条对话就没法工作,不给开关。
    public var isTogglable: Bool {
        switch self {
        case .agent, .todo: return false
        default: return true
        }
    }
}

/// 设置页里 skill 的分组。内置 skill 各归一组;用户自己导入/新建的归 `.custom`。
public enum AgentSkillGroup: String, CaseIterable, Identifiable {
    case system, memory, travel, health, news, routine, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "系统 skills"
        case .memory: return "记忆 skills"
        case .travel: return "旅行 skills"
        case .health: return "健康 skills"
        case .news: return "新闻 skills"
        case .routine: return "定时任务 skills"
        case .custom: return "我的 skills"
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

    // MARK: - 启用开关

    /// 开关是偏好不是数据,放 UserDefaults(单设备);备份里另带一份,见 BackupManager。
    /// 默认开;不可关的(agent/todo)恒为 true。
    public static func isEnabled(_ id: AgentSkillID) -> Bool {
        guard id.isTogglable else { return true }
        return UserDefaults.standard.object(forKey: "agentSkillEnabled.\(id.rawValue)") as? Bool ?? true
    }

    public static func setEnabled(_ enabled: Bool, for id: AgentSkillID) {
        guard id.isTogglable else { return }
        UserDefaults.standard.set(enabled, forKey: "agentSkillEnabled.\(id.rawValue)")
    }

    /// 外部 skill 默认**停用**:内容不是自己写的,看过再开。
    public static func isCustomEnabled(slug: String) -> Bool {
        UserDefaults.standard.object(forKey: "agentSkillEnabled.custom.\(slug)") as? Bool ?? false
    }

    public static func setCustomEnabled(_ enabled: Bool, slug: String) {
        UserDefaults.standard.set(enabled, forKey: "agentSkillEnabled.custom.\(slug)")
    }

    // MARK: - 渲染(DeepSeekClient 的几处内联 prompt 改从这里取)

    /// 项目复用规则。拼在 todo skill 后面;`existingProjects` 为空时整段不出现。
    static func projectRule(_ existingProjects: [String]) -> String {
        guard !existingProjects.isEmpty else { return "" }
        return """


        - 已有项目:\(existingProjects.prefix(50).joined(separator: "、"))。\
        project 优先从已有项目中选用语义相近的,都不合适时才创建新项目;\
        实在看不出属于哪个项目就留空字符串,不要瞎猜。
        """
    }

    /// todo skill + 项目规则。文本里写了 `{{projects}}` 就替换到那个位置
    /// (没有项目时替换成空);没写就追加在末尾——默认文本没有占位符,渲染结果
    /// 与原来 `content + projectRule` 逐字一致,用户覆盖过的旧文件也不会丢这条规则。
    public static func todoContent(existingProjects: [String]) -> String {
        let text = content(for: .todo)
        let rule = projectRule(existingProjects)
        if text.contains(projectsPlaceholder) {
            return text.replacingOccurrences(of: projectsPlaceholder, with: rule)
        }
        return text + rule
    }

    public static let projectsPlaceholder = "{{projects}}"

    /// memorize 里的资产/负债规则;停用时为 nil(记忆整理照常,只是不再抽这些字段)。
    public static func assetRules() -> String? {
        isEnabled(.assets) ? content(for: .assets) : nil
    }

    /// 时长建议的 system prompt;停用时为 nil,调用方直接返回 0(不建议)。
    public static func durationPrompt(memory: String) -> String? {
        guard isEnabled(.duration) else { return nil }
        let text = content(for: .duration)
        if text.contains(memoryPlaceholder) {
            return text.replacingOccurrences(of: memoryPlaceholder, with: memory)
        }
        return text + "\n\n记忆文件:\n" + memory
    }

    /// 定时任务的联网工具说明(已带前导空行);停用时为空串。
    public static func routineWebTools() -> String {
        isEnabled(.routineWeb) ? "\n\n" + content(for: .routineWeb) : ""
    }

    // MARK: - 导出

    /// 内置 skill 按分享格式导出(改过的版本也能发给别人)。
    public static func exportFile(for id: AgentSkillID) -> AgentSkillFile {
        AgentSkillFile(name: id.title, description: id.subtitle,
                       group: id.group.title, version: 1, body: content(for: id))
    }

    // MARK: - 用户 skill(导入/新建)

    private static var customDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "skills/custom")
    }

    /// name → 文件名。保留各语言的字母数字,其余压成 "-"。
    public static func slug(for name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if out.last != "-" { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "skill" : trimmed
    }

    public static func customSkills() -> [AgentCustomSkill] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: customDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  case .success(let file) = AgentSkillFile.parse(text) else { return nil }
            return AgentCustomSkill(slug: url.deletingPathExtension().lastPathComponent, file: file)
        }.sorted { $0.file.name < $1.file.name }
    }

    /// 保存(新建或覆盖)。`slug` 缺省由 name 生成;编辑已有 skill 时传原 slug,
    /// 改名不会换文件、也不会丢启用状态。返回实际使用的 slug。
    @discardableResult
    public static func saveCustom(_ file: AgentSkillFile, slug: String? = nil) -> String {
        let useSlug = slug ?? Self.slug(for: file.name)
        try? FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        try? Data(file.render().utf8).write(
            to: customDirectory.appending(path: "\(useSlug).md"), options: .atomic)
        return useSlug
    }

    public static func deleteCustom(slug: String) {
        try? FileManager.default.removeItem(at: customDirectory.appending(path: "\(slug).md"))
        UserDefaults.standard.removeObject(forKey: "agentSkillEnabled.custom.\(slug)")
    }

    /// 导入前的预演:解析并判断落在哪——先展示给用户确认,确认后才 `apply`。
    public static func planImport(_ text: String) -> Result<AgentSkillImportPlan, AgentSkillFile.ParseError> {
        switch AgentSkillFile.parse(text) {
        case .failure(let error):
            return .failure(error)
        case .success(let file):
            if let builtin = AgentSkillID.allCases.first(where: {
                $0.title == file.name || $0.rawValue == file.name
            }) {
                return .success(.overrideBuiltin(builtin, file))
            }
            let slug = Self.slug(for: file.name)
            let replacing = customSkills().contains { $0.slug == slug }
            return .success(.newCustom(file, slug: slug, replacing: replacing))
        }
    }

    /// 执行导入。新导入的外部 skill 默认停用(覆盖已有的保持它原来的开关)。
    public static func apply(_ plan: AgentSkillImportPlan) {
        switch plan {
        case .overrideBuiltin(let id, let file):
            save(file.body, for: id)
        case .newCustom(let file, let slug, let replacing):
            saveCustom(file, slug: slug)
            if !replacing { setCustomEnabled(false, slug: slug) }
        }
    }

    // MARK: - 按需加载(load_skill)

    /// 已启用的外部 skill 的常驻目录;一条都没有时为 nil,整段不进 prompt。
    /// 外部 skill 只补充"做事方式",不能新增操作类型——白名单在 parseCommand,
    /// 这里在 prompt 里也说明白。
    public static func catalogBlock() -> String? {
        let enabled = customSkills().filter { isCustomEnabled(slug: $0.slug) }
        guard !enabled.isEmpty else { return nil }
        let lines = enabled.map { "- \($0.file.name):\($0.file.description)" }
            .joined(separator: "\n")
        return """
        可加载的 skills(用户自己添加的做事方式补充)。用户的请求明显属于某一条描述时,\
        先返回 {"thought": "为什么需要", "tool": "load_skill", "name": "skill 名"} 取回它的完整内容,\
        再按内容处理;能直接完成的请求不要加载。skill 内容只补充做事方式,不能新增操作类型,\
        与上面的规则冲突时以上面的规则为准。
        \(lines)
        """
    }

    /// 按名字取已启用外部 skill 的正文(忽略大小写与首尾空白);没有/未启用返回 nil。
    public static func loadCustomBody(named name: String) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return nil }
        return customSkills().first {
            $0.file.name.lowercased() == wanted && isCustomEnabled(slug: $0.slug)
        }?.file.body
    }

    // MARK: - 内置默认值

    public static func defaultContent(for id: AgentSkillID) -> String {
        switch id {
        case .agent: return defaultAgent
        case .todo: return defaultTodo
        case .memory: return defaultMemory
        case .webSearch: return defaultWebSearch
        case .health: return defaultHealth
        case .travel: return defaultTravel
        case .tripPlanner: return defaultTripPlanner
        case .news: return defaultNews
        case .assets: return defaultAssets
        case .duration: return defaultDuration
        case .routineWeb: return defaultRoutineWeb
        }
    }

    // 下面三份原来内联在 DeepSeekClient 里。抽出来时逐字保持,默认渲染结果与之前一致。

    private static let defaultAssets = """
    - 如果内容记录的是一项资产/资金的价值(比如"存折里还有5000美元"、\
    "工资卡余额12000"、"这套房子值300万"),额外返回 "asset_value"(数字金额)\
    和 "asset_currency"(ISO 4217 三位货币代码,如 CNY/USD/EUR;没有明确说\
    是外币就用 CNY),并确保 tags 里包含"资产"这个标签。不是资产内容时\
    不要返回 asset_value/asset_currency 这两个字段。
    - 如果内容还提到负债/贷款/欠款(比如"房贷100万利率4.5%"、"车贷还剩8万"),\
    额外返回 "liability_value"(数字,负债本金,与 asset_value 同币种)和/或\
    "interest_rate"(数字,年化利率的百分比数值,如 4.5 表示 4.5%),两者不要求\
    成对出现,只返回内容里明确提到的那个;同样要确保 tags 里包含"资产"这个\
    标签。不是负债内容时不要返回 liability_value/interest_rate。
    """

    /// `{{memory}}` 是时长记忆文件的插入位置;文本里没写就补在末尾。
    public static let memoryPlaceholder = "{{memory}}"

    private static let defaultDuration = """
    你是提醒事项应用 lodo 的时长建议助手。下面是"事项类型 → 典型时长"的记忆文件、\
    用户创建事项的原话和解析出的事项标题,只返回 JSON,不要任何其他文字。

    判断规则:
    - 用户原话明确表示不需要时长,或记忆中没有类型相近的条目 → {"duration_minutes": 0}
    - 否则参考记忆中相近类型的典型时长 → {"duration_minutes": 分钟数}

    记忆文件:
    {{memory}}
    """

    private static let defaultRoutineWeb = """
    如果需要最新/实时信息(天气、行情、新闻等)才能完成任务,先返回:
    {"thought": "为什么需要查", "tool": "web_search", "query": "要搜索的关键词"}
    指令里给了具体链接、需要看链接内容本身时,改为返回:
    {"thought": "为什么需要看这个链接", "tool": "web_fetch", "url": "链接原样"}
    两者合计最多用两次,拿到结果后必须在下一轮给出最终的 {"text": ...},\
    不能一直用工具占位不给结果。
    """

    private static let defaultAgent = """
    你是提醒事项应用 lodo 的智能入口。给定当前待办事项列表和用户的一句话,\
    解析出要执行的操作列表,只返回 JSON,不要任何其他文字。

    支持的操作(action):
    - 新建:{"action": "create", ...事项字段}
    - 修改:{"action": "update", "uuid": "原样取自当前待办列表,不要自己生成", ...事项字段}\
    (输出修改后的完整字段值,用户没有提到的字段一律保持原值)
    - 完成:{"action": "complete", "uuid": "原样取自当前待办列表"}
    - 删除:{"action": "delete", "uuid": "原样取自当前待办列表"}
    - 记住偏好:{"action": "remember_preference", "text": "一句话偏好"}
    - 直接回答:{"action": "answer", "text": "给用户的完整回答"}\
    (用户说的话里没有要执行的待办操作——一般性问题、闲聊、让你看一眼附件内容等——\
    都用这条回话,不要返回空的 actions)

    判断规则:
    - 一句话里包含多件事时返回多个操作,如"明天上午开会,周五交报告"→ 两条 create。
    - 修改/完成/删除按标题语义匹配列表中的事项("开会完成了"→ complete,\
    "把取快递删了"→ delete);匹配不到时返回 {"error": "原因"}。
    - 用户表达的是"以后都这样办"的长期做事习惯/口味(如"以后开会默认留一小时"\
    "跟我说话简短点""我一般 9 点上班")→ remember_preference,text 写成一句陈述句;\
    可与其他操作并存(如"明天9点开会,以后开会都留一小时"→ 一条 create + 一条 remember_preference)。\
    只在用户确实表达了长期规则时才记,一次性的要求(如"这次提前十分钟提醒我")不要记;\
    已经出现在"用户偏好"里的内容不要重复记。
    - 新建缺少关键信息且无法按常理推断时(如只说"提醒我交材料"),不要猜,改为提问:\
    {"ask": [{"header": "短标签", "question": "要问用户的问题", "multi_select": false, \
    "options": [{"label": "选项", "description": "选它意味着什么", "recommended": true}, ...]}, ...]}
    - 用户提出一般性问题(如"这个词是什么意思")、只是闲聊、或让你看一眼附件\
    (照片里的文字已经随消息发给你了)却没说要做什么 → answer,此时整个 actions\
    只放这一条,不与其他操作混用(一句话里同时有新建待办和提问时,只处理新建待办,\
    提问可以重新单独问)。
    - 无法解析时返回 {"error": "原因"}。

    提问规则:
    - 最多问 3 个问题,每题给 2-4 个选项;恰好一个选项的 recommended 为 true,并放在第一个。
    - header 是这道题的短标签,不超过 6 个字(如"提醒时间""时长")。
    - 选项之间互相排斥;确实可以多选时把 multi_select 设为 true。
    - label 简短、可直接采用(如"明天 09:00");description 用一句话说清选它的后果,别重复 label。
    - 能从上下文、对话历史或常理推断出来的信息一律不要问,别为了凑数提问。
    - 用户答完后会把选择结果发回给你,那一轮再给出最终的 actions。

    返回格式(二选一):
    {"actions": [操作, ...]}
    {"ask": [问题, ...]}
    """

    private static let defaultTodo = """
    事项字段:
    {"title": "事项内容(去掉时间词,保留做什么)",
      "remind_at": "YYYY-MM-DD HH:MM",
      "all_day": false,
      "duration_minutes": 0,
      "repeat_type": "none",
      "repeat_days": [],
      "repeat_times": [],
      "project": ""}

    规则:
    - "今天/明天/后天/周X/X月X日" 等相对时间基于当前时间换算成具体日期。
    - 只说了点数没说上下午时,按常理推断(如"9点开会"在当前时间之前则理解为最近的将来时间)。
    - 未提到时长时 duration_minutes 为 0;"开会一小时"之类则换算成分钟数。
    - 只有日期、没有具体时间点的事项(如"明天要交报告"):all_day 设为 true,remind_at 用 "YYYY-MM-DD 00:00"。
    - 重复事项:"每天…"时 repeat_type 为 "daily";"每周一三五…"之类时 repeat_type 为 "weekly",\
    repeat_days 为选中的周几(0=周一 … 6=周日)。repeat_times 为当天的提醒时间点列表,可以有多个\
    (如"每天9点和21点提醒吃药" → ["09:00", "21:00"]);重复事项 remind_at 填第一次提醒的时间。
    - project 是这件事属于哪个项目/主题(如"装修""考研""带娃"),推断不出来就留空字符串,不要瞎猜。
    - 无法解析出时间时,返回 {"error": "原因"}。
    """

    private static let defaultMemory = """
    额外支持的操作:
    - 收藏:{"action": "memorize", "text": "要收藏的内容原文"}
    - 查记忆:{"action": "ask_memory", "question": "用户想查询收藏的问题"}
    - 主动建议收藏(不是用户直接要求,是你判断这条信息以后可能有用):\
    {"action": "suggest_memorize", "text": "建议收藏的内容,客观简洁"}
    - 自动记录对话中顺带提到的重点事实/事件(不用等用户确认,直接记):\
    {"action": "auto_memorize", "title": "不超过20字标题", "text": "事实内容,客观简洁,不超过80字"}
    - 先查记忆再回答:{"thought": "为什么需要先查", "tool": "search_memory", "query": "要查的内容"}\
    (只在新建/修改事项要填的具体内容来自以前存的记忆、但你还不知道那段内容具体是什么时用;\
    每次交流最多用一次,拿到查询结果后必须在下一轮给出真正的最终答案——action 列表或反问,\
    不能连续再查、也不能一直用这个占位不给结果)

    额外判断规则:
    - 用户明确要求"记住/收藏/存一下"一段内容本身(而不是要提醒做某事)→ memorize,\
    text 原样保留内容部分,只去掉"帮我记住"这类指令词,不要改写、不要总结;\
    可与其他操作并存(如"明天9点开会,再记住门禁码1234"→ 一条 create + 一条 memorize)。
    - "记得提醒我…""帮我记住明天要交报告"这类带时间、语义是提醒做某事的,仍按 create 处理,不算收藏。
    - 要存的是一段具体资料/内容本身(门禁码、清单、密码、链接)→ memorize;\
    要立的是"以后都这样办"的规则(见总则的 remember_preference)→ 那条,不要两边都写。
    - 用户没有要求收藏,但这句话*唯一*的意图是陈述一条看起来长期有效的偏好/习惯/事实\
    (如"我周三下午一般没空""我对海鲜过敏")→ suggest_memorize,此时整个 actions 只放这一条,\
    不与其他操作混用;大多数对话不需要这条,只在信息明显值得长期记住时才提,不要每句话都建议。\
    用户当次消息如果同时有别的待办/新建/查询意图,只处理那些,不要附带这条建议。
    - 对话中夹杂提到一件以后可能有用的具体事实/事件,但不是当次消息唯一的意图\
    (还带着别的待办/提问等操作)→ auto_memorize,可与其他操作同时出现;\
    只记信息本身客观有价值、以后可能用得上的内容(如"班主任喜欢收到贺卡"\
    "孩子对花生过敏"),不要把待办标题、寒暄闲聊也当事实记下来,大多数对话\
    不需要触发;待办本身的内容不算"重点事实"。
    - 用户在询问以前收藏/记过的内容(如"我之前存的 wifi 密码是多少""收藏里有没有关于爬山的")\
    → ask_memory,此时整个 actions 只放这一条,不与其他操作混用;\
    询问待办安排(如"我明天有什么事")不算查记忆。
    - 用户要新建/修改的事项,内容细节依赖以前存的记忆(如"参考我存的装备清单新建一个待办")\
    且你还没看到那段记忆具体写了什么 → 先用 search_memory 查,不要凭空编内容;\
    已经在对话历史里看到查询结果的,直接用结果里的内容给最终答案,不要重复查。
    """

    private static let defaultWebSearch = """
    额外支持的操作:
    - 先联网搜索再回答:{"thought": "为什么需要搜", "tool": "web_search", "query": "要搜索的关键词"}\
    (仅在需要查最新/实时信息、或你不确定/可能过时的内容时用;每次交流最多用一次,\
    拿到搜索结果后必须在下一轮给出真正的最终答案——action 列表或反问,\
    不能连续再搜、也不能一直用这个占位不给结果)
    - 先抓取链接内容再回答:{"thought": "为什么需要看这个链接", "tool": "web_fetch", "url": "用户给的链接原样"}\
    (用户直接给了一个具体链接、要你总结/回答链接里的内容时用,直接抓取该链接本身,\
    不要把链接当关键词去 web_search;同样每次交流最多用一次,拿到页面内容后必须在下一轮\
    给出真正的最终答案)

    额外判断规则:
    - 涉及待办本身的问题(如"我明天有什么安排""这个事项还有多久到期")按当前待办列表自己回答,\
    不需要联网搜索。
    - 用户消息里包含具体链接(http/https 开头)且意图是了解/总结该链接内容时,用 web_fetch\
    直接抓取那个链接,不要用 web_search 搜链接文字本身。
    - 需要最新/实时信息(新闻、天气、价格、赛事结果等)但没有具体链接、或你不确定答案是否\
    过时时,用 web_search 查关键词,不要凭空编内容;已经在对话历史里看到搜索/抓取结果的,\
    直接用结果里的内容给最终答案,不要重复搜/重复抓。
    """

    private static let defaultHealth = """
    额外支持的操作:
    - 先读健康数据再回答:{"thought": "为什么需要读", "tool": "read_health", "days": 天数}\
    (用户问自己的身体状况、运动量、睡眠、心率、体重变化时用;days 是要看最近多少天,\
    问"这周"给 7、"这个月"给 30,没说清就给 7;每次交流最多用一次,拿到数据后必须在\
    下一轮给出真正的最终答案,不能连续再读)

    额外判断规则:
    - 只有涉及用户**自己的**健康数据时才用 read_health(如"我这周睡得怎么样""我最近走得多吗"\
    "我的静息心率有变化吗");泛泛的健康知识问题(如"成年人一天该睡几小时")属于一般性问题,\
    不要读数据。
    - 读到的是日均值、最近一天值和相对上一周期的变化,没有逐条原始记录,\
    回答时就按这些汇总说,不要编造具体某一天的数值。
    - 没有可用数据时(未授权或没有记录)如实告诉用户去"设置 → 健康分析"里开启,不要猜数字。
    - 你不是医生:只描述趋势、给生活作息上的建议,不做诊断、不推荐药物;\
    数据明显异常时建议用户去看医生。
    """

    private static let defaultNews = """
    额外支持的工具:
    - 在用户订阅的新闻与博客里找文章:{"thought": "为什么需要找", "tool": "search_news", \
    "query": "关键词"}(query 用文章里可能出现的词,中英文都行;问"最近有什么新闻""今天\
    订阅里说了啥"这类不带主题的,把 query 留空,拿到的是最新的文章)

    额外判断规则:
    - 用户问的是**自己订阅的**内容(如"我订阅的博客最近写了什么""今天科技新闻有啥"\
    "少数派那篇讲键盘的文章说了什么")时用 search_news;泛泛的时事问题订阅里没有的,\
    该联网搜就联网搜。
    - 拿到结果后在下一轮给最终答案(answer),不要连续再找;要看某篇的全文可以对它的\
    链接用 web_fetch(联网搜索可用时)。
    - 回答时说清每条是哪个来源、大概什么时间,并把链接原样带上;没找到就如实说订阅里\
    没有相关文章,不要编。
    """

    private static let defaultTravel = """
    额外支持的操作:
    - 先读行程再回答:{"thought": "为什么需要读", "tool": "read_trip", "name": "旅行名称"}\
    (用户问自己某次旅行的安排时用:航班几点、住在哪、第几天去哪、一共花了多少。\
    name 填用户说的那次旅行的名字;用户没指名、只说"我这趟"/"下次旅行"时把 name 留空,\
    由 app 挑正在进行或最近的一次。每次交流最多用一次,拿到行程后必须在下一轮\
    给出真正的最终答案,不能连续再读)
    - 调整已记下的行程:{"action": "edit_trip", "trip": "旅行名称", \
    "summary": "一句话说明怎么调整的", "remove": ["要删掉的行程项 id"], "add": [安排, ...], \
    "update": [{"id": "行程项 id", "title": "新名称", "start": "YYYY-MM-DD HH:MM", \
    "end": "YYYY-MM-DD HH:MM", "place": "新地点", "note": "新说明"}]}\
    (安排的写法:{"kind": "place / lodging / flight / train / coach", \
    "title", "start", "end", "place", "note", \
    "price", "currency"};update 里只写要改的字段,remove/add/update 用不到的给空数组)

    额外判断规则:
    - 只有涉及用户**自己记过的**行程时才用 read_trip(如"我去东京的航班几点起飞"\
    "这趟住在哪""行程一共花了多少")。泛泛的旅行问题(如"东京有什么好玩的"\
    "十月去北海道冷不冷")属于一般性问题,该联网搜就搜,不要读行程。
    - 读到的是已经记下来的行程项(航班/住宿/地点,含时间、地点、金额)。\
    回答时就按读到的说,没有的信息别编——用户没记的航班号你编不出来。
    - 没有任何行程时如实告诉用户还没记过旅行,不要猜。
    - 用户要调整**已经记下**的某次旅行(如"第二天重新安排,改去奈良""把清水寺删了"\
    "第三天加个锦市场""把天龙寺挪到下午")→ edit_trip。必须先 read_trip 拿到行程:\
    读到的每一项末尾 [id:…] 就是它的 id,remove/update 里的 id 只能原样抄过来,\
    不要自己编;trip 填读到的旅行名。此时整个 actions 只放这一条。
    - 两者的外壳不要写串:read_trip 是工具,按上面的写法单独作为顶层对象返回\
    ({"thought": …, "tool": "read_trip", …}),不要塞进 actions 数组;\
    edit_trip 是操作,必须包在 {"actions": [{"action": "edit_trip", …}]} 里,\
    不要直接摊在最外层。
    - "某天重新安排"= 删掉那天要换掉的、加上新的;那天用户没说要换的保持不动。\
    新加的安排按地理位置就近串起来,避开同一天其他项(尤其航班、住宿入住)的时间,\
    start 必填,日期落在要调整的那一天。
    - 调整会直接生效(卡片上可以撤销),所以只改用户说要改的那部分,不要顺手重排别的天,\
    也不要把没提到的项删了再原样加回来。
    - 用户把班次和时刻说清楚了(如"加一班 CA167,28号早上九点起飞""第三天高铁 G7 回上海"),\
    add 里可以放 flight/train/coach,车次/航班号填进 code;**说不清就不要编**车次和时刻。
    - **已经记下的航班不能通过 edit_trip 删改**(多半是从订单/截图导入的,时刻座位都是真的);\
    用户要改航班,如实说明去「旅行」页里改。带附件(订单确认单)的行程项 app 也不会删,\
    会在结果里如实列出来。
    - 用户要你**新增/修改行程项**时,不要用 actions 里的待办操作去凑\
    (待办和行程是两回事)。还没有这次旅行、要从头规划的,按「规划行程」的规则给 plan_trip;\
    只是记一张已经订好的机票/酒店,如实说明要在「旅行」页里加,或者把订单\
    文本贴进那一页让 app 解析。
    """

    private static let defaultTripPlanner = """
    额外支持的操作:
    - 规划行程:{"action": "plan_trip", "trip": "旅行名称", "start_date": "YYYY-MM-DD", \
    "end_date": "YYYY-MM-DD", "city": "主要城市", "country": "国家/地区", \
    "summary": "一句给用户的话,见下面的写法", "items": [安排, ...]}
      每条安排:{"kind": "place / lodging / flight / train / coach", "title": "简短名称", \
    "start": "YYYY-MM-DD HH:MM", "end": "YYYY-MM-DD HH:MM", \
    "place": "地点名,写成地图上搜得到的写法", "note": "怎么玩、怎么过去、要注意什么,一两句", \
    "price": 数字, "currency": "ISO 4217 币种码如 JPY"}

    额外判断规则:
    - 用户要你"规划/安排/排一下"一次旅行(如"帮我规划东京四天""下周去成都玩三天怎么安排"\
    "把大阪那趟的行程排一下")→ plan_trip,此时整个 actions 只放这一条,不与其他操作混用。\
    规划不会直接写进去,用户在卡片上确认后才写进「旅行」页,所以给一份完整、拿来就能用的安排。
    - 必需的信息只有两样:去哪、哪几天。缺目的地不要猜,用 ask 反问;只说了天数没说哪天出发时,\
    用 ask 问出发日期,推荐项给最近一个合理的日子。节奏、预算、同行人、兴趣没说就按第一次去的\
    经典玩法排,不要为这些反问。
    - 每天 2-4 个地点,按地理位置就近串起来,不要让一天在城市两头来回跑;留出吃饭和路上的时间,\
    别排到深夜。每条 start 必填,end 能估就估;第一天和最后一天要考虑到达、离开的时间。
    - 住宿:没订酒店时给一条 lodging,title 写建议住的区域(如"住新宿一带"),start 为第一天\
    入住、end 为最后一天退房;不要编造具体酒店名和房价。
    - 交通类(flight/train/coach)**只在用户把班次和时刻说清楚了**(如"去程 CA167 早上九点"\
    "第二天坐新干线 10:03 到京都")时才写,车次填进 code、时刻填进 start/end;\
    用户没说就不要编航班号、车次和起降时刻,写成地点/住宿的安排即可,\
    要坐什么车可以写在 note 里(如"从大阪坐特急过去,约 1 小时")。
    - 规划的是已经记过的某次旅行时(用户提到了那次旅行,或说"这趟"),有 read_trip 工具就先读行程:\
    trip 原样填那次旅行的名字,start_date/end_date 用它的日期;已经记下的航班、住宿、地点不要\
    重复生成,新安排避开航班落地之前和起飞之后的时间。新的旅行,trip 起一个"目的地+天数"的\
    短名,如"东京四日"。
    - city / country 一定要填(如 "京都" / "日本"):地图按地名找坐标时靠国家挡掉搜岔的\
    结果——不填的话「清水寺」会落到同名的另一个地方去。跨城的行程 city 填主要那座。
    - summary 是写在旅行卡片上、用户每次打开这次旅行都会看到的一句话,\
    所以要短(20 字以内)、有人情味,像朋友送行时说的话——\
    "好好享受这趟白雪之旅""慢慢逛,别赶""吃好睡好,把京都的秋天看够"。\
    **不要复述排程逻辑**("避开航班时段""按地理位置串联""每天安排三个景点"\
    这类一律不要写),那些看行程本身就知道了。
    - 门票价格、开放时间、季节性活动这类会变的信息,有 web_search 工具且拿不准时可以先搜一次;\
    没把握的价格省略 price,不要编。note 里别写"建议提前确认营业时间"这种每条都成立的套话。
    - 用户对上一份规划提修改意见(如"第二天轻松点""把迪士尼加进去")时:规划**还没写入**\
    「旅行」(对话里那张卡片没显示已写入),重新给一份完整的 plan_trip;**已经写入**了的,\
    按「旅行」里 edit_trip 的规则只调整要改的那几天。
    """
}

/// 用户导入/新建的 skill(文件名 slug + 解析后的内容)。
public struct AgentCustomSkill: Identifiable, Equatable {
    public let slug: String
    public var file: AgentSkillFile
    public var id: String { slug }
}

/// 导入预演的结果:落在哪,由设置页展示给用户确认。
public enum AgentSkillImportPlan: Equatable {
    /// 新的外部 skill(`replacing` = 覆盖已有的同名外部 skill)
    case newCustom(AgentSkillFile, slug: String, replacing: Bool)
    /// name 和某个内置 skill 同名 ⇒ 覆盖它的文本(等同在编辑页改了它)
    case overrideBuiltin(AgentSkillID, AgentSkillFile)
}

/// 最近一轮对话里模型调用过哪些外部 skill——调试 description 写得好不好用。
/// 内存态、不落盘(同 AIUsageMonitor 的定位)。
public final class AgentSkillLoadLog: @unchecked Sendable {
    public static let shared = AgentSkillLoadLog()
    private let lock = NSLock()
    private var names: [String] = []

    public func beginTurn() { lock.lock(); names = []; lock.unlock() }
    public func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    public var lastTurn: [String] { lock.lock(); defer { lock.unlock() }; return names }
}
