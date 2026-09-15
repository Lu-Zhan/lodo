import SwiftUI
import SwiftData
import LodoCore

/// 把订单/确认单文本丢给 AI,解析成若干行程项,**过一遍确认页**再落库。
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

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                if parsed.isEmpty {
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
                            .disabled(parsing || text.trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        confirmButton("写入行程") { commit() }
                            .disabled(picked.isEmpty)
                    }
                }
            }
            .onDisappear { parseTask?.cancel() }
        }
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
        .buttonStyle(.plain)
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
                    text: text, tripTitle: trip.title,
                    tripStart: trip.startDate, tripEnd: trip.endDate)
                guard !Task.isCancelled else { return }
                if items.isEmpty {
                    errorMessage = "没从这段文字里读出行程项。换一段更完整的订单内容试试,或者直接手动添加。"
                    return
                }
                parsed = items
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
            TravelStore.create(from: item, tripUUID: trip.uuid, context: context)
        }
        dismiss()
    }
}
