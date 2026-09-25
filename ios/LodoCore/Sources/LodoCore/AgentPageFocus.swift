import Foundation

/// 用户是从哪一页唤出 AI 助手的(底部「问问 AI」条)。只影响含糊指令的默认领域,
/// 不收窄也不放宽任何工具/能力开关;侧栏里的全局 AI 页不传,各领域优先级一致。
public enum AgentPageFocus: String, CaseIterable, Sendable {
    case overview, todo, memory, contact, health, travel, menu

    /// 页面名(和侧栏一致)。
    public var pageName: String {
        switch self {
        case .overview: return "总览"
        case .todo: return "任务"
        case .memory: return "记忆"
        case .contact: return "人脉"
        case .health: return "健康"
        case .travel: return "旅行"
        case .menu: return "菜单"
        }
    }

    /// 含糊指令默认指向的领域。
    var defaultDomain: String {
        switch self {
        case .overview: return "今天的待办与提醒"
        case .todo: return "待办任务"
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
