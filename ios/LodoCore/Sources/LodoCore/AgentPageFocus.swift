import Foundation

/// 用户是从哪一页唤出 AI 助手的(底部「问问 AI」条)。只影响含糊指令的默认领域,
/// 不收窄也不放宽任何工具/能力开关;侧栏里的全局 AI 页不传,各领域优先级一致。
public enum AgentPageFocus: String, CaseIterable, Sendable {
    case overview, todo, calendar, memory, contact, health, travel, menu

    /// 页面名(和侧栏一致)。
    public var pageName: String {
        switch self {
        case .overview: return "总览"
        case .todo: return "任务"
        case .calendar: return "日历"
        case .memory: return "记忆"
        case .contact: return "人脉"
        case .health: return "健康"
        case .travel: return "旅行"
        case .menu: return "菜单"
        }
    }

    /// 含糊指令默认指向的领域。
    public var defaultDomain: String {
        switch self {
        case .overview: return "今天的待办与提醒"
        case .todo: return "待办任务"
        case .calendar: return "时间安排(系统日历里的日程你读不到也改不了;要新建或调整安排时按待办任务处理)"
        case .memory: return "记忆库里收藏的内容"
        case .contact: return "人脉/联系人"
        case .health: return "健康数据(需要时先 read_health)"
        case .travel: return "旅行与行程(需要时先 read_trip)"
        case .menu: return "菜单与点菜"
        }
    }

    /// 拼进 command 的 system prompt。
    public var promptBlock: String {
        """
        当前页面:用户是在「\(pageName)」页唤出你的。没有说明领域的含糊指令(如"加一个…""改一下…""第二天…")默认指该页的内容:\(defaultDomain)。\
        用户明确提到其他领域(任务、记忆、旅行等)时照常处理,不要因为在这一页就拒绝、反问或改成这一页的事。
        """
    }
}

/// 唤出 AI 的那个位置:哪一页 +(可选)页面里当前打开的那个具体对象。
/// 页面本身仍是 `AgentPageFocus`,`subject` 是"这一页现在正看着哪一个"——
/// 目前只有旅行详情页会给(那次旅行的名字),含糊指令默认就指它。
///
/// 为什么不做成 `AgentPageFocus` 的关联值:那个枚举还要当 `CaseIterable` 用
/// (单测遍历全部页面、prompt 块逐个核对),带关联值就没法逐个列举了。
public struct AgentFocus: Equatable, Sendable {
    public let page: AgentPageFocus
    /// 页面里当前打开的那个对象的名字,如某次旅行的名字。nil = 整页。
    public let subject: String?

    public init(page: AgentPageFocus, subject: String? = nil) {
        self.page = page
        let trimmed = subject?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subject = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public static let overview = AgentFocus(page: .overview)
    public static let todo = AgentFocus(page: .todo)
    public static let calendar = AgentFocus(page: .calendar)
    public static let memory = AgentFocus(page: .memory)
    public static let contact = AgentFocus(page: .contact)
    public static let health = AgentFocus(page: .health)
    public static let travel = AgentFocus(page: .travel)
    public static let menu = AgentFocus(page: .menu)

    /// 旅行详情页:带上这次旅行的名字。名字为空(还没命名)时退回整页。
    public static func travel(trip: String) -> AgentFocus {
        AgentFocus(page: .travel, subject: trip)
    }

    /// 拼进 command 的 system prompt。没有 subject 时就是页面那段原文。
    public var promptBlock: String {
        guard let subject else { return page.promptBlock }
        return """
        当前页面:用户是在「\(page.pageName)」页的「\(subject)」里唤出你的。\
        没有说明对象的含糊指令(如"加一个…""改一下…""第二天…")默认指的就是\
        「\(subject)」这一个,查询和修改都**优先**落在它身上:\(page.defaultDomain)。\
        用户明确提到别的对象或别的领域(任务、记忆、另一次旅行等)时照常处理,\
        不要因为在这一页就拒绝、反问或改成这一页的事。
        """
    }
}
