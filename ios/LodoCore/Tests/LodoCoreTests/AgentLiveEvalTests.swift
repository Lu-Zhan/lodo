import XCTest
@testable import LodoCore

/// AI 助手(`command`)端到端评测:**真发请求**给当前服务商(内置 key),逐个场景检查
/// 模型给出的动作/工具调用是否符合协议、字段是否对得上。
///
/// - 默认跳过,不影响离线的 `swift test`。手动跑:
///   `LODO_LIVE_AI=1 LODO_LIVE_AI_LOG=/tmp/agent-eval.log swift test --filter AgentLiveEvalTests`
/// - ReAct 循环照抄 app 的 `AgentHostView.route()`:最多 3 轮,工具调用由这里用固定的
///   假数据作答(记忆、联网、健康、行程、订阅文章、外部 skill),历史条目的写法和 app 逐字一致,
///   这样测的就是真实 prompt + 真实解析 + 真实循环,只把"执行工具"换成桩。
/// - 写操作不落库(落库在 app 层,另有离线单测),这里只断言模型给出的结构。
/// - 模型有随机性:断言只卡"必须这样才算对"的部分(动作类型、目标 id、关键字段),
///   不卡措辞。
final class AgentLiveEvalTests: XCTestCase {

    // MARK: - 夹具

    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date()) }
    private func day(_ offset: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: offset, hour: hour, minute: minute), to: today)!
    }

    private let milkID = "11111111-1111-1111-1111-111111111111"
    private let rentID = "22222222-2222-2222-2222-222222222222"
    private let reportID = "33333333-3333-3333-3333-333333333333"

    private var tasks: [(uuid: String, task: ParsedTask)] {
        [
            (milkID, ParsedTask(title: "买牛奶", remindAt: day(1, 18), allDay: false,
                                repeatType: .none, repeatDays: [], repeatTimes: [])),
            (rentID, ParsedTask(title: "交房租", remindAt: day(2, 10), allDay: false,
                                repeatType: .none, repeatDays: [], repeatTimes: [])),
            (reportID, ParsedTask(title: "写周报", remindAt: day(4, 16), allDay: false,
                                  repeatType: .weekly, repeatDays: [4], repeatTimes: ["16:00"],
                                  project: "工作")),
        ]
    }

    private let anniversaryID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private var countdowns: [CountdownEntry] {
        [CountdownEntry(id: anniversaryID, title: "结婚纪念日",
                        start: calendar.date(byAdding: .day, value: -399, to: today)!)]
    }

    private let depositID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private var assets: [AssetEntry] {
        [AssetEntry(id: depositID, title: "招商银行定期", category: "存款", value: 50_000,
                    currency: "CNY", liability: nil, interestRate: 1.8,
                    updatedAt: day(-100))]
    }

    private let sspaiID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private var feeds: [FeedEntry] {
        [FeedEntry(id: sspaiID, title: "少数派", url: "https://sspai.com/feed", kind: .news,
                   enabled: true)]
    }

    private let flightID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    private let sensojiID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private let skytreeID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    private let hotelID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private var tripDays: [Date] { (10...13).map { day($0) } }

    /// read_trip 的桩:用 app 同一个 `TravelPlan.promptSummary` 拼(includeIDs 同 AI 助手路径)。
    private var tripObservation: String {
        let entries = [
            TravelEntry(id: flightID, kind: .flight, title: "MU523 上海→东京",
                        start: day(10, 9, 30), end: day(10, 13, 20),
                        placeName: "成田机场", originName: "浦东机场", code: "MU523"),
            TravelEntry(id: hotelID, kind: .lodging, title: "新宿王子酒店",
                        start: day(10, 15), end: day(13, 11), placeName: "新宿"),
            TravelEntry(id: sensojiID, kind: .place, title: "浅草寺",
                        start: day(11, 9), end: day(11, 11), placeName: "浅草"),
            TravelEntry(id: skytreeID, kind: .place, title: "东京晴空塔",
                        start: day(11, 14), end: day(11, 16), placeName: "押上"),
        ]
        return TravelPlan.promptSummary(tripTitle: "东京四日", days: tripDays, entries: entries,
                                        includeIDs: true)
    }

    // MARK: - 跑一轮(照抄 route() 的 ReAct 循环)

    private struct Caps {
        var memory = true
        var webSearch = false
        var health = false
        var travel = false
        var news = false
    }

    private struct Run {
        var result: AICommandResult
        var tools: [AITool]
        var actions: [AIAction] {
            if case .actions(let list) = result { return list }
            return []
        }
    }

    private func run(_ text: String, caps: Caps = Caps(), focus: AgentFocus? = nil,
                     history: [(role: String, content: String)] = [],
                     extraTasks: [(uuid: String, task: ParsedTask)] = [],
                     file: StaticString = #filePath, line: UInt = #line) async throws -> Run {
        var reasoning = history
        var current = text
        var tools: [AITool] = []
        for _ in 0..<3 {
            let result = try await DeepSeekClient.command(
                current, tasks: tasks + extraTasks, memoryEnabled: caps.memory,
                webSearchEnabled: caps.webSearch, healthEnabled: caps.health,
                travelEnabled: caps.travel, tripPlanEnabled: true, newsEnabled: caps.news,
                countdownEnabled: true, countdowns: countdowns,
                assetsEnabled: true, assets: assets,
                feedsEnabled: true, feeds: feeds,
                pageFocus: focus, history: reasoning, existingProjects: ["工作"])
            guard case .toolCall(let thought, let tool) = result else {
                log(text, result, tools)
                return Run(result: result, tools: tools)
            }
            tools.append(tool)
            let (label, header, observation) = stub(tool)
            reasoning.append((role: "assistant", content: "思考:\(thought);\(label)"))
            reasoning.append((role: "user", content: "\(header):\n\(observation)"))
            current = "(请基于以上\(header)继续处理最初的请求:\(text))"
        }
        XCTFail("3 轮之内没有给出最终答案,工具调用:\(tools)", file: file, line: line)
        throw DeepSeekError.parse("ReAct 超过 3 轮")
    }

    /// 工具桩:历史条目的前缀和 app 逐字一致。
    private func stub(_ tool: AITool) -> (label: String, header: String, observation: String) {
        switch tool {
        case .searchMemory(let q):
            return ("查记忆:\(q)", "记忆检索结果",
                    "「家里 WiFi」名称 Lodo-Home,密码 sunshine2026 [id:\(Self.wifiMemoryID)]\n"
                    + "「班主任」王老师,喜欢手写贺卡 [id:\(Self.teacherMemoryID)]")
        case .webSearch(let q):
            return ("联网搜索:\(q)", "搜索结果",
                    "「上海天气预报」今天多云转晴,18–24°C,东北风 3 级。\n来源:https://weather.example.com/shanghai")
        case .webFetch(let url):
            return ("抓取链接:\(url)", "链接内容",
                    "Swift 6.2 发布说明:默认开启更严格的并发检查,新增 InlineArray 与 Span 类型,编译速度提升约 20%。")
        case .readHealth(let days):
            return ("读健康数据:最近 \(days) 天", "健康数据",
                    "睡眠:日均 6.2 小时,最近一晚 5.5 小时,比之前 7 天少 0.8 小时\n步数:日均 8400 步")
        case .readTrip(let name):
            return ("读行程:\(name.isEmpty ? "当前旅行" : name)", "行程", tripObservation)
        case .searchNews(let q):
            return ("找订阅文章:\(q.isEmpty ? "最新" : q)", "订阅文章",
                    "1. [少数派] 苹果发布 iOS 27.1:锁屏小组件支持交互(今天 08:30)\n链接:https://sspai.com/post/1")
        case .loadSkill(let name):
            return ("加载 skill:\(name)", "skill 内容", "没有这个 skill")
        }
    }

    /// 每个场景的输入、工具调用、最终结果追加写进 `LODO_LIVE_AI_LOG` 指定的文件,
    /// 断言失败时翻这里看模型到底给了什么。
    private func log(_ text: String, _ result: AICommandResult, _ tools: [AITool]) {
        guard let path = ProcessInfo.processInfo.environment["LODO_LIVE_AI_LOG"] else { return }
        let line = "▶︎ \(text)\n   工具:\(tools)\n   结果:\(result)\n\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LODO_LIVE_AI"] == "1",
                          "设置 LODO_LIVE_AI=1 才会真发请求")
        try XCTSkipUnless(DeepSeekClient.isConfigured, "没有可用的 AI key")
    }

    /// 不发请求:把这套夹具下的完整 system prompt 写到日志旁边(`<log>.prompt.txt`),
    /// 排查"模型为什么这么答"时先看它到底收到了什么。
    func testDumpSystemPrompt() throws {
        guard let path = ProcessInfo.processInfo.environment["LODO_LIVE_AI_LOG"] else {
            throw XCTSkip("没设 LODO_LIVE_AI_LOG")
        }
        let caps = DeepSeekClient.CommandCapabilities(
            memory: true, webSearch: true, health: true, travel: true, tripPlan: true,
            news: true, countdown: true, assets: true, feeds: true)
        let prompt = DeepSeekClient.commandSystemPrompt(
            tasks: tasks, capabilities: caps, existingProjects: ["工作"],
            countdowns: countdowns, assets: assets, feeds: feeds).system
        try prompt.write(toFile: path + ".prompt.txt", atomically: true, encoding: .utf8)
    }

    // MARK: - 断言小工具

    private func creates(_ run: Run) -> [ParsedTask] {
        run.actions.compactMap { if case .create(let t) = $0 { return t } else { return nil } }
    }

    private func hm(_ date: Date) -> (Int, Int) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? -1, c.minute ?? -1)
    }

    // MARK: - 待办

    func testCreateSingleTask() async throws {
        let r = try await run("明天下午3点提醒我给妈妈打电话")
        let list = creates(r)
        XCTAssertEqual(list.count, 1)
        guard let task = list.first else { return }
        XCTAssertTrue(task.title.contains("妈妈"), task.title)
        XCTAssertTrue(calendar.isDate(task.remindAt, inSameDayAs: day(1)))
        XCTAssertEqual(hm(task.remindAt).0, 15)
        XCTAssertFalse(task.allDay)
    }

    func testCreateBatch() async throws {
        let r = try await run("明天上午10点开周会,晚上8点去健身")
        let list = creates(r)
        XCTAssertEqual(list.count, 2, "\(r.result)")
        XCTAssertEqual(Set(list.map { hm($0.remindAt).0 }), [10, 20])
    }

    func testCreateWeeklyRepeat() async throws {
        let r = try await run("每周一三五早上7点提醒我跑步")
        guard let task = creates(r).first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(task.repeatType, .weekly)
        XCTAssertEqual(Set(task.repeatDays), [0, 2, 4], "周几 0=周一")
        XCTAssertEqual(task.repeatTimes, ["07:00"])
    }

    func testCreateDailyRepeat() async throws {
        let r = try await run("每天晚上10点提醒我吃药")
        guard let task = creates(r).first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(task.repeatType, .daily)
        XCTAssertEqual(task.repeatTimes, ["22:00"])
    }

    func testCreateAllDay() async throws {
        let r = try await run("后天要交水电费")
        guard let task = creates(r).first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(calendar.isDate(task.remindAt, inSameDayAs: day(2)))
        XCTAssertTrue(task.allDay, "只说了日子没说时刻,应为全天")
    }

    func testCreateWithProject() async throws {
        let r = try await run("工作项目里加一条:周五下午整理季度预算")
        guard let task = creates(r).first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(task.project, "工作")
    }

    func testCreateEnglish() async throws {
        let r = try await run("Remind me tomorrow at 9am to call John")
        guard let task = creates(r).first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(calendar.isDate(task.remindAt, inSameDayAs: day(1)))
        XCTAssertEqual(hm(task.remindAt).0, 9)
    }

    func testUpdateTask() async throws {
        let r = try await run("把买牛奶改到后天早上9点")
        guard case .update(let uuid, let task)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(uuid, milkID)
        XCTAssertTrue(calendar.isDate(task.remindAt, inSameDayAs: day(2)))
        XCTAssertEqual(hm(task.remindAt).0, 9)
    }

    func testCompleteTask() async throws {
        let r = try await run("房租已经交了")
        guard case .complete(let uuid)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(uuid, rentID)
    }

    func testDeleteTask() async throws {
        let r = try await run("删掉买牛奶那条")
        guard case .delete(let uuid)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(uuid, milkID)
    }

    func testAsksWhenInfoMissing() async throws {
        let r = try await run("帮我加个提醒")
        guard case .ask(let questions) = r.result else { return XCTFail("应该反问:\(r.result)") }
        XCTAssertFalse(questions.isEmpty)
        XCTAssertFalse(questions[0].question.isEmpty)
    }

    // MARK: - 对话、记忆、偏好

    func testChatAnswer() async throws {
        let r = try await run("你好,你能帮我做什么?")
        guard case .answer(let text)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertFalse(text.isEmpty)
    }

    func testMemorize() async throws {
        let r = try await run("帮我收藏这段话:好的设计是尽可能少的设计。——迪特·拉姆斯")
        guard case .memorize(let text)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(text.contains("设计"))
    }

    func testAskMemoryUsesSearch() async throws {
        let r = try await run("我之前收藏的家里 WiFi 密码是多少?")
        let searched = r.tools.contains { if case .searchMemory = $0 { return true } else { return false } }
        let asked = r.actions.contains { if case .askMemory = $0 { return true } else { return false } }
        XCTAssertTrue(searched || asked, "应该查记忆:\(r.result)")
        if searched, case .answer(let text)? = r.actions.first {
            XCTAssertTrue(text.contains("sunshine2026"), "答案应来自检索结果:\(text)")
        }
    }

    static let wifiMemoryID = "6F1C2D3E-4A5B-4C6D-8E7F-901A2B3C4D5E"
    static let teacherMemoryID = "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D"

    func testDeleteMemoryUsesSearchedID() async throws {
        let r = try await run("把我收藏的家里 WiFi 那条记忆删掉")
        let searched = r.tools.contains { if case .searchMemory = $0 { return true } else { return false } }
        XCTAssertTrue(searched, "应该先查记忆拿 id:\(r.result)")
        guard case .deleteMemory(let ids)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(ids, [Self.wifiMemoryID], "只删用户指的那条:\(r.result)")
    }

    func testRememberPreference() async throws {
        let r = try await run("以后我说开会,默认都提前15分钟提醒我")
        let pref = r.actions.contains {
            if case .rememberPreference = $0 { return true } else { return false }
        }
        XCTAssertTrue(pref, "\(r.result)")
    }

    func testAutoMemorizeAlongsideTask() async throws {
        let r = try await run("提醒我下周一给班主任王老师买贺卡,她特别喜欢手写的贺卡")
        XCTAssertEqual(creates(r).count, 1, "\(r.result)")
    }

    // MARK: - 工具

    func testWebSearch() async throws {
        let r = try await run("今天上海天气怎么样?", caps: Caps(webSearch: true))
        XCTAssertTrue(r.tools.contains { if case .webSearch = $0 { return true } else { return false } },
                      "应该联网:\(r.tools)")
        guard case .answer(let text)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(text.contains("18") || text.contains("多云"), text)
    }

    func testWebFetch() async throws {
        let r = try await run("帮我看看这个链接讲了什么 https://www.swift.org/blog/swift-6.2-released/",
                              caps: Caps(webSearch: true))
        XCTAssertTrue(r.tools.contains { if case .webFetch = $0 { return true } else { return false } },
                      "应该抓链接而不是搜关键词:\(r.tools)")
        guard case .answer? = r.actions.first else { return XCTFail("\(r.result)") }
    }

    func testAnswerWithoutWebSearch() async throws {
        // 没配联网也要能直接回话(answer 不受开关门控)。
        let r = try await run("番茄炒蛋怎么做?")
        guard case .answer(let text)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertFalse(text.isEmpty)
    }

    func testReadHealth() async throws {
        let r = try await run("我这周睡得怎么样?", caps: Caps(health: true))
        XCTAssertTrue(r.tools.contains { if case .readHealth = $0 { return true } else { return false } },
                      "\(r.tools)")
        guard case .answer(let text)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(text.contains("6.2") || text.contains("5.5"), text)
    }

    func testSearchNews() async throws {
        let r = try await run("我订阅的文章里最近有什么苹果相关的?", caps: Caps(news: true))
        XCTAssertTrue(r.tools.contains { if case .searchNews = $0 { return true } else { return false } },
                      "\(r.tools)")
        guard case .answer(let text)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(text.contains("27.1") || text.contains("iOS"), text)
    }

    // MARK: - 旅行

    func testReadTripAnswer() async throws {
        let r = try await run("我去东京的航班几点起飞?", caps: Caps(travel: true))
        XCTAssertTrue(r.tools.contains { if case .readTrip = $0 { return true } else { return false } },
                      "\(r.tools)")
        guard case .answer(let text)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(text.contains("9:30") || text.contains("09:30"), text)
    }

    func testPlanTrip() async throws {
        let r = try await run("帮我规划一下京都三天的行程,下个月10号出发")
        guard case .planTrip(let plan)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertFalse(plan.items.isEmpty)
        XCTAssertNotNil(plan.country, "plan_trip 必须带国家,地图要靠它定位")
        XCTAssertTrue((plan.city ?? plan.tripTitle).contains("京都"))
        XCTAssertLessThanOrEqual(plan.summary.count, 30, "summary 是一句话:\(plan.summary)")
        let days = calendar.dateComponents([.day], from: plan.startDate, to: plan.endDate).day ?? -1
        XCTAssertEqual(days, 2, "三天 = 起止相差 2 天")
    }

    func testEditTripRemovesByID() async throws {
        let r = try await run("把东京四日里的浅草寺删掉", caps: Caps(travel: true))
        XCTAssertTrue(r.tools.contains { if case .readTrip = $0 { return true } else { return false } },
                      "改行程前必须先 read_trip:\(r.tools)")
        guard case .editTrip(let edit)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(edit.removeIDs, [sensojiID])
    }

    func testEditTripCannotTouchFlight() async throws {
        let r = try await run("把东京四日的去程航班删了", caps: Caps(travel: true))
        // 模型可能拒绝(answer)或照样给 edit_trip(app 层 protectedReason 会挡住);
        // 不允许的是把航班 id 以外的东西删掉。
        if case .editTrip(let edit)? = r.actions.first {
            XCTAssertTrue(Set(edit.removeIDs).isSubset(of: [flightID]), "\(edit.removeIDs)")
        }
    }

    /// 给已经记下的行程项记费用:update 带 price/currency,不新加一项、不删。
    func testEditTripAddsPriceToExistingItem() async throws {
        let r = try await run("东京四日里浅草寺的门票记一下,500 日元", caps: Caps(travel: true))
        guard case .editTrip(let edit)? = r.actions.first else { return XCTFail("\(r.result)") }
        guard let update = edit.updates.first(where: { $0.id == sensojiID }) else {
            return XCTFail("应该 update 浅草寺:\(edit)")
        }
        XCTAssertEqual(update.price, 500)
        XCTAssertEqual(update.currency, "JPY")
        XCTAssertTrue(edit.removeIDs.isEmpty)
        XCTAssertTrue(edit.additions.isEmpty, "不该另加一项:\(edit.additions)")
    }

    /// 用户原话:「xx 行程中 xx 酒店 2 天花了一共 2000 元」。只记总价,**不许**因为"2 天"
    /// 和记下的住宿天数(3 晚)对不上就去改入住/退房时间。
    func testHotelTotalCostDoesNotTouchDates() async throws {
        let r = try await run("东京四日行程中新宿王子酒店2天花了一共2000元", caps: Caps(travel: true))
        guard case .editTrip(let edit)? = r.actions.first else { return XCTFail("\(r.result)") }
        guard let update = edit.updates.first(where: { $0.id == hotelID }) else {
            return XCTFail("应该 update 酒店:\(edit)")
        }
        XCTAssertEqual(update.price, 2000)
        XCTAssertEqual(update.currency, "CNY")
        XCTAssertNil(update.start, "不该改入住时间:\(update)")
        XCTAssertNil(update.end, "不该改退房时间:\(update)")
        XCTAssertTrue(edit.additions.isEmpty && edit.removeIDs.isEmpty, "\(edit)")
    }

    /// 按晚报价:模型给 price_per_night(或者自己乘对了的总价),app 按记下的 3 晚算总价 2400;
    /// 「元」是人民币,不能因为旅行在日本就当成日元。
    func testHotelPerNightPriceStoresTotal() async throws {
        let r = try await run("东京四日的新宿王子酒店一晚 800 元,帮我记上房费", caps: Caps(travel: true))
        guard case .editTrip(let edit)? = r.actions.first else { return XCTFail("\(r.result)") }
        guard let update = edit.updates.first(where: { $0.id == hotelID }) else {
            return XCTFail("应该 update 酒店:\(edit)")
        }
        XCTAssertEqual(update.resolvedPrice(kind: .lodging, start: day(10, 15), end: day(13, 11)), 2400,
                       "总价应为 800×3:\(update)")
        XCTAssertEqual(update.currency, "CNY")
        XCTAssertNil(update.start)
        XCTAssertNil(update.end)
    }

    /// 航班可以补费用(时刻不动)。
    func testEditTripAddsPriceToFlight() async throws {
        let r = try await run("东京四日的去程机票花了 3200 块,帮我记上", caps: Caps(travel: true))
        guard case .editTrip(let edit)? = r.actions.first else { return XCTFail("\(r.result)") }
        guard let update = edit.updates.first(where: { $0.id == flightID }) else {
            return XCTFail("应该 update 航班:\(edit)")
        }
        XCTAssertEqual(update.price, 3200)
        XCTAssertTrue(update.touchesOnlyCostOrNote, "航班只能改费用:\(update)")
    }

    func testTravelPageFocus() async throws {
        let r = try await run("第二天下午改去上野公园,晴空塔不去了",
                              caps: Caps(travel: true), focus: .travel(trip: "东京四日"))
        guard case .editTrip(let edit)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(edit.removeIDs.contains(skytreeID) || edit.updates.contains { $0.id == skytreeID },
                      "\(edit)")
    }

    // MARK: - 倒数日、资产、订阅

    func testCreateCountdown() async throws {
        let r = try await run("帮我加一个倒数日:明年元旦")
        guard case .countdown(.create(let draft))? = r.actions.first else { return XCTFail("\(r.result)") }
        let year = calendar.component(.year, from: Date()) + 1
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: draft.start),
                       DateComponents(year: year, month: 1, day: 1))
    }

    func testDeleteCountdown() async throws {
        let r = try await run("把结婚纪念日那个倒数日删了")
        guard case .countdown(.delete(let id))? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(id, anniversaryID)
    }

    func testCreateAsset() async throws {
        let r = try await run("记一笔资产:支付宝余额宝里有 2 万")
        guard case .asset(.create(let draft))? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(draft.value, 20_000)
    }

    func testUpdateAsset() async throws {
        let r = try await run("招商银行定期现在有 6 万了")
        guard case .asset(.update(let id, _))? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(id, depositID)
    }

    func testSubscribeFeed() async throws {
        let r = try await run("帮我订阅这个博客 https://www.ruanyifeng.com/blog/atom.xml")
        guard case .feed(.subscribe(let draft))? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(draft.url, "https://www.ruanyifeng.com/blog/atom.xml")
    }

    func testPauseFeed() async throws {
        let r = try await run("少数派先别推了,暂停一下")
        guard case .feed(.update(let id, let change))? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(id, sspaiID)
        XCTAssertEqual(change.enabled, false)
    }

    func testTaskAndCountdownInOneSentence() async throws {
        let r = try await run("下个月15号是老婆生日,加个倒数日,再提醒我前一天晚上8点订蛋糕")
        let hasCountdown = r.actions.contains { if case .countdown = $0 { return true } else { return false } }
        XCTAssertTrue(hasCountdown, "\(r.result)")
        XCTAssertEqual(creates(r).count, 1, "\(r.result)")
    }

    // MARK: - 边界场景

    func testRelativeWeekday() async throws {
        let r = try await run("下周三下午两点半看牙医")
        guard let task = creates(r).first else { return XCTFail("\(r.result)") }
        // 下周三:下一个自然周的周三(周一起头)。
        let weekdayIndex = (calendar.component(.weekday, from: today) + 5) % 7  // 0=周一
        let expected = day(7 - weekdayIndex + 2)
        XCTAssertTrue(calendar.isDate(task.remindAt, inSameDayAs: expected),
                      "\(task.remindAt) vs \(expected)")
        XCTAssertEqual(hm(task.remindAt).0, 14)
        XCTAssertEqual(hm(task.remindAt).1, 30)
    }

    func testQuestionAboutScheduleAnswersFromTaskList() async throws {
        let r = try await run("我后天有什么安排?")
        guard case .answer(let text)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(text.contains("房租"), text)
        XCTAssertFalse(r.actions.contains { if case .create = $0 { return true } else { return false } })
    }

    func testFollowUpNeverRenamesAnotherTask() async throws {
        // 对话里说的事项不在列表里(已完成/超出 50 条/别的设备删了):最伤的错误是把列表里
        // 另一件事整个改成它(实测出现过,单条修改直接落库)。guardMisdirectedUpdates 兜这一层。
        // 已知限制:模型只改了另一件事的时间、不改标题时,和"把买牛奶改成4点"分不出来,不在此列。
        let history = [
            (role: "user", content: "明天下午3点提醒我给妈妈打电话"),
            (role: "assistant", content: "已新建:给妈妈打电话(明天 15:00)"),
        ]
        let r = try await run("改成4点吧", history: history)
        for action in r.actions {
            if case .update(let uuid, let task) = action,
               let original = tasks.first(where: { $0.uuid == uuid })?.task {
                XCTAssertEqual(task.title, original.title, "把「\(original.title)」改成了别的事")
            }
        }
        if let task = creates(r).first {
            XCTAssertEqual(hm(task.remindAt).0, 16)
            XCTAssertTrue(task.title.contains("妈妈"), task.title)
        }
    }

    func testFollowUpEditsJustCreatedTask() async throws {
        // 真实情形:上一轮新建的事项已经在待办列表里了。
        let momID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let mom = ParsedTask(title: "给妈妈打电话", remindAt: day(1, 15), allDay: false,
                             repeatType: .none, repeatDays: [], repeatTimes: [])
        let history = [
            (role: "user", content: "明天下午3点提醒我给妈妈打电话"),
            (role: "assistant", content: "已新建:给妈妈打电话(明天 15:00)"),
        ]
        let r = try await run("改成4点吧", history: history, extraTasks: [(momID, mom)])
        guard case .update(let uuid, let task)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(uuid, momID)
        XCTAssertEqual(hm(task.remindAt).0, 16)
        XCTAssertTrue(calendar.isDate(task.remindAt, inSameDayAs: day(1)))
    }

    func testAnswerAfterAsk() async throws {
        // 模拟反问卡片答完后的下一轮:选择结果随历史回传。
        let history = [
            (role: "user", content: "帮我加个提醒:取快递"),
            (role: "assistant", content: "{\"ask\": [{\"header\": \"时间\", \"question\": \"什么时候提醒你取快递?\", \"options\": [{\"label\": \"今天 18:00\"}, {\"label\": \"明天 09:00\"}]}]}"),
        ]
        let r = try await run("什么时候提醒你取快递?:明天 09:00", history: history)
        guard let task = creates(r).first else { return XCTFail("\(r.result)") }
        XCTAssertTrue(task.title.contains("快递"), task.title)
        XCTAssertTrue(calendar.isDate(task.remindAt, inSameDayAs: day(1)))
        XCTAssertEqual(hm(task.remindAt).0, 9)
    }

    func testSuggestMemorizeOnPlainFact() async throws {
        let r = try await run("我的护照号是 E12345678,有效期到 2031 年")
        let ok = r.actions.contains {
            switch $0 {
            case .suggestMemorize, .memorize, .autoMemorize: return true
            default: return false
            }
        }
        XCTAssertTrue(ok, "陈述一条值得记的信息时应建议/记录收藏:\(r.result)")
        XCTAssertTrue(creates(r).isEmpty, "不该凭空建待办:\(r.result)")
    }

    func testRecordTripIsNotPlanning() async throws {
        let r = try await run("记一下:下周五去成都两天,住春熙路的亚朵,周六上午去大熊猫基地")
        guard case .planTrip(let plan)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(plan.recorded, true, "这是记录不是规划,应带 record:true")
        XCTAssertTrue(plan.items.contains { $0.title.contains("熊猫") }, "\(plan.items.map(\.title))")
        XCTAssertLessThanOrEqual(plan.items.count, 4, "记录时只照用户说的记,不补景点:\(plan.items.map(\.title))")
    }

    func testRenameCountdown() async throws {
        let r = try await run("把结婚纪念日改名叫「我们的纪念日」")
        guard case .countdown(.update(let id, let change))? = r.actions.first else {
            return XCTFail("\(r.result)")
        }
        XCTAssertEqual(id, anniversaryID)
        XCTAssertEqual(change.title, "我们的纪念日")
    }

    func testNoHallucinatedToolWhenDisabled() async throws {
        // 健康开关关着:不能调 read_health(parseCommand 会直接报错)。
        let r = try await run("我昨天走了多少步?")
        XCTAssertFalse(r.tools.contains { if case .readHealth = $0 { return true } else { return false } })
        guard case .answer? = r.actions.first else { return XCTFail("\(r.result)") }
    }

    func testCompleteRepeatingTask() async throws {
        let r = try await run("这周的周报写完了")
        guard case .complete(let uuid)? = r.actions.first else { return XCTFail("\(r.result)") }
        XCTAssertEqual(uuid, reportID)
    }

    func testDeleteNonexistentDoesNotTouchOthers() async throws {
        let r = try await run("把去健身房那条删了")
        for action in r.actions {
            if case .delete(let uuid) = action { XCTFail("列表里没有健身的事项,不该删 \(uuid)") }
        }
    }

    func testCountdownFocusAmbiguous() async throws {
        let r = try await run("加一个,明年 5 月 1 号", focus: AgentFocus(page: .countdown))
        guard case .countdown(.create(let draft))? = r.actions.first else {
            return XCTFail("在倒数日页说的含糊新建应是倒数日:\(r.result)")
        }
        XCTAssertEqual(calendar.component(.month, from: draft.start), 5)
    }
}
