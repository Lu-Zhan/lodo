package com.lodo.app.ai

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime

/** 这一轮从 iOS 移植的 command 协议(提问卡、倒数日、资产、订阅、行程)离线单测,同 iOS 的同名用例。 */
class AgentProtocolTest {
    private fun actions(vararg a: JSONObject) = JSONObject().put("actions", JSONArray(a.toList()))

    @Test
    fun askParsesQuestions() {
        val payload = JSONObject().put("ask", JSONArray().put(JSONObject()
            .put("header", "时间").put("question", "几点提醒?").put("multi_select", false)
            .put("options", JSONArray().put(JSONObject().put("label", "明天 09:00").put("recommended", true)).put(JSONObject().put("label", "明天 14:00")))))
        val r = DeepSeekClient.parseCommandResult(payload, emptySet(), false) as AICommandResult.Ask
        assertEquals("几点提醒?", r.questions[0].question)
        assertTrue(r.questions[0].options[0].recommended)
    }

    @Test(expected = DeepSeekException::class)
    fun askWithoutOptionsThrows() {
        val payload = JSONObject().put("ask", JSONArray().put(JSONObject().put("question", "?").put("options", JSONArray())))
        DeepSeekClient.parseCommandResult(payload, emptySet(), false)
    }

    @Test
    fun replyWithoutActionsBecomesAnswer() {
        val r = DeepSeekClient.parseCommandResult(JSONObject().put("actions", JSONArray()).put("reply", "你好"), emptySet(), false)
        assertEquals(listOf(AIAction.Answer("你好")), (r as AICommandResult.Actions).actions)
    }

    @Test
    fun bareActionWithoutEnvelope() {
        val r = DeepSeekClient.parseCommandResult(JSONObject().put("action", "answer").put("text", "hi"), emptySet(), false)
        assertEquals(listOf(AIAction.Answer("hi")), (r as AICommandResult.Actions).actions)
    }

    @Test
    fun toolInsideActionsIsToolCall() {
        val payload = actions(JSONObject().put("action", "read_trip").put("name", "东京"))
        val r = DeepSeekClient.parseCommandResult(payload, emptySet(), false, travel = true)
        assertEquals(AITool.ReadTrip("东京"), (r as AICommandResult.ToolCall).tool)
    }

    @Test
    fun countdownCreateAllDayAndMixedWithTask() {
        val payload = actions(
            JSONObject().put("action", "create").put("title", "交报告").put("remind_at", "2026-07-09 15:00"),
            JSONObject().put("action", "create_countdown").put("title", "考研").put("start", "2026-12-20").put("start_reminders", JSONArray(listOf(1440, 0, 1440))),
        )
        val r = DeepSeekClient.parseCommandResult(payload, emptySet(), false, countdown = true) as AICommandResult.Actions
        assertEquals(2, r.actions.size)
        val op = (r.actions[0] as AIAction.Countdown).op as CountdownOp.Create
        assertTrue(op.draft.allDay)
        assertEquals(listOf(0, 1440), op.draft.startReminders)
        assertTrue(r.actions[1] is AIAction.Create)
    }

    @Test
    fun countdownUpdateCanonicalizesIdAndClearsEnd() {
        val id = "ABCDEF12-0000-0000-0000-000000000000"
        val payload = actions(JSONObject().put("action", "update_countdown").put("id", "[id:${id.lowercase()}]").put("end", ""))
        val r = DeepSeekClient.parseCommandResult(payload, emptySet(), false, countdown = true, validCountdownIds = listOf(id)) as AICommandResult.Actions
        val op = (r.actions[0] as AIAction.Countdown).op as CountdownOp.Update
        assertEquals(id, op.id)
        assertTrue(op.change.clearEnd)
    }

    @Test(expected = DeepSeekException::class)
    fun countdownWhenDisabledIsUnknown() {
        DeepSeekClient.parseCommandResult(actions(JSONObject().put("action", "delete_countdown").put("id", "x")), emptySet(), false)
    }

