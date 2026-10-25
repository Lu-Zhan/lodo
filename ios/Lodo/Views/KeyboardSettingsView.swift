#if os(iOS)
import LodoCore
import SwiftUI

/// 设置 → lodo 键盘:怎么启用、完全访问拿来做什么、按键震动、模糊音、致谢。
/// 教程放在这里而不是键盘里(HIG:别在键盘里放帮助内容)。
struct KeyboardSettingsView: View {
    @AppStorage(KeyboardExchange.fuzzyKey, store: KeyboardExchange.shared) private var fuzzyRaw = 0
    @AppStorage(KeyboardExchange.hapticsKey, store: KeyboardExchange.shared) private var haptics = true
    @AppStorage(KeyboardExchange.hapticsIntensityKey, store: KeyboardExchange.shared)
    private var hapticsIntensity = KeyboardExchange.defaultHapticsIntensity
    /// 和键盘里同一种震感(.soft),预览才对得上。
    @State private var preview = UIImpactFeedbackGenerator(style: .soft)
    @Environment(\.openURL) private var openURL

    /// 和 LodoIME 的 `FuzzyOptions` 位一一对应(主 app 不链接 LodoIME,这里按位写)。
    private static let fuzzyPairs: [(bit: Int, label: String)] = [
        (0, "z = zh"), (1, "c = ch"), (2, "s = sh"), (3, "n = l"),
        (4, "in = ing"), (5, "en = eng"), (6, "an = ang"),
    ]

    var body: some View {
        Form {
            Section {
                Label("打开「设置」→「通用」→「键盘」→「键盘」", systemImage: "1.circle")
                Label("点「添加新键盘…」,选「lodo」", systemImage: "2.circle")
                Label("想用 ✨ 问 lodo,再点进「lodo」打开「允许完全访问」", systemImage: "3.circle")
                Button("打开系统设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } header: {
                Text("启用")
            } footer: {
                Text("打字时在键盘左下角(或底部)的地球键切换到 lodo。")
            }

            Section {
                Label("不开也能正常打字,拼音和学到的词都只存在键盘自己那里。", systemImage: "keyboard")
                Label("✨:问 lodo 一个问题,答案可以直接插进正在写的地方。发给你在 lodo 里设置的 AI 服务的,只有你的问题、这次前面几轮对话,和从记忆里检索到的相关摘录;不发任务列表。", systemImage: "sparkles")
            } header: {
                Text("完全访问")
            } footer: {
                Text("归在健康、体检报告、体重秤报告、资产这几类的记忆不会给键盘;其他记忆里的相关摘录可能被用来回答。你打过的词只在本机用来调整候选顺序,不会上传。")
            }

            Section {
                Toggle("按键震动", isOn: $haptics)
                VStack(alignment: .leading) {
                    Text("震动强度")
                    Slider(value: Binding(
                        get: { KeyboardExchange.hapticsIntensity(from: hapticsIntensity) },
                        set: { hapticsIntensity = $0 }),
                           in: KeyboardExchange.hapticsIntensityRange, step: 0.05) {
                        Text("震动强度")
                    } minimumValueLabel: {
                        Text("轻")
                    } maximumValueLabel: {
                        Text("强")
                    } onEditingChanged: { editing in
                        if !editing { playPreview() } // 松手试一下,拖动途中不一直震
                    }
                    .accessibilityValue(Text(verbatim: "\(Int((KeyboardExchange.hapticsIntensity(from: hapticsIntensity) * 100).rounded()))%"))
                }
                .disabled(!haptics)
                Button("试一下", action: playPreview)
                    .disabled(!haptics)
            } footer: {
                Text("要开了「允许完全访问」才会震,不开也能正常打字;这里的预览不代表键盘已经拿到权限。下次弹出键盘时生效。键盘的颜色跟着这里选的强调色。")
            }

            Section {
                ForEach(Self.fuzzyPairs, id: \.bit) { pair in
                    Toggle(pair.label, isOn: Binding(
                        get: { fuzzyRaw & (1 << pair.bit) != 0 },
                        set: { fuzzyRaw = $0 ? fuzzyRaw | (1 << pair.bit) : fuzzyRaw & ~(1 << pair.bit) }))
                }
            } header: {
                Text("模糊音")
            } footer: {
                Text("分不清前后鼻音、平翘舌时打开对应的几项;下次弹出键盘时生效。")
            }

            Section {
                acknowledgement("拼音重排模型 chinese-ime-lm", "Apache-2.0。Trained on the Chinese portion of C4 (ODC-BY, https://huggingface.co/datasets/allenai/c4) and LCCC (MIT, https://github.com/thu-coai/CDial-GPT).")
                acknowledgement("AOSP 谷歌拼音词库", "Apache-2.0")
                acknowledgement("jieba 词典", "MIT")
                acknowledgement("mozillazg/pinyin-data、phrase-pinyin-data", "MIT")
            } header: {
                Text("致谢")
            }
        }
        .formStyle(.grouped)
        .pageTitle("lodo 键盘")
    }

    private func playPreview() {
        preview.impactOccurred(intensity: KeyboardExchange.hapticsIntensity(from: hapticsIntensity))
        preview.prepare()
    }

    private func acknowledgement(_ title: LocalizedStringKey, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(verbatim: detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
#endif
