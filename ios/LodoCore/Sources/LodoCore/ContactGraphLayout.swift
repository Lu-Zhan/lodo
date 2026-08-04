import Foundation

/// 关系图谱(ContactGraphView)的纯布局数学:不依赖 SwiftUI/Canvas,放 LodoCore
/// 才能脱离模拟器单测。用元组而不是 CGPoint,保持这个包"无 UI 依赖"的约束——
/// 调用处(app 层)自己转成 CGPoint。
public enum ContactGraphLayout {
    /// 把 count 个节点均匀摆在以 center 为圆心、radius 为半径的圆周上,从
    /// 12 点钟方向顺时针分布。count <= 1 时把唯一的节点(如果有)放在圆心,
    /// 不需要摆出一个圆——一个点谈不上"分布"。
    public static func circlePositions(
        count: Int, radius: Double, center: (x: Double, y: Double)
    ) -> [(x: Double, y: Double)] {
        guard count > 0 else { return [] }
        guard count > 1 else { return [center] }
        return (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count) - .pi / 2
            return (
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle)
            )
        }
    }
}