    @Test
    fun assetCreateAndUpdate() {
        val payload = actions(
            JSONObject().put("action", "create_asset").put("title", "招行存款").put("category", "存款").put("value", "320,000"),
            JSONObject().put("action", "update_asset").put("id", "a1").put("liability", 2000000),
        )
        val r = DeepSeekClient.parseCommandResult(payload, emptySet(), false, assets = true, validAssetIds = listOf("a1")) as AICommandResult.Actions
        val create = (r.actions[0] as AIAction.Asset).op as AssetOp.Create
        assertEquals(320000.0, create.draft.value!!, 0.0)
        assertEquals("CNY", create.draft.currency)
        assertEquals(2000000.0, ((r.actions[1] as AIAction.Asset).op as AssetOp.Update).change.liability!!, 0.0)
    }

    @Test
    fun subscribeFeedExpandsList() {
        val payload = actions(JSONObject().put("action", "subscribe_feed").put("feeds", JSONArray()
            .put(JSONObject().put("url", "https://a.com"))
            .put(JSONObject().put("url", "https://A.com"))
            .put(JSONObject().put("name", "少数派").put("kind", "blog"))))
        val r = DeepSeekClient.parseCommandResult(payload, emptySet(), false, feeds = true) as AICommandResult.Actions
        assertEquals(2, r.actions.size)
        assertEquals("blog", ((r.actions[1] as AIAction.Feed).op as FeedOp.Subscribe).draft.kind)
    }

    @Test
    fun feedMatchScoresByName() {
        assertEquals(100, FeedMatch.score("Hacker News", "hackernews", ""))
        assertEquals(0, FeedMatch.score("新闻", "BBC 中文新闻网站首页", ""))
    }

    @Test
    fun tripPlanShiftsPastYearForward() {
        val raw = JSONObject().put("trip", "东京四日").put("start_date", "2025-11-10").put("end_date", "2025-11-13")
            .put("items", JSONArray().put(JSONObject().put("kind", "place").put("title", "浅草寺").put("start", "2025-11-10 10:00")))
        val plan = parseTripPlan(raw, LocalDateTime.of(2026, 7, 8, 9, 0))
        assertEquals(LocalDate.of(2026, 11, 10), plan.startDate)
        assertEquals(2026, plan.items[0].start!!.year)
    }

    @Test
    fun tripPlanRecordKeepsDates() {
        val raw = JSONObject().put("trip", "成都").put("start_date", "2025-11-10").put("end_date", "2025-11-11").put("record", true)
            .put("items", JSONArray().put(JSONObject().put("kind", "lodging").put("title", "亚朵")))
        assertEquals(2025, parseTripPlan(raw, LocalDateTime.of(2026, 7, 8, 9, 0)).startDate.year)
    }

    @Test(expected = DeepSeekException::class)
    fun tripPlanWithoutItemsThrows() {
        parseTripPlan(JSONObject().put("trip", "x").put("items", JSONArray()))
    }

    @Test
    fun tripEditRemovePrefixAndRemoveWins() {
        val raw = JSONObject().put("trip", "东京").put("remove", JSONArray(listOf("[id:a]", "a")))
            .put("update", JSONArray().put(JSONObject().put("id", "a").put("title", "改")))
        val edit = parseTripEdit(raw)
        assertEquals(listOf("a"), edit.removeIds)
        assertTrue(edit.updates.isEmpty())
    }

