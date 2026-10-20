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

/// 身体档案:上传过的体重秤报告(体脂秤 app 的截图/PDF,含体重、体脂率等)。
/// 「上传身体档案」走体重管理同一个导入页(`WeightReportImportView`),核对后每次测量记成一条
/// `WeightRecord`,所以这里的内容就是体重管理里那条趋势的来源;最上面一行直接进体重管理。
/// 删报告(在条目详情里)不删已经记下的测量,同 `WeightReportStore`。
struct BodyArchiveView: View {
    let reports: [MemoryItem]
    let weightRecords: [WeightRecord]
    let healthWeights: [HealthDailyPoint]
    let healthSummary: String?
    let todayActiveEnergy: Double?

    @State private var importing = false

    private var entries: [WeightEntry] {
        WeightPlan.merge(records: weightRecords.map(\.entry), health: healthWeights)
    }

    var body: some View {
        List {
            Section {
                NavigationLink {
                    WeightManagementView(healthWeights: healthWeights, healthSummary: healthSummary,
                                         todayActiveEnergy: todayActiveEnergy)
                } label: {
                    Label("体重与饮食", systemImage: "scalemass")
                }
            } footer: {
                Text("上传的身体档案核对后会记进体重管理,体重、体脂率等变化在那里看。")
            }
            if reports.isEmpty {
                ContentUnavailableView {
                    Label("还没有身体档案", systemImage: "figure.stand")
                } description: {
                    Text("体脂秤 app 的测量详情、历史截图或导出的 PDF 都可以上传,体重、体脂率等读数核对后记进体重管理。")
                } actions: {
                    Button("上传身体档案") { importing = true }
                        .glassProminentButton()
                }
            } else {
                Section {
                    ForEach(reports) { item in
                        NavigationLink {
                            MemoryDetailView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Group {
                                    if item.title.isEmpty {
                                        Text("未命名")
                                    } else {
                                        Text(item.title)
                                    }
                                }
                                .font(.body.weight(.medium))
                                Text(caption(for: item))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .pageTitle("身体档案")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !reports.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        importing = true
                    } label: {
                        Label("上传身体档案", systemImage: "doc.badge.plus")
                    }
                }
            }
        }
        .sheet(isPresented: $importing) { WeightReportImportView(existing: entries) }
    }

    /// 「上传于 10月3日 · 3 次测量」。
    private func caption(for item: MemoryItem) -> String {
        let date = item.createdAt.formatted(.dateTime.month().day().locale(AppSettings.language.locale))
        let count = weightRecords.filter { $0.reportUUID == item.uuid }.count
        return count > 0
            ? String(localized: "上传于 \(date) · \(count) 次测量", bundle: .appLanguage(),
                     locale: AppSettings.language.locale)
            : String(localized: "上传于 \(date)", bundle: .appLanguage(), locale: AppSettings.language.locale)
    }
}
