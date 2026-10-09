import SwiftUI
import SwiftData
import LodoCore

/// 新闻的「阅读设置」:AI 总结用什么语言、正文字号、左右边距。新闻页右上角菜单和
/// 文章页右上角的「Aa」都打开它;改动即时生效(文章页开着时直接看到变化)。
struct NewsReadingSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.newsSummaryLanguageKey) private var summaryLanguageRaw = ""
    @AppStorage(AppSettings.newsDigestTimeKey) private var digestTime = "09:00"
    @AppStorage(AppSettings.newsFontSizeKey) private var fontSizeRaw = NewsFontSize.standard.rawValue
    @AppStorage(AppSettings.newsMarginKey) private var marginRaw = NewsMargin.standard.rawValue

    private var fontSize: NewsFontSize { NewsFontSize.stored(fontSizeRaw) }
    private var margin: NewsMargin { NewsMargin.stored(marginRaw) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("总结语言", selection: $summaryLanguageRaw) {
                        ForEach(NewsSummaryLanguage.allCases) { option in
                            Text(LocalizedStringKey(option.displayName)).tag(option.rawValue)
                        }
                    }
                } footer: {
                    Text("文章和新闻页的总结都用这种语言写。已经总结过的文章不会自动重写,可以在文章里点「重新总结」。")
                }

                Section {
                    DatePicker("每日总结时间", selection: Binding(
                        get: {
                            let parts = digestTime.split(separator: ":").compactMap { Int($0) }
                            return Calendar.current.date(bySettingHour: parts.count == 2 ? parts[0] : 9,
                                                         minute: parts.count == 2 ? parts[1] : 0,
                                                         second: 0, of: Date()) ?? Date()
                        },
                        set: { date in
                            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                            digestTime = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
                            RoutineRunner.refreshSchedule(context: context)
                        }), displayedComponents: .hourAndMinute)
                } footer: {
                    Text("每天到这个时间统一整理一览、各 RSS 来源和内容分类。系统若延迟后台运行,下次打开应用会补做。")
                }

                Section("字号") {
                    HStack(spacing: 12) {
                        Text("A").font(.footnote)
                        Slider(value: Binding(
                            get: { Double(fontSizeRaw) },
                            set: { fontSizeRaw = Int($0.rounded()) }),
                               in: 0...Double(NewsFontSize.allCases.count - 1), step: 1)
                        Text("A").font(.title2)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("字号")
                    .accessibilityValue(Text(LocalizedStringKey(fontSize.displayName)))
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: fontSizeRaw = min(fontSizeRaw + 1, NewsFontSize.allCases.count - 1)
                        case .decrement: fontSizeRaw = max(fontSizeRaw - 1, 0)
                        @unknown default: break
                        }
                    }
                }

                Section("边距") {
                    Picker("边距", selection: $marginRaw) {
                        ForEach(NewsMargin.allCases) { option in
                            Text(LocalizedStringKey(option.displayName)).tag(option.rawValue)
                        }
                    }
                    .segmentedPickerStyle()
                    .labelsHidden()
                    // 只要分段控件本身,不要它背后那块分组行底色。
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                Section("预览") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("苹果秋季发布会定档")
                            .font(.title3.weight(.bold))
                        Text("新 iPhone 与 Apple Watch 预计同场亮相,端侧 AI 是这次的重点。阅读页的正文会按这里的字号和边距排版。")
                            .font(.body)
                            .lineSpacing(7)
                    }
                    .dynamicTypeSize(fontSize.dynamicTypeSize)
                    .padding(.horizontal, margin.points - 4)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets())
                    .animation(.lodoAware(.snappy), value: fontSizeRaw)
                    .animation(.lodoAware(.snappy), value: marginRaw)
                }
            }
            .pageTitle("新闻设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

extension NewsFontSize {
    /// 阅读页整体套的 Dynamic Type 档位:「标准」= 系统默认的 .large。
    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: return .medium
        case .standard: return .large
        case .large: return .xLarge
        case .larger: return .xxLarge
        case .largest: return .xxxLarge
        }
    }
}
