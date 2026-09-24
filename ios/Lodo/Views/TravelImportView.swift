import SwiftUI
import SwiftData
import PhotosUI
import LodoCore

/// 把订单/确认单文本和截图丢给 AI,解析成若干行程项,**过一遍确认页**再落库。
///
/// 截图(登机牌、航司 App 的航班动态、酒店确认页)在端上用 Vision OCR 成文字,
/// 和粘贴的文本拼在一起交给 AI,不上传图片本身。解析出来的航班如果行程里已经有
/// 同一班(`TravelStore.existingFlight`),确认后合并进那一条而不是再建一条——
/// 航班信息的"动态更新"就是再导入一张新截图。
///
/// 为什么单独给确认页:订单里的日期、金额认错了代价不小(照着错的时间去机场),
/// 不像单条待办那样撤销一下就完事。所以这条路径保留"AI 解析 → 用户逐条勾选 → 落库",
/// 不走"默认直接落库"那套。
struct TravelImportView: View {
    let trip: TravelTrip

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @State private var text = ""
    @State private var parsed: [ParsedTravelItem] = []
    @State private var picked: Set<UUID> = []
    @State private var parsing = false
    @State private var errorMessage: String?
    @State private var parseTask: Task<Void, Never>?
    @State private var photoItems: [PhotosPickerItem] = []
    /// 每张截图 OCR 出来的文字(按选择顺序);识别不出字的不进这里。
    @State private var screenshots: [Screenshot] = []
    @State private var recognizing = false
    /// 解析结果里哪些条目会合并进已有航班(parsed.id → 已有条目)。
    @State private var mergeTargets: [UUID: MemoryItem] = [:]

    /// 从某个航班详情页进来时,输入框上方提示"更新这一班"。
    var updatingFlightCode: String?

    private struct Screenshot: Identifiable {
        let id = UUID()
        let text: String
    }

    private var hasInput: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !screenshots.isEmpty
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                if parsed.isEmpty {
                    screenshotSection
                    Section {
                        TextEditor(text: $text)
                            .frame(minHeight: 160)
                            .overlay(alignment: .topLeading) {
                                if text.isEmpty {
                                    Text("把订票邮件、酒店确认信或行程单贴进来,AI 会拆成航班/住宿/地点。")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 8)
                                        .padding(.leading, 5)
                                        .allowsHitTesting(false)
                                }
                            }
                    } header: {
                        Text("订单内容")
                    } footer: {
                        Text("解析出来的每一条都会先让你过一眼,确认后才写进行程。")
                    }
                } else {
                    Section {
                        ForEach(parsed) { item in
                            row(item)
                        }
                    } header: {
                        Text("解析结果")
                    } footer: {
                        Text("取消勾选的不会写进行程。日期或金额不对的,先存下来再到行程里改。")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("从订单导入")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        parseTask?.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if parsed.isEmpty {
                        Button(parsing ? "解析中…" : "解析") { parse() }
                            .disabled(parsing || recognizing || !hasInput)
                    } else {
                        confirmButton("写入行程") { commit() }
                            .disabled(picked.isEmpty)
                    }
                }
            }
            .onDisappear { parseTask?.cancel() }
            .onChange(of: photoItems) { _, items in recognize(items) }
        }
    }

    // MARK: - 截图

    private var screenshotSection: some View {
        Section {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 6, matching: .images) {
                Label(screenshots.isEmpty ? "添加截图" : "重新选择截图", systemImage: "photo.on.rectangle")
            }
            .disabled(recognizing || parsing)
            if recognizing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在识别截图里的文字…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(screenshots.enumerated()), id: \.element.id) { index, shot in
                VStack(alignment: .leading, spacing: 2) {
                    Text("截图 \(index + 1)")
                        .font(.subheadline)
                    Text(shot.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .onDelete { offsets in screenshots.remove(atOffsets: offsets) }
        } header: {
            if let updatingFlightCode {
                Text("更新航班 \(updatingFlightCode)")
            } else {
                Text("截图")
            }
        } footer: {
            Text("登机牌、航司 App 的航班动态、订单详情页都可以。截图只在本机识别文字,不会上传图片;行程里已有的航班会用新信息更新。")
        }
    }

    /// 选好截图后逐张 OCR。重新选择时整体替换,不叠加(PhotosPicker 的选择本身就是全量的)。
    private func recognize(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        recognizing = true
        errorMessage = nil
        Task {
            defer { recognizing = false }
            var shots: [Screenshot] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let text = await ContentExtractor.recognizeText(imageData: data)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { shots.append(Screenshot(text: text)) }
            }
            screenshots = shots
            if shots.isEmpty {
                errorMessage = "没从截图里认出文字。换一张更清晰的截图,或者直接把文字贴进来。"
            }
        }
    }

    /// 发给 AI 的正文:粘贴的文本 + 每张截图的 OCR 结果,分段标清来源。
    private var combinedInput: String {
        var parts: [String] = []
        let pasted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pasted.isEmpty { parts.append(pasted) }
        for (index, shot) in screenshots.enumerated() {
            parts.append("【截图 \(index + 1) 识别出的文字】\n\(shot.text)")
        }
        return parts.joined(separator: "\n\n")
    }

    private func row(_ item: ParsedTravelItem) -> some View {
        Button {
            if picked.contains(item.id) { picked.remove(item.id) } else { picked.insert(item.id) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: picked.contains(item.id)
                      ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(picked.contains(item.id) ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Label(item.title, systemImage: item.kind.systemImage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if mergeTargets[item.id] != nil {
                        Label("更新行程里已有的这班航班", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                    if let flight = item.flight {
                        FlightInfoLine(flight: flight, planned: item.start, showsStatus: true)
                    }
                    if let detail = detailLine(item) {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let price = item.price {
                        Text("\(item.currency ?? "CNY") \(String(format: "%.2f", price))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .pressableCard()
    }

    private func detailLine(_ item: ParsedTravelItem) -> String? {
        var parts: [String] = []
        if let code = item.code { parts.append(code) }
        if let origin = item.originName, let place = item.placeName {
            parts.append("\(origin) → \(place)")
        } else if let place = item.placeName {
            parts.append(place)
        }
        if let start = item.start {
            var span = Self.formatter.string(from: start)
            if let end = item.end { span += " – " + Self.formatter.string(from: end) }
            parts.append(span)
        } else {
            parts.append("未排期")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func parse() {
        errorMessage = nil
        parsing = true
        parseTask = Task {
            defer { parsing = false }
            do {
                let items = try await DeepSeekClient.parseTravelItems(
                    text: combinedInput, tripTitle: trip.title,
                    tripStart: trip.startDate, tripEnd: trip.endDate)
                guard !Task.isCancelled else { return }
                if items.isEmpty {
                    errorMessage = "没从这段文字里读出行程项。换一段更完整的订单内容试试,或者直接手动添加。"
                    return
                }
                parsed = items
                let existing = TravelStore.items(for: trip.uuid, in: context)
                mergeTargets = Dictionary(uniqueKeysWithValues: items.compactMap { item in
                    TravelStore.existingFlight(for: item, in: existing).map { (item.id, $0) }
                })
                // 默认全选:AI 解析出来的通常都要,逐条勾更费事;不要的取消掉就行。
                picked = Set(items.map(\.id))
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commit() {
        for item in parsed where picked.contains(item.id) {
            if let target = mergeTargets[item.id], !target.isDeleted {
                TravelStore.merge(item, into: target, context: context)
            } else {
                TravelStore.create(from: item, tripUUID: trip.uuid, context: context)
            }
        }
        dismiss()
    }
}
