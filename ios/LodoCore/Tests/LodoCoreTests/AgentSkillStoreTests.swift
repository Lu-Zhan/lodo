import XCTest
@testable import LodoCore

/// AgentSkillStore 的存取/重置离线单测;每个用例前后清理覆盖文件,不污染本机状态。
final class AgentSkillStoreTests: XCTestCase {
    override func tearDown() {
        for id in AgentSkillID.allCases {
            AgentSkillStore.reset(id)
            UserDefaults.standard.removeObject(forKey: "agentSkillEnabled.\(id.rawValue)")
        }
        for skill in AgentSkillStore.customSkills() { AgentSkillStore.deleteCustom(slug: skill.slug) }
        super.tearDown()
    }

    func testDefaultContentNonEmpty() {
        for id in AgentSkillID.allCases {
            XCTAssertFalse(AgentSkillStore.defaultContent(for: id)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(id) 默认内容为空")
        }
    }

    func testContentFallsBackToDefaultWhenNotCustomized() {
        for id in AgentSkillID.allCases {
            XCTAssertFalse(AgentSkillStore.isCustomized(id))
            XCTAssertEqual(AgentSkillStore.content(for: id), AgentSkillStore.defaultContent(for: id))
        }
    }

    func testSaveThenContentReadsOverride() {
        AgentSkillStore.save("自定义总则内容", for: .agent)
        XCTAssertTrue(AgentSkillStore.isCustomized(.agent))
        XCTAssertEqual(AgentSkillStore.content(for: .agent), "自定义总则内容")
        // 其他 skill 不受影响
        XCTAssertFalse(AgentSkillStore.isCustomized(.todo))
    }

    func testResetRestoresDefault() {
        AgentSkillStore.save("临时内容", for: .memory)
        AgentSkillStore.reset(.memory)
        XCTAssertFalse(AgentSkillStore.isCustomized(.memory))
        XCTAssertEqual(AgentSkillStore.content(for: .memory), AgentSkillStore.defaultContent(for: .memory))
    }

    func testSaveEmptyTextActsAsReset() {
        AgentSkillStore.save("有内容", for: .todo)
        AgentSkillStore.save("   ", for: .todo)
        XCTAssertFalse(AgentSkillStore.isCustomized(.todo))
    }

    // MARK: - 分组与开关

    func testEverySkillHasGroupAndGroupsAreNotCustom() {
        for id in AgentSkillID.allCases { XCTAssertNotEqual(id.group, .custom) }
    }

    func testEnabledDefaultsToTrueAndAgentTodoCannotBeDisabled() {
        for id in AgentSkillID.allCases { XCTAssertTrue(AgentSkillStore.isEnabled(id)) }
        AgentSkillStore.setEnabled(false, for: .agent)
        AgentSkillStore.setEnabled(false, for: .todo)
        XCTAssertTrue(AgentSkillStore.isEnabled(.agent))
        XCTAssertTrue(AgentSkillStore.isEnabled(.todo))
        AgentSkillStore.setEnabled(false, for: .travel)
        XCTAssertFalse(AgentSkillStore.isEnabled(.travel))
    }

    // MARK: - 抽出的 prompt 默认渲染与原文一致

    func testTodoContentMatchesOldConcatenation() {
        XCTAssertEqual(AgentSkillStore.todoContent(existingProjects: []),
                       AgentSkillStore.content(for: .todo))
        XCTAssertEqual(AgentSkillStore.todoContent(existingProjects: ["装修", "考研"]),
                       AgentSkillStore.content(for: .todo) + """


        - 已有项目:装修、考研。project 优先从已有项目中选用语义相近的,都不合适时才创建新项目;实在看不出属于哪个项目就留空字符串,不要瞎猜。
        """)
    }

    func testTodoPlaceholderIsReplacedInPlace() {
        AgentSkillStore.save("前{{projects}}后", for: .todo)
        XCTAssertEqual(AgentSkillStore.todoContent(existingProjects: []), "前后")
        XCTAssertTrue(AgentSkillStore.todoContent(existingProjects: ["装修"]).hasPrefix("前\n\n- 已有项目:装修"))
    }

    func testDurationPromptMatchesOriginal() {
        XCTAssertEqual(AgentSkillStore.durationPrompt(memory: "M"), """
        你是提醒事项应用 lodo 的时长建议助手。下面是"事项类型 → 典型时长"的记忆文件、用户创建事项的原话和解析出的事项标题,只返回 JSON,不要任何其他文字。

        判断规则:
        - 用户原话明确表示不需要时长,或记忆中没有类型相近的条目 → {"duration_minutes": 0}
        - 否则参考记忆中相近类型的典型时长 → {"duration_minutes": 分钟数}

        记忆文件:
        M
        """)
        AgentSkillStore.setEnabled(false, for: .duration)
        XCTAssertNil(AgentSkillStore.durationPrompt(memory: "M"))
    }

    func testDurationWithoutPlaceholderAppendsMemory() {
        AgentSkillStore.save("自定义规则", for: .duration)
        XCTAssertEqual(AgentSkillStore.durationPrompt(memory: "M"), "自定义规则\n\n记忆文件:\nM")
    }

    func testAssetRulesAndRoutineWebDefaults() {
        let assets = AgentSkillStore.assetRules() ?? ""
        XCTAssertTrue(assets.hasPrefix("- 如果内容记录的是一项资产/资金的价值(比如\"存折里还有5000美元\"、"))
        XCTAssertTrue(assets.hasSuffix("不是负债内容时不要返回 liability_value/interest_rate。"))
        AgentSkillStore.setEnabled(false, for: .assets)
        XCTAssertNil(AgentSkillStore.assetRules())

        let web = AgentSkillStore.routineWebTools()
        XCTAssertTrue(web.hasPrefix("\n\n如果需要最新/实时信息(天气、行情、新闻等)才能完成任务,先返回:"))
        XCTAssertTrue(web.hasSuffix("不能一直用工具占位不给结果。"))
        AgentSkillStore.setEnabled(false, for: .routineWeb)
        XCTAssertEqual(AgentSkillStore.routineWebTools(), "")
    }

    // MARK: - 用户 skill

    private let external = """
    ---
    name: 日料点菜助手
    description: 用户在餐厅问点菜时使用
    ---
    先问几位用餐。
    """

    func testImportNewCustomIsDisabledUntilEnabled() throws {
        let plan = try AgentSkillStore.planImport(external).get()
        guard case .newCustom(_, let slug, let replacing) = plan else { return XCTFail("应是新 skill") }
        XCTAssertFalse(replacing)
        AgentSkillStore.apply(plan)
        XCTAssertEqual(AgentSkillStore.customSkills().map(\.slug), [slug])
        XCTAssertNil(AgentSkillStore.catalogBlock(), "默认停用,不进目录")
        XCTAssertNil(AgentSkillStore.loadCustomBody(named: "日料点菜助手"))

        AgentSkillStore.setCustomEnabled(true, slug: slug)
        XCTAssertTrue(AgentSkillStore.catalogBlock()?.contains("- 日料点菜助手:用户在餐厅问点菜时使用") == true)
        XCTAssertEqual(AgentSkillStore.loadCustomBody(named: " 日料点菜助手 "), "先问几位用餐。")
        XCTAssertNil(AgentSkillStore.loadCustomBody(named: "不存在"))

        // 再导入同名 ⇒ 覆盖,且保持原来的启用状态
        let again = try AgentSkillStore.planImport(external).get()
        guard case .newCustom(_, _, let replacingAgain) = again else { return XCTFail() }
        XCTAssertTrue(replacingAgain)
        AgentSkillStore.apply(again)
        XCTAssertTrue(AgentSkillStore.isCustomEnabled(slug: slug))

        AgentSkillStore.deleteCustom(slug: slug)
        XCTAssertTrue(AgentSkillStore.customSkills().isEmpty)
        XCTAssertFalse(AgentSkillStore.isCustomEnabled(slug: slug))
    }

    func testImportSameNameAsBuiltinOverridesIt() throws {
        let text = "---\nname: 旅行\ndescription: d\n---\n我的旅行规则"
        let plan = try AgentSkillStore.planImport(text).get()
        guard case .overrideBuiltin(let id, _) = plan else { return XCTFail("应覆盖内置") }
        XCTAssertEqual(id, .travel)
        AgentSkillStore.apply(plan)
        XCTAssertEqual(AgentSkillStore.content(for: .travel), "我的旅行规则")
        XCTAssertTrue(AgentSkillStore.customSkills().isEmpty)
    }

    func testExportBuiltinRoundTripsThroughImport() throws {
        let exported = AgentSkillStore.exportFile(for: .health).render()
        let plan = try AgentSkillStore.planImport(exported).get()
        guard case .overrideBuiltin(let id, let file) = plan else { return XCTFail() }
        XCTAssertEqual(id, .health)
        XCTAssertEqual(file.body, AgentSkillStore.defaultContent(for: .health)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSlugKeepsUnicodeAndCollapsesSeparators() {
        XCTAssertEqual(AgentSkillStore.slug(for: "日料 点菜/助手!"), "日料-点菜-助手")
        XCTAssertEqual(AgentSkillStore.slug(for: "***"), "skill")
    }

    // MARK: - system prompt 组装

    func testCommandPromptHonorsSkillSwitchesAndCatalog() throws {
        let caps = DeepSeekClient.CommandCapabilities(memory: true, travel: true, tripPlan: true)
        let full = DeepSeekClient.commandSystemPrompt(tasks: [], capabilities: caps).system
        XCTAssertTrue(full.contains(AgentSkillStore.content(for: .travel)))
        XCTAssertFalse(full.contains("可加载的 skills"), "没有外部 skill 时不出现目录")

        AgentSkillStore.setEnabled(false, for: .travel)
        let off = DeepSeekClient.commandSystemPrompt(tasks: [], capabilities: caps).system
        XCTAssertFalse(off.contains(AgentSkillStore.content(for: .travel)))
        XCTAssertTrue(off.contains(AgentSkillStore.content(for: .memory)))

        let plan = try AgentSkillStore.planImport(external).get()
        AgentSkillStore.apply(plan)
        guard case .newCustom(_, let slug, _) = plan else { return XCTFail() }
        AgentSkillStore.setCustomEnabled(true, slug: slug)
        let withCatalog = DeepSeekClient.commandSystemPrompt(tasks: [], capabilities: caps).system
        XCTAssertTrue(withCatalog.contains("- 日料点菜助手:用户在餐厅问点菜时使用"))
        XCTAssertFalse(withCatalog.contains("先问几位用餐。"), "正文按需加载,不常驻 prompt")
    }
}
