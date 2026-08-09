package com.lodo.app.core

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * 人脉关系图谱的确定性圆形布局,与 iOS ContactGraphLayout.circlePositions 对齐:
 * 不做力导向仿真,N 个节点均匀布在一个圆上,结果稳定可预测、可单测。纯
 * Kotlin/JVM,不依赖 Compose 的 Offset 类型,UI 层转换成自己的坐标类型。
 */
object ContactGraphLayout {
    /** 返回每个节点相对圆心 (0,0) 的 (x, y) 坐标,半径为 radius;从正上方开始
     * 顺时针均匀分布。count <= 0 返回空;count == 1 时该节点在圆心。 */
    fun circlePositions(count: Int, radius: Double): List<Pair<Double, Double>> {
        if (count <= 0) return emptyList()
        if (count == 1) return listOf(0.0 to 0.0)
        val step = 2 * PI / count
        return (0 until count).map { i ->
            val angle = -PI / 2 + i * step
            radius * cos(angle) to radius * sin(angle)
        }
    }
}
