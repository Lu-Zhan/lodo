import SwiftUI

/// 项目名 → 颜色的确定性映射,ProjectListView/ProjectTimelineView 共用。按项目名
/// 字符串手算哈希取调色板下标(不用 Hasher/hashValue——那个每次进程启动种子
/// 随机,同一项目名颜色会在两次打开 app 之间跳变)。浅色系,配合低透明度使用。
enum ProjectColor {
    static let palette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint]

    /// project 为 nil/空字符串(未分类)统一给灰色。
    static func color(for project: String?) -> Color {
        guard let project, !project.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .gray
        }
        let hash = project.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[hash % palette.count]
    }
}
