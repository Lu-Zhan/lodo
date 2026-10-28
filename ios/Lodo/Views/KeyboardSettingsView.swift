#if os(iOS)
import LodoCore
import SwiftUI
import SwiftData

/// 设置 → lodo 键盘:怎么启用、完全访问拿来做什么、按键震动、模糊音、致谢。
/// 教程放在这里而不是键盘里(HIG:别在键盘里放帮助内容)。
struct KeyboardSettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var importMessage: String?
    @AppStorage(KeyboardExchange.fuzzyKey, store: KeyboardExchange.shared) private var fuzzyRaw = 0
    @AppStorage(KeyboardExchange.smartCorrectionKey, store: KeyboardExchange.shared) private var smartCorrection = true
    @AppStorage(KeyboardExchange.hapticsKey, store: KeyboardExchange.shared) private var haptics = true
    @AppStorage(KeyboardExchange.nineKeyKey, store: KeyboardExchange.shared) private var nineKey = false
    @AppStorage(KeyboardExchange.hapticsIntensityKey, store: KeyboardExchange.shared)
    private var hapticsIntensity = KeyboardExchange.defaultHapticsIntensity
    @AppStorage(KeyboardExchange.keyHeightScaleKey, store: KeyboardExchange.shared)
    private var keyHeightScale = KeyboardExchange.defaultKeyHeightScale
    @AppStorage(KeyboardExchange.hapticsStyleKey, store: KeyboardExchange.shared)
    private var hapticsStyleRaw = KeyboardExchange.HapticsStyle.crisp.rawValue

    /// 和键盘里同一套映射,预览才对得上。
    private var previewStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch KeyboardExchange.hapticsStyle(from: hapticsStyleRaw) {
        case .crisp: .rigid
        case .standard: .light
        case .soft: .soft
        }
    }
    @Environment(\.openURL) private var openURL

    /// 和 LodoIME 的 `FuzzyOptions` 位一一对应(主 app 不链接 LodoIME,这里按位写)。
    private static let fuzzyPairs: [(bit: Int, label: String)] = [
        (0, "z = zh"), (1, "c = ch"), (2, "s = sh"), (3, "n = l"),
        (4, "in = ing"), (5, "en = eng"), (6, "an = ang"),
    ]

    private static let keyHeightSection = "keyHeight"
    #if DEBUG
    @State private var demoFrequentWords = false
    #endif

    var body: some View {
        ScrollViewReader { proxy in
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
                Picker("中文键盘", selection: $nineKey) {
                    Text("全键盘").tag(false)
                    Text("九宫格").tag(true)
                }
                .segmentedPickerStyle()
            } footer: {
                Text("九宫格:按数字键打拼音,左边那列可以选拼音、没在打字时是常用标点;英文和数字符号仍是全键盘。下次弹出键盘时生效。")
            }

            Section {
                KeyboardSizePreview(scale: KeyboardExchange.keyHeightScale(from: keyHeightScale))
                    .padding(.vertical, 6)
                VStack(alignment: .leading) {
                    Text("按键高度")
                    Slider(value: Binding(
                        get: { KeyboardExchange.keyHeightScale(from: keyHeightScale) },
                        set: { keyHeightScale = $0 }),
                           in: KeyboardExchange.keyHeightScaleRange, step: 0.05) {
                        Text("按键高度")
                    } minimumValueLabel: {
                        Text("矮")
                    } maximumValueLabel: {
                        Text("高")
                    }
                    .accessibilityValue(Text(verbatim: "\(Int((KeyboardExchange.keyHeightScale(from: keyHeightScale) * 100).rounded()))%"))
                }
                if abs(KeyboardExchange.keyHeightScale(from: keyHeightScale) - KeyboardExchange.defaultKeyHeightScale) > 0.001 {
                    Button("恢复默认高度") { keyHeightScale = KeyboardExchange.defaultKeyHeightScale }
                }
            } footer: {
                Text("只改按键本身的高度,候选栏和按键间距不变;默认和系统键盘一样高。下次弹出键盘时生效。")
            }
            .id(Self.keyHeightSection)

            Section {
                Toggle("按键震动", isOn: $haptics)
                Picker("震感", selection: $hapticsStyleRaw) {
                    Text("清脆").tag(KeyboardExchange.HapticsStyle.crisp.rawValue)
                    Text("标准").tag(KeyboardExchange.HapticsStyle.standard.rawValue)
                    Text("柔和").tag(KeyboardExchange.HapticsStyle.soft.rawValue)
                }
                .disabled(!haptics)
                .onChange(of: hapticsStyleRaw) { playPreview() }
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
                Toggle("智能纠错", isOn: $smartCorrection)
            } footer: {
                Text("漏敲一个拼音元音时尝试找回完整词句,例如 nihaya → 你好呀。下次弹出键盘时生效。")
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
                NavigationLink("常用词") { KeyboardFrequentWordsView() }
                NavigationLink("自定义短语与读音") { KeyboardPersonalWordsView() }
                Button("导入通讯录姓名") {
                    Task {
                        guard case .granted = await ContactsBridge.requestAccess() else {
                            importMessage = "没有通讯录访问权限"
                            return
                        }
                        let imported = await Task.detached(priority: .utility) { () -> Int? in
                            guard let names = ContactsBridge.fetchKeyboardNames() else { return nil }
                            let words = names.compactMap(KeyboardExchange.PersonalWord.init(text:))
                            return KeyboardExchange.writeImportedContactWords(words) ? words.count : -1
                        }.value
                        guard let imported else {
                            importMessage = "读取通讯录失败,请稍后再试"
                            return
                        }
                        guard imported >= 0 else {
                            importMessage = "保存姓名词库失败"
                            return
                        }
                        KeyboardBridge.refresh(context: context)
                        importMessage = "已导入\(imported)个姓名或昵称"
                    }
                }
                Button("清除已导入的通讯录姓名", role: .destructive) {
                    guard KeyboardExchange.writeImportedContactWords([]) else {
                        importMessage = "清除姓名词库失败"
                        return
                    }
                    KeyboardBridge.refresh(context: context)
                    importMessage = "已清除通讯录姓名"
                }
            } header: {
                Text("人名词库")
            } footer: {
                Text("lodo 人脉的姓名和昵称会自动用于键盘候选。通讯录姓名为一次性导入,再次点击可更新;只保存姓名和拼音。")
            }

            Section {
                acknowledgement("拼音重排模型 chinese-ime-lm", "Apache-2.0。Trained on the Chinese portion of C4 (ODC-BY, https://huggingface.co/datasets/allenai/c4) and LCCC (MIT, https://github.com/thu-coai/CDial-GPT).")
                acknowledgement("AOSP 谷歌拼音词库", "Apache-2.0")
                acknowledgement("jieba 词典", "MIT")
                acknowledgement("mozillazg/pinyin-data、phrase-pinyin-data", "MIT")
                acknowledgement("通用规范汉字表字表(jaywcjlove 整理)", "MIT")
            } header: {
                Text("致谢")
            }
        }
        .formStyle(.grouped)
        #if DEBUG
        // 截图核对按键高度示意图:`--demo-key-height <倍数>` 设好值并滚到那一组。
        .navigationDestination(isPresented: $demoFrequentWords) { KeyboardFrequentWordsView() }
        .onAppear {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--demo-frequent-words") { demoFrequentWords = true } // 直接推到「常用词」
            guard let i = args.firstIndex(of: "--demo-key-height"), args.indices.contains(i + 1),
                  let value = Double(args[i + 1]) else { return }
            keyHeightScale = value
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(Self.keyHeightSection, anchor: .top) }
        }
        #endif
        }
        .pageTitle("lodo 键盘")
        .alert("人名词库", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("好", role: .cancel) { importMessage = nil }
        } message: {
            Text(importMessage ?? "")
        }
    }

    private func playPreview() {
        let generator = UIImpactFeedbackGenerator(style: previewStyle)
        generator.impactOccurred(intensity: KeyboardExchange.hapticsIntensity(from: hapticsIntensity))
    }

    private func acknowledgement(_ title: LocalizedStringKey, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(verbatim: detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
#endif
