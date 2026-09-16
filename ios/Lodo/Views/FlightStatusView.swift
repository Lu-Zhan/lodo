import SwiftUI
import SwiftData
import LodoCore

/// 航班行程项的详情:起降两端(机场/计划与预计时刻/航站楼/值机柜台/登机口/
/// 行李转盘)、座位舱位机型、状态。补充信息全部来自用户导入的订单文本和截图
/// (`FlightDetails`),**不联网查询**——所以状态会过期,页面上始终写明"更新于",
/// 想更新就再导入一张截图。
struct FlightStatusView: View {
    let item: MemoryItem
    let trip: TravelTrip

    @Environment(\.dismiss) private var dismiss

    @State private var editing = false
    @State private var importing = false

    private var flight: FlightDetails? { FlightDetails.decode(item.travelFlightData) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    header
                }
                departureSection
                arrivalSection
                if let flight, flight.seat != nil || flight.cabin != nil || flight.aircraft != nil {
                    Section("乘机") {
                        row("座位", flight.seat)
                        row("舱位", flight.cabin)
                        row("机型", flight.aircraft)
                    }
                }
                Section {
                    Button {
                        importing = true
                    } label: {
                        Label("导入截图更新", systemImage: "photo.badge.plus")
                    }
                } footer: {
                    if let updated = flight?.updatedAt {
                        Text("信息来自你导入的订单和截图,更新于 \(updated, format: .relative(presentation: .named))。不会自动刷新,请以航司和机场通知为准。")
                    } else {
                        Text("导入登机牌或航司 App 的航班动态截图,可以补上航站楼、登机口、座位等信息;之后再导入新截图会更新这一班。")
                    }
                }
            }
            .navigationTitle(item.travelCode ?? item.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") { editing = true }
                }
            }
            .sheet(isPresented: $editing) {
                TravelItemEditView(tripUUID: trip.uuid, existing: item)
            }
            .sheet(isPresented: $importing) {
                TravelImportView(trip: trip, updatingFlightCode: item.travelCode)
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.title3.weight(.semibold))
                    if let airline = flight?.airline {
                        Text(airline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let status = flight?.status {
                    FlightStatusBadge(status: status)
                }
            }
            HStack(alignment: .center) {
                endpointCode(flight?.departureCode, name: item.travelOriginName, alignment: .leading)
                Spacer()
                Image(systemName: "airplane")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
                endpointCode(flight?.arrivalCode, name: item.travelPlaceName, alignment: .trailing)
            }
            if let delay = flight?.departureDelayMinutes(planned: item.travelStart)
                ?? flight?.arrivalDelayMinutes(planned: item.travelEnd) {
                Label {
                    Text("晚点约 \(delay) 分钟")
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    /// 有三字码就大字显示三字码、下面小字地名;没有三字码就只显示地名。
    private func endpointCode(
        _ code: String?, name: String?, alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if let code {
                Text(code)
                    .font(.title.weight(.bold).monospaced())
                if let name, !name.isEmpty {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text(name.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            }
        }
    }

    // MARK: - 两端

    private var departureSection: some View {
        Section("出发") {
            row("机场", item.travelOriginName)
            timeRow("计划起飞", item.travelStart)
            estimatedRow("预计起飞", flight?.estimatedDeparture, planned: item.travelStart)
            row("航站楼", flight?.departureTerminal)
            row("值机柜台", flight?.checkInCounter)
            row("登机口", flight?.gate)
            timeRow("登机时间", flight?.boardingTime)
        }
    }

    private var arrivalSection: some View {
        Section("到达") {
            row("机场", item.travelPlaceName)
            timeRow("计划到达", item.travelEnd)
            estimatedRow("预计到达", flight?.estimatedArrival, planned: item.travelEnd)
            row("航站楼", flight?.arrivalTerminal)
            row("行李转盘", flight?.baggageBelt)
        }
    }

    /// 没有值的行整行不显示——截图上没拍到的信息不摆一排"未知"。
    @ViewBuilder
    private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title, value: value)
        }
    }

    @ViewBuilder
    private func timeRow(_ title: LocalizedStringKey, _ date: Date?) -> some View {
        if let date {
            LabeledContent(title) {
                Text(Self.formatter.string(from: date))
                    .monospacedDigit()
            }
        }
    }

    /// 预计时刻:晚于计划标橙色;和计划一样就不重复显示。
    @ViewBuilder
    private func estimatedRow(_ title: LocalizedStringKey, _ date: Date?, planned: Date?) -> some View {
        if let date, date != planned {
            let late = planned.map { date > $0 } ?? false
            LabeledContent(title) {
                Text(Self.formatter.string(from: date))
                    .monospacedDigit()
                    .foregroundStyle(late ? Color.orange : Color.primary)
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()
}

/// 航班状态小标签,行程列表行、导入确认页和详情页共用。
struct FlightStatusBadge: View {
    let status: FlightStatus

    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    var body: some View {
        Text(LocalizedStrings.text(status.titleKey, language: language))
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var color: Color {
        switch status.tone {
        case .neutral: return .secondary
        case .active: return .blue
        case .warning: return .orange
        case .critical: return .red
        case .done: return .green
        }
    }
}

/// 一行放得下的航班补充信息:"T3 · 值机 F01-F12 · 登机口 E23 · 座位 32A · 晚点 25 分钟"。
/// 拆成几段 Text 而不是先拼 String:拼好的字符串进不了字符串目录。
struct FlightInfoLine: View {
    let flight: FlightDetails
    /// 原计划起飞时刻,算晚点用。
    let planned: Date?
    /// 列表行已经有状态胶囊了,导入确认页没有,由它自己带上。
    var showsStatus = false

    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    var body: some View {
        let delay = flight.departureDelayMinutes(planned: planned)
        let pieces: [Text] = [
            flight.departureTerminal.map { Text(verbatim: $0) },
            flight.checkInCounter.map { Text("值机 \($0)") },
            flight.gate.map { Text("登机口 \($0)") },
            flight.seat.map { Text("座位 \($0)") },
            delay.map { Text("晚点 \($0) 分钟") },
            showsStatus
                ? flight.status.map { Text(LocalizedStrings.text($0.titleKey, language: language)) }
                : nil,
        ].compactMap { $0 }
        if let first = pieces.first {
            // 拼成一段 Text,放不下时自然换行而不是截断:登机口/座位被截掉就白导入了。
            pieces.dropFirst().reduce(first) { Text("\($0) · \($1)") }
                .font(.footnote)
                .foregroundStyle(delay != nil ? Color.orange : Color.secondary)
        }
    }
}
