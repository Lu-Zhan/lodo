package com.lodo.app.core

import java.util.Locale
import kotlin.math.roundToInt

/**
 * AI 助手标题行的 token 用量与速度,1:1 移植 iOS `AIUsage.swift`(时间由调用方传入毫秒,便于单测)。
 * 口径:整轮累计(一轮 = 一次 route,ReAct 最多 3 次请求);只统计 command;速度 = 累计输出 token /
 * 累计生成时长(每次请求"第一片增量 → 请求结束",刻意不用整轮墙钟);有 usage 用精确值,没有退回
 * 按增量分片计数的估算,估算态打 ≈ 且只报输出。
 */
data class AIUsage(
    val inputTokens: Int? = null,
    val outputTokens: Int = 0,
    val isEstimated: Boolean = true,
    val generatingSeconds: Double = 0.0,
    val requests: Int = 0,
    val isStreaming: Boolean = false,
) {
    val tokensPerSecond: Double?
        get() = if (outputTokens > 0 && generatingSeconds >= MIN_SPEED_WINDOW) outputTokens / generatingSeconds else null

    /** 「↑1.2k ↓300 · 42 tok/s」;进行中只报速度(输入要等最后那片 usage)。 */
    val badge: String?
        get() {
            val parts = mutableListOf<String>()
            if (!isStreaming && outputTokens > 0) {
                parts += if (inputTokens != null && !isEstimated) "↑${formatCount(inputTokens)} ↓${formatCount(outputTokens)}"
                else "↓≈${formatCount(outputTokens)}"
            }
            tokensPerSecond?.let { parts += "${it.roundToInt()} tok/s" }
            return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
        }

    companion object {
        const val MIN_SPEED_WINDOW = 0.2

        fun formatCount(value: Int): String {
            if (value < 1000) return "$value"
            if (value >= 10_000) return "${(value + 500) / 1000}k"
            val text = String.format(Locale.ROOT, "%.1f", value / 1000.0)
            return (if (text.endsWith(".0")) text.dropLast(2) else text) + "k"
        }
    }
}

class AIUsageAccumulator {
    private var exactInput: Int? = null
    private var exactOutput = 0
    private var estimatedOutput = 0
    private var missingExact = false
    private var generatingSeconds = 0.0
    private var requests = 0

    private var requestStart: Long? = null
    private var requestFirstDelta: Long? = null
    private var requestDeltas = 0
    private var requestInput: Int? = null
    private var requestOutput: Int? = null
    private var lastPublish: Long? = null

    fun beginRequest(now: Long) { if (requestStart == null) requestStart = now }

    /** 记一片增量;返回要不要刷新界面(0.25 秒节流)。 */
    fun markDelta(now: Long): Boolean {
        if (requestStart == null) requestStart = now
        if (requestFirstDelta == null) requestFirstDelta = now
        requestDeltas++
        val last = lastPublish
        if (last != null && now - last < PUBLISH_INTERVAL_MS) return false
        lastPublish = now
        return true
    }

    fun report(inputTokens: Int?, outputTokens: Int?, now: Long) {
        if (requestStart == null) requestStart = now
        inputTokens?.let { requestInput = it }
        outputTokens?.let { requestOutput = it }
    }

    fun endRequest(now: Long) {
        val start = requestStart ?: return
        val output = requestOutput
        if (output != null) {
            exactOutput += output
            requestInput?.let { exactInput = (exactInput ?: 0) + it }
        } else {
            estimatedOutput += requestDeltas
            missingExact = true
        }
        generatingSeconds += maxOf(0L, now - (requestFirstDelta ?: start)) / 1000.0
        requests++
        clear()
    }

    fun discardRequest() = clear()

    private fun clear() {
        requestStart = null; requestFirstDelta = null; requestDeltas = 0; requestInput = null; requestOutput = null
    }

    fun snapshot(now: Long): AIUsage {
        var output = exactOutput + estimatedOutput
        var seconds = generatingSeconds
        var estimated = missingExact
        val start = requestStart
        if (start != null) {
            output += requestOutput ?: requestDeltas
            if (requestOutput == null && requestDeltas > 0) estimated = true
            val first = requestFirstDelta
            if (first != null) seconds += maxOf(0L, now - first) / 1000.0
            else if (requestOutput != null) seconds += maxOf(0L, now - start) / 1000.0
        }
        return AIUsage(exactInput, output, estimated, seconds, requests, start != null)
    }

    companion object { const val PUBLISH_INTERVAL_MS = 250L }
}
