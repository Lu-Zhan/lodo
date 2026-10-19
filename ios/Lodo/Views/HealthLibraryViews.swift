import SwiftUI
import SwiftData
import LodoCore

// 健康页「健康资料」推进去的两页:体检档案、健康记录。首页只剩两行入口 + 一个上传按钮,
// 长期档案不再和每天要做的事挤在同一条长列表里。

/// 体检档案:原来首页那一整组(本人、家人、上传报告、添加家人)原样搬进来。
/// 报告详情仍经 `HealthView` 根上的 `navigationDestination(item: $openReport)` 推进。
struct CheckupLibraryView: View {
    let memoryItems: [MemoryItem]
    @Binding var openReport: UUID?

    var body: some View {
        List {
            CheckupSection(memoryItems: memoryItems, openReport: $openReport)
        }
        .pageTitle("体检档案")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 健康记录:记忆库里打了「健康」标签的条目(病历、过敏、体检之外的资料),
/// 右上角「记一笔」= 记忆收藏的文字录入,整理完保底打上「健康」。
struct HealthMemoryListView: View {
    let items: [MemoryItem]
    @State private var composing = false

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("还没有健康记录", systemImage: "heart.text.square")
                } description: {
                    Text("病历、过敏、复查提醒这类资料可以记在这里,AI 健康分析时会一并参考。")
                } actions: {
                    Button("记一笔") { composing = true }
                        .glassProminentButton()
                }
                .emptyStateFill()
            } else {
                ForEach(items) { item in
                    NavigationLink {
                        MemoryDetailView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            // 分开写而不是三元:三元的两支都是 String,会挑到
                            // Text 的 verbatim 重载,"未命名"就进不了字符串目录。
                            Group {
                                if item.title.isEmpty {
                                    Text("未命名")
                                } else {
                                    Text(item.title)
                                }
                            }
                            .font(.body.weight(.medium))
                            if !item.summary.isEmpty {
                                Text(item.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .pageTitle("健康记录")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("记一笔") { composing = true }
                }
            }
        }
        .sheet(isPresented: $composing) {
            MemoryComposeView(presetTags: [MemoryItem.healthTagName])
        }
    }
}
