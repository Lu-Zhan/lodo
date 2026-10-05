package com.lodo.app.ai

/** 从哪一页唤出 AI(底部「问问 AI」),同 iOS AgentPageFocus:只影响含糊指令的默认领域。 */
enum class AgentPageFocus(val pageName: String, val defaultDomain: String) {
    OVERVIEW("总览", "今天的待办与提醒"),
    TODO("任务", "待办任务"),
    CALENDAR("日历", "时间安排(系统日历里的日程你读不到也改不了;要新建或调整安排时按待办任务处理)"),
    COUNTDOWN("倒数日", "倒数日(新建/修改/删除用 create_countdown 等操作,不要改成新建待办)"),
    MEMORY("记忆", "记忆库里收藏的内容"),
    CONTACT("人脉", "人脉/联系人"),
    ASSETS("资产", "资产台账:车子、房产、存款、投资这类资产(用 create_asset/update_asset)。收入、固定支出和信用卡在资产页里手动维护,你读不到也改不了——用户要记这些时,告诉他在资产页右上角「+」里添加"),
    HEALTH("健康", "健康数据(需要时先 read_health)"),
    TRAVEL("旅行", "旅行与行程(需要时先 read_trip)"),
    MENU("菜单", "菜单与点菜"),
    NEWS("新闻", "订阅的新闻与博客(需要时先 search_news)"),
}

data class AgentFocus(val page: AgentPageFocus, val subject: String? = null) {
    val promptBlock: String
        get() {
            val s = subject?.trim()?.takeIf { it.isNotEmpty() }
                ?: return "当前页面:用户是在「${page.pageName}」页唤出你的。没有说明领域的含糊指令(如\"加一个…\"\"改一下…\"\"第二天…\")默认指该页的内容:${page.defaultDomain}。" +
                    "用户明确提到其他领域(任务、记忆、旅行等)时照常处理,不要因为在这一页就拒绝、反问或改成这一页的事。"
            return "当前页面:用户是在「${page.pageName}」页的「$s」里唤出你的。" +
                "没有说明对象的含糊指令(如\"加一个…\"\"改一下…\"\"第二天…\")默认指的就是" +
                "「$s」这一个,查询和修改都**优先**落在它身上:${page.defaultDomain}。" +
                "用户明确提到别的对象或别的领域(任务、记忆、另一次旅行等)时照常处理," +
                "不要因为在这一页就拒绝、反问或改成这一页的事。"
        }
}
