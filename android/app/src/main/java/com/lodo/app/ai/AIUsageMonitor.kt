package com.lodo.app.ai

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.lodo.app.core.AIUsage
import com.lodo.app.core.AIUsageAccumulator

/**
 * 进程内的用量观察点(同 iOS AIUsageMonitor.shared,不持久化)。一轮的边界是 AgentViewModel.route
 * (`beginTurn` / `endTurn`),请求层(DeepSeekClient.command 那一路)报每次请求的增量和 usage。
 * `turn` 是 Compose 状态:只有标题那一行小字读它,数字每 0.25 秒跳一次不会牵动整条对话重组。
 */
object AIUsageMonitor {
    var turn by mutableStateOf<AIUsage?>(null)
        private set

    private val lock = Any()
    private var acc = AIUsageAccumulator()
    private var turnOpen = false
    private var implicitTurn = false

    private fun now() = System.currentTimeMillis()

    fun beginTurn() = synchronized(lock) {
        acc = AIUsageAccumulator()
        turnOpen = true
        implicitTurn = false
        // 不清 turn:新一轮还没数出东西之前留着上一轮的数字,免得这行小字闪一下。
    }

    fun endTurn() = synchronized(lock) {
        acc.endRequest(now())   // 中途抛错没走 endRequest 的,在这儿折进累计
        turnOpen = false
        implicitTurn = false
        publish()
    }

    fun beginRequest() = synchronized(lock) { openIfNeeded(); acc.beginRequest(now()) }

    fun noteDelta() = synchronized(lock) { openIfNeeded(); if (acc.markDelta(now())) publish() }

    fun report(input: Int?, output: Int?) = synchronized(lock) { openIfNeeded(); acc.report(input, output, now()) }

    fun endRequest() = synchronized(lock) {
        acc.endRequest(now())
        publish()
        if (implicitTurn) { turnOpen = false; implicitTurn = false }
    }

    fun discardRequest() = synchronized(lock) { acc.discardRequest() }

    private fun openIfNeeded() {
        if (turnOpen) return
        acc = AIUsageAccumulator(); turnOpen = true; implicitTurn = true
    }

    private fun publish() {
        val snap = acc.snapshot(now())
        if (snap.badge == null && turnOpen && turn != null) return
        turn = if (snap.badge == null) null else snap
    }
}
