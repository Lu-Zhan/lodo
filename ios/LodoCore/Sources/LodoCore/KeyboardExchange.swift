import Foundation

/// 主 app 与 lodo 键盘扩展之间的约定。扩展**只读快照、只写收件箱**,不碰数据库。
///
/// - 快照 `keyboard-snapshot.json`:主 app 回前台/进后台时写,给键盘的 ✨ 检索记忆用。
///   **只有记忆,不放任务**(键盘改不了已有任务,用不上);**隐私口径同 Spotlight**:资产、健康、
///   体检报告、体重秤报告一律不进(键盘跑在别的 app 里,快照不该带出 app 外面不能出现的东西)。
/// - 收件箱:任务写 `Keyboard/Tasks/<uuid>.json`(一个 `ParsedTask`),记忆写分享扩展同一个
///   `Memory/Inbox/<uuid>/meta.json`。主 app 消费完只删处理过的文件,目录留着。
/// - 设置:主 app 把 AI 服务商/模型/语言等镜像进 App Group 的 UserDefaults,扩展启动时
///   拷进自己的 standard——`AppSettings` 读的是 standard,这样 LodoCore 一行不用改。
public enum KeyboardExchange {
    public static let groupID = "group.com.lodo.app"
    public static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }
    public static var snapshotURL: URL? { root?.appending(path: "keyboard-snapshot.json") }
    public static var personalWordsURL: URL? { root?.appending(path: "keyboard-personal-words.json") }
    private static var importedContactWordsURL: URL? { root?.appending(path: "keyboard-imported-contacts.json") }
    private static var customWordsURL: URL? { root?.appending(path: "keyboard-custom-words.json") }
    public static var shared: UserDefaults? { UserDefaults(suiteName: groupID) }
    public static var taskInbox: URL? { directory("Keyboard/Tasks") }
    public static var memoryInbox: URL? { directory("Memory/Inbox") }

    private static func directory(_ path: String) -> URL? {
        guard let url = root?.appending(path: path) else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 快照

    public struct Memory: Codable, Equatable {
        public let uuid: String
        public let title: String
        public let summary: String
        public let tags: [String]
        public let excerpt: String
        public let createdAt: Date
        public init(uuid: String, title: String, summary: String, tags: [String], excerpt: String, createdAt: Date) {
            self.uuid = uuid; self.title = title; self.summary = summary; self.tags = tags
            self.excerpt = excerpt; self.createdAt = createdAt
        }
    }

    public struct Snapshot: Codable, Equatable {
        public var memories: [Memory]
        public init(memories: [Memory] = []) { self.memories = memories }
    }

    /// 快照里最多放这么多条记忆(按新近)。
    public static let memoryLimit = 500

    /// 这条记忆能不能进键盘快照。
    public static func isShareable(_ item: MemoryItem) -> Bool {
        !item.isAsset && !item.isHealth && !item.isCheckup && !item.isWeightReport
    }

    public static func loadSnapshot() -> Snapshot {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
        return snapshot
    }

    public static func write(_ snapshot: Snapshot) {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 键盘选词专用:只含姓名/短语与拼音,没有电话、邮箱、头像或备注。
    public struct PersonalWord: Codable, Hashable, Sendable {
        public let text: String
        public let pinyin: String
        public init?(text: String) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // ü 先换成引擎用的 v 再去声调:直接 stripDiacritics 会把「吕 lǚ」变成 lu,和「路」混在一起、打 lv 也搜不到。
            guard !value.isEmpty, value.count <= 24,
                  let latin = value.applyingTransform(.toLatin, reverse: false)
                    .map(Self.umlautToV)?
                    .applyingTransform(.stripDiacritics, reverse: false) else { return nil }
            let sounds = latin.lowercased().split(whereSeparator: { !$0.isASCII || !$0.isLetter })
            guard !sounds.isEmpty, sounds.count <= 8 else { return nil }
            self.text = value
            self.pinyin = sounds.joined(separator: " ")
        }
        public init?(text: String, pinyin: String) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let sounds = Self.umlautToV(pinyin.lowercased()).split(whereSeparator: { $0 == " " || $0 == "'" })
            guard !value.isEmpty, value.count <= 24, !sounds.isEmpty, sounds.count <= 8,
                  sounds.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isLetter } }) else { return nil }
            self.text = value
            self.pinyin = sounds.joined(separator: " ")
        }

        /// ü 和带声调的 ǖǘǚǜ(含大写)→ v。
        static func umlautToV(_ s: String) -> String {
            String(s.map { "üǖǘǚǜÜǕǗǙǛ".contains($0) ? "v" : $0 })
        }
    }

    private struct PersonalWordsSnapshot: Codable {
        let version: Int
        let words: [PersonalWord]
    }

    public static func loadImportedContactWords() -> [PersonalWord] {
        guard let url = importedContactWordsURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PersonalWord].self, from: data)) ?? []
    }

    public static func loadCustomWords() -> [PersonalWord] {
        guard let url = customWordsURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PersonalWord].self, from: data)) ?? []
    }

    @discardableResult
    public static func writeCustomWords(_ words: [PersonalWord]) -> Bool {
        guard let url = customWordsURL, let data = try? JSONEncoder().encode(words) else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    @discardableResult
    public static func writeImportedContactWords(_ words: [PersonalWord]) -> Bool {
        guard let url = importedContactWordsURL, let data = try? JSONEncoder().encode(words) else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }

    public static func writePersonalWords(_ words: [PersonalWord]) {
        guard let url = personalWordsURL else { return }
        let snapshot = PersonalWordsSnapshot(version: 1, words: Array(Set(words)).sorted {
            $0.text == $1.text ? $0.pinyin < $1.pinyin : $0.text < $1.text
        })
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - 收件箱

    @discardableResult
    public static func queueTask(_ task: ParsedTask) throws -> URL {
        guard let dir = taskInbox else { throw CocoaError(.fileNoSuchFile) }
        let url = dir.appending(path: "\(UUID().uuidString).json")
        try JSONEncoder().encode(task).write(to: url, options: .atomic)
        return url
    }

    /// `automatic` = AI 顺带记下的(收件箱 type "auto",打「AI记录」标签,不再整理一遍)。
    @discardableResult
    public static func queueMemory(text: String, title: String? = nil, automatic: Bool = false) throws -> URL {
        guard let inbox = memoryInbox else { throw CocoaError(.fileNoSuchFile) }
        let dir = inbox.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta = ["type": automatic && title != nil ? "auto" : "text", "text": text]
        if let title { meta["title"] = title }
        try JSONEncoder().encode(meta).write(to: dir.appending(path: "meta.json"), options: .atomic)
        return dir
    }

    /// 撤销:主 app 还没消费就删掉;已经入库了返回 false(那时只能去 lodo 里删)。
    @discardableResult
    public static func unqueue(_ url: URL) -> Bool {
        (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// 收件箱里还没被主 app 消费的任务。
    public static func pendingTasks() -> [(url: URL, task: ParsedTask)] {
        guard let dir = taskInbox,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let task = try? JSONDecoder().decode(ParsedTask.self, from: data) else { return nil }
            return (url, task)
        }
    }

    // MARK: - 强调色

    /// 主 app 写的强调色快照(`WidgetBridge.writeTheme`,`widget-theme.json`),键盘按它上色。
    /// fill/onFill 是后加的,老快照里没有时退回 accent / 白字。
    public struct Theme: Decodable, Equatable {
        public let accentLight: UInt32
        public let accentDark: UInt32
        public let fillLight: UInt32?
        public let fillDark: UInt32?
        public let onFillLight: UInt32?
        public let onFillDark: UInt32?
    }

    public static func loadTheme() -> Theme? {
        guard let url = root?.appending(path: "widget-theme.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Theme.self, from: data)
    }

    /// 键盘的「按键震动」开关(主 app 设置里改,默认开)。
    public static let hapticsKey = "keyboardHaptics"
    /// 中文键盘用九宫格(true)还是全键盘(默认)。存储值别改。
    public static let nineKeyKey = "keyboardNineKey"
    /// 震感:crisp 清脆(默认,短而干脆,接近系统键盘)/ standard 标准 / soft 柔和。存储值别改。
    public static let hapticsStyleKey = "keyboardHapticsStyle"
    public enum HapticsStyle: String, CaseIterable, Sendable {
        case crisp, standard, soft
    }
    public static func hapticsStyle(from raw: Any?) -> HapticsStyle {
        (raw as? String).flatMap(HapticsStyle.init(rawValue:)) ?? .crisp
    }
    /// 按键震动的强度(0.1…1.0,默认 0.6)。存储值别改。
    public static let hapticsIntensityKey = "keyboardHapticsIntensity"
    public static let defaultHapticsIntensity = 0.6
    public static let hapticsIntensityRange: ClosedRange<Double> = 0.1...1.0

    /// 读出来的强度:没存过、类型不对、不是有限数时用默认值,越界的夹回范围里。
    public static func hapticsIntensity(from raw: Any?) -> Double {
        guard let value = (raw as? NSNumber)?.doubleValue, value.isFinite else { return defaultHapticsIntensity }
        return min(max(value, hapticsIntensityRange.lowerBound), hapticsIntensityRange.upperBound)
    }

    /// 按键高度倍数(0.85…1.25,默认 1 = 照系统键盘量的高度)。只放大键帽,键缝行距不变。存储值别改。
    public static let keyHeightScaleKey = "keyboardKeyHeightScale"
    public static let defaultKeyHeightScale = 1.0
    public static let keyHeightScaleRange: ClosedRange<Double> = 0.85...1.25

    public static func keyHeightScale(from raw: Any?) -> Double {
        guard let value = (raw as? NSNumber)?.doubleValue, value.isFinite else { return defaultKeyHeightScale }
        return min(max(value, keyHeightScaleRange.lowerBound), keyHeightScaleRange.upperBound)
    }

    // MARK: - 常用词记忆(键盘学到的用户词,主 app「常用词」页整理)

    /// 上屏时学不学用户词(默认开)。存储值别改。
    public static let learnWordsKey = "keyboardLearnWords"

    /// 键盘学到的一条词。`ids` 是词库里的音节编号:主 app 没有词库,改动时原样带回去让键盘认。
    public struct FrequentWord: Codable, Hashable, Sendable, Identifiable {
        public let word: String
        public let pinyin: String
        public let ids: [Int]
        /// 按一个月半衰期折算后的使用次数。
        public let weight: Double
        public let lastUsed: Date
        public var pinned: Bool
        public var id: String { word + "|" + ids.map(String.init).joined(separator: ",") }
        public init(word: String, pinyin: String, ids: [Int], weight: Double, lastUsed: Date, pinned: Bool) {
            self.word = word; self.pinyin = pinyin; self.ids = ids
            self.weight = weight; self.lastUsed = lastUsed; self.pinned = pinned
        }
    }

    public struct FrequentWordsSnapshot: Codable, Sendable {
        public var exportedAt: Date
        public var words: [FrequentWord]
        /// 键盘已经处理到哪一条整理(见 `FrequentWordEdit.serial`)。
        public var appliedSerial: Int
        public init(exportedAt: Date, words: [FrequentWord], appliedSerial: Int) {
            self.exportedAt = exportedAt; self.words = words; self.appliedSerial = appliedSerial
        }
    }

    /// 主 app 里的一次整理。键盘写不了 App Group 时(没开完全访问)删不掉这份清单,
    /// 所以按递增编号只处理没处理过的——「清空」不能每次弹出都再清一遍。
    public struct FrequentWordEdit: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable { case forget, pin, unpin, clearAll }
        public let serial: Int
        public let kind: Kind
        public let word: String
        public let ids: [Int]
        public init(serial: Int, kind: Kind, word: String = "", ids: [Int] = []) {
            self.serial = serial; self.kind = kind; self.word = word; self.ids = ids
        }
    }

    /// 键盘导出的常用词(要开完全访问才写得进来),整理页只显示最常用的这么多条。
    public static let frequentWordsLimit = 1000
    private static var frequentWordsURL: URL? { root?.appending(path: "keyboard-frequent-words.json") }
    private static var frequentWordEditsURL: URL? { root?.appending(path: "keyboard-frequent-word-edits.json") }

    public static func loadFrequentWords() -> FrequentWordsSnapshot? {
        guard let url = frequentWordsURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FrequentWordsSnapshot.self, from: data)
    }

    @discardableResult
    public static func writeFrequentWords(_ snapshot: FrequentWordsSnapshot) -> Bool {
        guard let url = frequentWordsURL, let data = try? JSONEncoder().encode(snapshot) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    public static func loadFrequentWordEdits() -> [FrequentWordEdit] {
        guard let url = frequentWordEditsURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FrequentWordEdit].self, from: data)) ?? []
    }

    /// 追加一次整理(主 app 调)。键盘已经处理过的(编号不超过 `applied`)顺手丢掉,清单不会越攒越长。
    @discardableResult
    public static func appendFrequentWordEdit(_ kind: FrequentWordEdit.Kind, word: String = "", ids: [Int] = [],
                                              applied: Int) -> Bool {
        var edits = loadFrequentWordEdits().filter { $0.serial > applied }
        let serial = max(applied, loadFrequentWordEdits().map(\.serial).max() ?? 0) + 1
        if kind == .clearAll { edits = [] } // 清空之前的那些不用再做了
        edits.append(FrequentWordEdit(serial: serial, kind: kind, word: word, ids: ids))
        guard let url = frequentWordEditsURL, let data = try? JSONEncoder().encode(edits) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    /// 键盘侧:还没处理过的整理,按先后。
    public static func pendingFrequentWordEdits(after applied: Int) -> [FrequentWordEdit] {
        loadFrequentWordEdits().filter { $0.serial > applied }.sorted { $0.serial < $1.serial }
    }

    // MARK: - 设置镜像

    /// 键盘里 AI 键要用到的设置。思考强度不镜像:键盘里固定不思考(打字间隙等不起推理)。
    public static let mirroredKeys: [String] = [
        AppSettings.aiProviderKey, AppSettings.aiModelKey, AppSettings.aiCustomEndpointKey,
        AppSettings.useBuiltInKeyKey, AppSettings.agentPersonaStyleKey, AppSettings.agentPersonaCustomKey,
        AppSettings.languageKey,
    ]

    /// 键盘的模糊音开关(`FuzzyOptions.rawValue`),在主 app 设置里改,扩展读。
    public static let fuzzyKey = "keyboardFuzzy"
    public static let smartCorrectionKey = "keyboardSmartCorrection"

    public static func mirror(from source: UserDefaults, to target: UserDefaults) {
        for key in mirroredKeys {
            if let value = source.object(forKey: key) { target.set(value, forKey: key) }
            else { target.removeObject(forKey: key) }
        }
        for key in source.dictionaryRepresentation().keys where key.hasPrefix("agentSkillEnabled.") {
            target.set(source.object(forKey: key), forKey: key)
        }
    }

    /// 扩展启动时调:把主 app 镜像过来的设置拷进自己的 standard,并关掉思考。
    public static func adoptMirroredSettings(into standard: UserDefaults = .standard) {
        if let shared { mirror(from: shared, to: standard) }
        standard.set("off", forKey: AppSettings.thinkingLevelKey)
    }

    // MARK: - 在快照上检索记忆

    public static func retrieve(_ question: String, in snapshot: Snapshot) -> [Memory] {
        MemorySearch.rank(question: question, items: snapshot.memories.enumerated().map { index, m in
            (index: index, text: "\(m.title) \(m.summary) \(m.tags.joined(separator: " ")) \(m.excerpt)",
             createdAt: m.createdAt)
        }).map { snapshot.memories[$0] }
    }

    /// ReAct `search_memory` 的观察结果,格式和手机/手表逐字一致。
    public static func observation(for query: String, in snapshot: Snapshot) -> String {
        let found = retrieve(query, in: snapshot)
        guard !found.isEmpty else { return "没有找到相关记忆内容" }
        return found.map { "「\($0.title)」\($0.excerpt) [id:\($0.uuid)]" }.joined(separator: "\n")
    }
}
