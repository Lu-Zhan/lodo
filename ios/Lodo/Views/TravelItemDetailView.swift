import SwiftUI
import SwiftData
import MapKit
import LodoCore

/// 一条行程项的详情(住宿/地点/火车/客车;航班有自己的 `FlightStatusView`)。
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

    private var kind: TravelItemKind { item.travelKind ?? .place }

    private var coordinate: CLLocationCoordinate2D? {
        guard let lat = item.travelLatitude, let lon = item.travelLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var body: some View {
        NavigationStack {
            List {
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
                if let coordinate {
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
            .navigationTitle(item.title)
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
        }
    }

    @ViewBuilder
    private var timeRows: some View {
        // 名字跟着类型走:住宿是入住/退房,交通是出发/到达,地点就是开始/结束。
        if let start = item.travelStart {
            LabeledContent(startLabel, value: Self.formatter.string(from: start))
        }
        if let end = item.travelEnd {
            LabeledContent(endLabel, value: Self.formatter.string(from: end))
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

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEEE HH:mm"
        return f
    }()
}
