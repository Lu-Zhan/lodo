#if os(iOS)
import SwiftUI
import SwiftData
import LodoCore

/// 个人短语和多音姓名的手动读音。列表只保存在本机共享容器。
struct KeyboardPersonalWordsView: View {
    @Environment(\.modelContext) private var context
    @State private var words = KeyboardExchange.loadCustomWords()
    @State private var editingIndex: Int?
    @State private var phrase = ""
    @State private var pronunciation = ""
    @State private var showingEditor = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(words, id: \.self) { word in
                    Button {
                        editingIndex = words.firstIndex(of: word)
                        phrase = word.text
                        pronunciation = word.pinyin
                        showingEditor = true
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(word.text)
                            Text(word.pinyin).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let previous = words
                    words.remove(atOffsets: offsets)
                    if !persist() { words = previous }
                }
            } footer: {
                Text("可为多音姓名填写正确读音,用空格分隔每个音节。例如:单雄信 → shan xiong xin。")
            }
        }
        .pageTitle("自定义短语")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加", systemImage: "plus") {
                    editingIndex = nil
                    phrase = ""
                    pronunciation = ""
                    showingEditor = true
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            NavigationStack {
                Form {
                    TextField("短语或姓名", text: $phrase)
                    TextField("拼音,如 zhang san", text: $pronunciation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .navigationTitle(editingIndex == nil ? "添加短语" : "修改短语")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showingEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { saveEditor() }
                    }
                }
            }
        }
        .alert("自定义短语", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func saveEditor() {
        let word = pronunciation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? KeyboardExchange.PersonalWord(text: phrase)
            : KeyboardExchange.PersonalWord(text: phrase, pinyin: pronunciation)
        guard let word else {
            errorMessage = "请填写短语和有效拼音,每个音节用空格隔开"
            return
        }
        let previous = words
        if let editingIndex, words.indices.contains(editingIndex) { words[editingIndex] = word }
        else if !words.contains(word) { words.append(word) }
        if persist() { showingEditor = false }
        else { words = previous }
    }

    @discardableResult
    private func persist() -> Bool {
        guard KeyboardExchange.writeCustomWords(words) else {
            errorMessage = "保存短语失败"
            return false
        }
        KeyboardBridge.refresh(context: context)
        return true
    }
}
#endif
