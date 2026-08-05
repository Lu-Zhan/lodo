import SwiftUI
import LodoCore

/// 首次打开的引导:五页可左右滑动的介绍,系统原生分页控件(TabView + .page 样式),
/// 不自绘。冷启动(ContentView)与设置页"查看引导"共用同一个视图/同一份逻辑,
/// 不区分"第一次看"和"回看"——onFinish 都会把 hasSeenOnboarding 置 true
/// (回看时本来就已经是 true,重复置位是无害的空操作)。
struct OnboardingView: View {
    var onFinish: () -> Void

    @AppStorage(AppSettings.hasSeenOnboardingKey) private var hasSeenOnboarding = false
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let body: String
    }

    private let pages: [Page] = [
        Page(symbol: "sparkles",
             title: "欢迎使用 Lodo",
             body: "一个「纠缠式提醒」待办 app:到期后可以完成,也可以稍等——\n没处理掉的事项会按稍等间隔反复提醒,直到你真正完成。"),
        Page(symbol: "checklist",
             title: "到期就纠缠你",
             body: "到期提醒后完成或稍等都行,但不完成就会一直被提醒;\n带时长的事项分两阶段提醒「该开始了」和「完成了吗」,\n还支持每天/每周重复。"),
        Page(symbol: "sparkles.rectangle.stack",
             title: "AI 帮你整理收藏",
             body: "粘贴文字、链接或导入文件,AI 自动整理成记忆条目;\n还能记一笔资产、记一位人脉,人脉之间的关系还能看关系图谱。"),
        Page(symbol: "bubble.left.and.sparkles",
             title: "一句话搞定",
             body: "跟 AI 助手说一句话就能新建、修改、完成、删除事项,\n还能问它你收藏过的内容,或者看总览页给的今日处理建议。"),
        Page(symbol: "checkmark.circle",
             title: "开始使用",
             body: "以后想再看一遍这段介绍,去 设置 → 查看引导 就行。"),
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageContent(pages[index], isLast: index == pages.count - 1)
                        .tag(index)
                }
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            #endif

            if page < pages.count - 1 {
                Button("跳过") { finish() }
                    .padding()
            }
        }
    }

    private func pageContent(_ item: Page, isLast: Bool) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: item.symbol)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text(item.title)
                .font(.title.bold())
            Text(item.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            if isLast {
                Button("开始使用") { finish() }
                    .glassProminentButton()
            } else {
                Button("下一步") {
                    withAnimation { page += 1 }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.bottom, 48)
    }

    private func finish() {
        hasSeenOnboarding = true
        onFinish()
    }
}