    /** 给已经记下的行程项补费用:update 里的 price/currency 要解析出来(原来整个被丢掉)。 */
    @Test
    fun tripEditUpdateCarriesPrice() {
        val raw = JSONObject().put("trip", "京都").put("update", JSONArray()
            .put(JSONObject().put("id", "[id:a]").put("price", 500).put("currency", "jpy"))
            .put(JSONObject().put("id", "b").put("price", "¥3,200")))
        val edit = parseTripEdit(raw)
        assertEquals(2, edit.updates.size)
        assertEquals(500.0, edit.updates[0].price!!, 0.0)
        assertEquals("JPY", edit.updates[0].currency)
        assertTrue(edit.updates[0].touchesOnlyCostOrNote)
        assertEquals(3200.0, edit.updates[1].price!!, 0.0)
    }

    /** 每晚价格按入住晚数乘成总价(同 iOS testResolvedPricePerNight)。 */
    @Test
    fun tripEditPricePerNightResolvesToTotal() {
        val edit = parseTripEdit(JSONObject().put("trip", "东京").put("update", JSONArray()
            .put(JSONObject().put("id", "h").put("price_per_night", "800").put("currency", "CNY"))))
        val u = edit.updates.single()
        val zone = java.time.ZoneId.systemDefault()
        val checkIn = java.time.LocalDateTime.of(2026, 7, 10, 15, 0).atZone(zone).toInstant().toEpochMilli()
        val checkOut = java.time.LocalDateTime.of(2026, 7, 13, 11, 0).atZone(zone).toInstant().toEpochMilli()
        assertEquals(2400.0, u.resolvedPrice(true, checkIn, checkOut)!!, 0.0)
        assertEquals(800.0, u.resolvedPrice(true, checkIn, null)!!, 0.0)
        assertEquals(800.0, u.resolvedPrice(false, checkIn, checkOut)!!, 0.0)
        assertEquals(2000.0, u.copy(price = 2000.0).resolvedPrice(true, checkIn, checkOut)!!, 0.0)
        assertTrue(u.touchesOnlyCostOrNote)
    }

    @Test
    fun planTripMixedWithCreateIsDropped() {
        val payload = actions(
            JSONObject().put("action", "create").put("title", "开会").put("remind_at", "2026-07-09 09:00"),
            JSONObject().put("action", "plan_trip").put("trip", "x").put("start_date", "2027-01-01").put("end_date", "2027-01-02")
                .put("items", JSONArray().put(JSONObject().put("kind", "place").put("title", "a"))),
        )
        val r = DeepSeekClient.parseCommandResult(payload, emptySet(), false, tripPlan = true) as AICommandResult.Actions
        assertEquals(1, r.actions.size)
        assertTrue(r.actions[0] is AIAction.Create)
    }

    @Test
    fun misdirectedUpdateBecomesCreate() {
        val original = ParsedTask("买牛奶", LocalDateTime.of(2026, 7, 9, 9, 0), false, 0, com.lodo.app.core.RepeatType.NONE, emptyList(), emptyList())
        val result = AICommandResult.Actions(listOf(AIAction.Update("u1", original.copy(title = "给妈妈打电话"))))
        val guarded = DeepSeekClient.guardMisdirectedUpdates(result, listOf("u1" to original), "改成4点吧") as AICommandResult.Actions
        assertTrue(guarded.actions[0] is AIAction.Create)
        val renamed = DeepSeekClient.guardMisdirectedUpdates(result, listOf("u1" to original), "把买牛奶改成给妈妈打电话") as AICommandResult.Actions
        assertTrue(renamed.actions[0] is AIAction.Update)
    }

    @Test
    fun autoMemorizeNeedsMemory() {
        val payload = actions(JSONObject().put("action", "auto_memorize").put("title", "贺卡").put("text", "班主任喜欢收到贺卡"))
        val r = DeepSeekClient.parseCommandResult(payload, emptySet(), false, memoryEnabled = true) as AICommandResult.Actions
        assertEquals(AIAction.AutoMemorize("贺卡", "班主任喜欢收到贺卡"), r.actions[0])
        try {
            DeepSeekClient.parseCommandResult(payload, emptySet(), false, memoryEnabled = false); fail()
        } catch (_: DeepSeekException) {}
    }
}
