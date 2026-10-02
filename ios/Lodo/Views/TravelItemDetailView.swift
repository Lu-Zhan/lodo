import SwiftUI
import SwiftData
import MapKit
import LodoCore

/// 一条行程项的详情(住宿/地点/火车/客车;航班有自己的 `FlightStatusView`)。
/// 火车/客车的时刻按两端**当地时间**显示,另有一段车票信息(检票口/站台/车厢/座位)。
///
/// 按天那一页的行只剩标题 + 一行摘要——要的是密度,一眼扫完一天有几件事;
/// 展开的信息落在这里,**备注放在第一个 section**:那是用户自己写下/AI 记下的
/// "这地方怎么玩、怎么过去",比时间地点更需要一眼看到。
struct TravelItemDetailView: View {
    let item: MemoryItem
    let trip: TravelTrip

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @State private var editing = false

    /// 嵌在旅行详情宽屏布局的右栏(inspector)里时传入:「完成」换成关闭这一栏,
    /// 而不是 dismiss(那会把整个旅行详情页退掉)。nil = 作为 sheet 弹出。
    private let onClose: (() -> Void)?

    init(item: MemoryItem, trip: TravelTrip, onClose: (() -> Void)? = nil) {
        self.item = item
        self.trip = trip
        self.onClose = onClose
    }

    private var kind: TravelItemKind { item.travelKind ?? .place }
    private var details: FlightDetails? {
        kind.isTransport ? FlightDetails.decode(item.travelFlightData) : nil
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = item.travelLatitude, let lon = item.travelLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        // 嵌在右栏时不再自带 NavigationStack:旅行详情页本身就是外层 NavigationStack 的
        // 目标页,里面再套一层会让 macOS 把外层的导航路径重置、直接退回旅行列表(实测)。
        // 也不设 navigationTitle——那会顶掉窗口标题上的旅行名,标题改放在列表顶上。
        if onClose != nil {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
            List {
                if onClose != nil {
                    Section {
                        Text(item.title)
                            .font(.title3.weight(.semibold))
                    }
                }
                if !item.summary.isEmpty {
                    Section("备注") {
                        Text(item.summary)
                    }
                }
                Section {
                    LabeledContent("类型") {
                        Label(LocalizedStrings.text(kind.titleKey, language: language),
                              systemImage: kind.systemImage)
                    }
                    if let code = item.travelCode, !code.isEmpty {
                        LabeledContent(kind.isTransport ? "车次/航班号" : "订单号", value: code)
                    }
                    timeRows
                    placeRows
                    if let price = item.travelPrice, price != 0 {
                        LabeledContent("价格") {
                            Text("\(item.travelCurrencyOrDefault) \(String(format: "%.2f", price))")
                                .font(.body.monospacedDigit())
                        }
                    }
                }
                ticketSection
                // 右栏里不再放小地图:正中那一栏就是地图,已经选中并飞到这个点了。
                if let coordinate, onClose == nil {
                    Section {
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))) {
                            Marker(item.travelPlaceName ?? item.title,
                                   systemImage: kind.systemImage, coordinate: coordinate)
                        }
                        .frame(height: 180)
                        .listRowInsets(EdgeInsets())
                    }
                }
                if !item.attachmentRelativePaths.isEmpty {
                    Section("附件") {
                        ForEach(item.attachmentRelativePaths, id: \.self) { path in
                            Label((path as NSString).lastPathComponent, systemImage: "paperclip")
                                .font(.subheadline)
                        }
                    }
                }
            }
            .navigationTitleIfPresent(onClose == nil ? item.title : nil)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let onClose {
                        Button(action: onClose) {
                            Label("关闭", systemImage: "xmark")
                        }
                    } else {
                        Button("完成") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") { editing = true }
                }
            }
            .sheet(isPresented: $editing) {
                TravelItemEditView(tripUUID: trip.uuid, existing: item)
            }
    }

    @ViewBuilder
    private var timeRows: some View {
        // 名字跟着类型走:住宿是入住/退房,交通是出发/到达,地点就是开始/结束。
        if let start = item.travelStart {
            LabeledContent(startLabel, value: LocalizedContent.dateAndWeekdayTime(
                start, language: language, timeZone: details?.departureZone))
        }
        if let zone = details?.departureZone {
            LabeledContent("出发地时区", value: LocalizedContent.timeZoneName(zone, language: language))
        }
        if let end = item.travelEnd {
            LabeledContent(endLabel, value: LocalizedContent.dateAndWeekdayTime(
                end, language: language, timeZone: details?.arrivalZone))
        }
        if let zone = details?.arrivalZone {
            LabeledContent("到达地时区", value: LocalizedContent.timeZoneName(zone, language: language))
        }
        if kind.isTransport,
           let minutes = FlightDetails.durationMinutes(start: item.travelStart, end: item.travelEnd) {
            LabeledContent("行程时长", value: CountdownText.durationText(minutes))
        }
    }

    /// 火车/客车的车票信息;一项都没填时整段不显示。
    @ViewBuilder
    private var ticketSection: some View {
        if let details, kind == .train || kind == .coach {
            let values = kind == .train
                ? [details.gate, details.platform, details.carriage, details.seat, details.cabin]
                : [details.gate, details.platform, details.seat]
            if values.contains(where: { !($0 ?? "").isEmpty }) {
                Section {
                    ticketRow("检票口", details.gate)
                    ticketRow(LocalizedStringKey(kind == .train ? "站台" : "上车点"), details.platform)
                    if kind == .train { ticketRow("车厢", details.carriage) }
                    ticketRow("座位", details.seat)
                    if kind == .train { ticketRow("座席", details.cabin) }
                } header: {
                    Label(LocalizedStringKey(kind == .train ? "火车信息" : "客车信息"),
                          systemImage: kind.systemImage)
                }
            }
        }
    }

    @ViewBuilder
    private func ticketRow(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title, value: value)
        }
    }

    private var startLabel: LocalizedStringKey {
        switch kind {
        case .lodging: return "入住"
        case .flight, .train, .coach: return "出发"
        case .place: return "开始时间"
        }
    }

    private var endLabel: LocalizedStringKey {
        switch kind {
        case .lodging: return "退房"
        case .flight, .train, .coach: return "到达"
        case .place: return "结束时间"
        }
    }

    @ViewBuilder
    private var placeRows: some View {
        if kind.isTransport, let origin = item.travelOriginName, !origin.isEmpty {
            LabeledContent("出发地", value: origin)
        }
        if let place = item.travelPlaceName, !place.isEmpty {
            LabeledContent(kind.isTransport ? "到达地" : "地点", value: place)
        }
    }

}
