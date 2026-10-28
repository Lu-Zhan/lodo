#if os(iOS)
import LodoCore
import SwiftUI

/// 设置 →「lodo 键盘」→「常用词」:键盘打字时记下的词和整句(上屏过的,越常用越靠前),在这里删除、固定或清空。
///
/// 词存在键盘扩展自己的容器里,主 app 读不到;开了「允许完全访问」后键盘每次存盘把最常用的一千条导出到 App Group
/// (`KeyboardExchange.loadFrequentWords`)。这里的整理写成一份按编号递增的清单,键盘下次弹出时补做——
/// 没开完全访问时键盘照样读得到这份清单,只是导出不出来,所以这页是空的。
struct KeyboardFrequentWordsView: View {
    @AppStorage(KeyboardExchange.learnWordsKey, store: KeyboardExchange.shared) private var learnWords = true
    @State private var snapshot: KeyboardExchange.FrequentWordsSnapshot?
    @State private var words: [KeyboardExchange.FrequentWord] = []
    @State private var query = ""
    @State private var confirmClear = false
    @State private var edited = false

    private var filtered: [KeyboardExchange.FrequentWord] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return words }
        let compact = q.replacingOccurrences(of: " ", with: "")
        return words.filter {
            $0.word.contains(q) || $0.pinyin.replacingOccurrences(of: " ", with: "").hasPrefix(compact)
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("记住常用词", isOn: $learnWords)
            } footer: {
                Text("打字时选过的词和整句会记下来,下次排在前面;一个月不用,分量减半。关掉后不再记新的,已经记下的照常参与排序。只存在本机。")
            }

            if snapshot == nil {
                Section {
                    Text("在系统设置里给 lodo 键盘打开「允许完全访问」,再用它打几个字,记下的常用词就会出现在这里,可以删除或固定。")
                        .foregroundStyle(.secondary)
                }
            } else if words.isEmpty {
                Section {
                    Text(edited ? "已清空。下次弹出键盘时生效。" : "还没有记下常用词。")
                        .foregroundStyle(.secondary)
                }
            } else {
                let pinned = filtered.filter(\.pinned)
                let others = filtered.filter { !$0.pinned }
                if !pinned.isEmpty {
                    Section {
                        ForEach(pinned) { row($0) }
                    } header: {
                        Text("固定")
                    } footer: {
                        Text("固定的词不会随时间变淡,也不会因为词太多被清掉,一直排在最前面。")
                    }
                }
                Section {
                    ForEach(others) { row($0) }
                } header: {
                    Text("常用")
                } footer: {
                    footer
                }
                if query.isEmpty {
                    Section {
                        Button("清空全部常用词", role: .destructive) { confirmClear = true }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: Text("搜索词或拼音"))
        .pageTitle("常用词")
        .confirmationDialog("清空全部常用词?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { clearAll() }
        } message: {
            Text("键盘记下的词和整句(包括固定的)都会删掉,不能撤销。自定义短语和通讯录姓名不受影响。")
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private var footer: some View {
        if let snapshot {
            Text("左滑删除或固定。整理后下次弹出键盘时生效。键盘上次同步:") + Text(snapshot.exportedAt, format: .relative(presentation: .named))
        }
    }

    private func row(_ word: KeyboardExchange.FrequentWord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(word.word)
                if word.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("已固定"))
                }
            }
            Text(verbatim: word.pinyin)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            + Text(verbatim: " · ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            + Text("约 \(max(1, Int(word.weight.rounded()))) 次")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { forget(word) } label: { Label("删除", systemImage: "trash") }
            Button { togglePin(word) } label: {
                word.pinned ? Label("取消固定", systemImage: "pin.slash") : Label("固定", systemImage: "pin")
            }
            .tint(LodoColor.neutralAction)
        }
        .contextMenu {
            Button { togglePin(word) } label: {
                word.pinned ? Label("取消固定", systemImage: "pin.slash") : Label("固定", systemImage: "pin")
            }
            Button(role: .destructive) { forget(word) } label: { Label("删除", systemImage: "trash") }
        }
    }

    private func load() {
        #if DEBUG
        // 截图用:模拟器里跑不了第三方键盘,塞一份样板「键盘导出的常用词」。
        if ProcessInfo.processInfo.arguments.contains("--demo-frequent-words") {
            let day: TimeInterval = 24 * 3600
            KeyboardExchange.writeFrequentWords(.init(exportedAt: Date().addingTimeInterval(-600), words: [
                .init(word: "收到", pinyin: "shou dao", ids: [1, 2], weight: 42, lastUsed: Date(), pinned: true),
                .init(word: "我马上到", pinyin: "wo ma shang dao", ids: [3, 4, 5, 6], weight: 18.6, lastUsed: Date(), pinned: false),
                .init(word: "好的没问题", pinyin: "hao de mei wen ti", ids: [7, 8, 9, 10, 11], weight: 12.2, lastUsed: Date(), pinned: false),
                .init(word: "张一鸣", pinyin: "zhang yi ming", ids: [12, 13, 14], weight: 6.8, lastUsed: Date().addingTimeInterval(-3 * day), pinned: false),
                .init(word: "周末去爬山", pinyin: "zhou mo qu pa shan", ids: [15, 16, 17, 18, 19], weight: 2.4, lastUsed: Date().addingTimeInterval(-9 * day), pinned: false),
                .init(word: "下周三开会", pinyin: "xia zhou san kai hui", ids: [20, 21, 22, 23, 24], weight: 0.6, lastUsed: Date().addingTimeInterval(-40 * day), pinned: false),
            ], appliedSerial: 0))
        }
        #endif
        snapshot = KeyboardExchange.loadFrequentWords()
        guard let snapshot else { return words = [] }
        // 键盘还没做到的整理(这次打开前在这页上点的)先按清单补到显示上,免得删掉的又冒出来。
        var list = snapshot.words
        for edit in KeyboardExchange.pendingFrequentWordEdits(after: snapshot.appliedSerial) {
            switch edit.kind {
            case .forget: list.removeAll { $0.word == edit.word && $0.ids == edit.ids }
            case .pin, .unpin:
                if let i = list.firstIndex(where: { $0.word == edit.word && $0.ids == edit.ids }) {
                    list[i].pinned = edit.kind == .pin
                }
            case .clearAll: list = []
            }
        }
        words = Self.sorted(list)
    }

    private static func sorted(_ list: [KeyboardExchange.FrequentWord]) -> [KeyboardExchange.FrequentWord] {
        list.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return $0.word < $1.word
        }
    }

    private var applied: Int { snapshot?.appliedSerial ?? 0 }

    private func forget(_ word: KeyboardExchange.FrequentWord) {
        KeyboardExchange.appendFrequentWordEdit(.forget, word: word.word, ids: word.ids, applied: applied)
        words.removeAll { $0.id == word.id }
        edited = true
    }

    private func togglePin(_ word: KeyboardExchange.FrequentWord) {
        KeyboardExchange.appendFrequentWordEdit(word.pinned ? .unpin : .pin, word: word.word, ids: word.ids, applied: applied)
        if let i = words.firstIndex(where: { $0.id == word.id }) { words[i].pinned.toggle() }
        words = Self.sorted(words)
        edited = true
    }

    private func clearAll() {
        KeyboardExchange.appendFrequentWordEdit(.clearAll, applied: applied)
        words = []
        edited = true
    }
}
#endif
