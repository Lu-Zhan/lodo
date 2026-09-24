import SwiftUI
import SwiftData
import MapKit
import LodoCore

/// 行程项的新建/编辑表单(航班/住宿/地点共用一张表,按类型显示不同字段)。
/// 和资产/人脉一样是结构化表单直接落库,不经 AI 整理。
struct TravelItemEditView: View {
    let tripUUID: UUID
    /// nil = 新建。
    var existing: MemoryItem?
    /// 新建时表单里时间的默认落点(从某一天进来就默认那天)。
    var defaultDate: Date = .now

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @State private var kind: TravelItemKind = .place
    @State private var title = ""
    @State private var code = ""
    @State private var note = ""
    @State private var hasStart = false
    @State private var start = Date()
    @State private var hasEnd = false
    @State private var end = Date()
    @State private var priceText = ""
    @State private var currency = AppSettings.assetDisplayCurrency
    @State private var placeName = ""
    @State private var placeCoordinate: CLLocationCoordinate2D?
    @State private var originName = ""
    @State private var originCoordinate: CLLocationCoordinate2D?
    @State private var searching: SearchTarget?
    @State private var didLoad = false
    /// 已存的航班补充信息(多半来自导入的截图)。表单只露出最常手改的几项,
    /// 其余字段(状态、预计时刻、三字码…)保存时原样带回去。
    @State private var flight: FlightDetails?
    /// 打开表单时的航班号;改成别的航班号时,截图里带来的那些字段就不属于这一班了。
    @State private var loadedCode = ""
    @State private var departureTerminal = ""
    @State private var arrivalTerminal = ""
    @State private var checkInCounter = ""
    @State private var gate = ""
    @State private var seat = ""
    @State private var aircraft = ""

    private enum SearchTarget: Identifiable {
        case place, origin
        var id: Int { self == .place ? 0 : 1 }
    }

    private var trimmedPriceText: String { priceText.trimmingCharacters(in: .whitespaces) }
    private var price: Double? { Double(trimmedPriceText) }

    /// 金额框非空但解析不出数字时挡住保存,不能悄悄当空值存掉
    /// (和 AssetComposeView 同一个处理)。
    private var hasInvalidPrice: Bool { !trimmedPriceText.isEmpty && price == nil }

    /// 起讫时间都填了却是倒着的,存下去会让按天视图铺出一段负的区间。
    private var hasInvalidRange: Bool { hasStart && hasEnd && end < start }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasInvalidPrice && !hasInvalidRange
    }

    private var titlePrompt: LocalizedStringKey {
        switch kind {
        case .flight: return "航空公司/航段,如 国航 北京–东京"
        case .lodging: return "住宿名称,如 新宿王子酒店"
        case .place: return "地点名称,如 浅草寺"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(TravelItemKind.allCases, id: \.self) { kind in
                            Label(LocalizedStrings.text(kind.titleKey, language: language),
                                  systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    TextField(titlePrompt, text: $title)
                    TextField(kind == .flight ? "航班号(可选)" : "订单号/房号(可选)", text: $code)
                }

                Section {
                    if kind == .flight {
                        placeRow(title: "出发地", name: $originName,
                                 coordinate: $originCoordinate, target: .origin)
                    }
                    placeRow(title: kind == .flight ? "到达地" : "地点",
                             name: $placeName, coordinate: $placeCoordinate, target: .place)
                } footer: {
                    Text("点「搜索」选地点才会记下坐标,地图上才画得出这个点;只手打名字也能存,只是不上地图。")
                }

                Section {
                    Toggle(kind == .flight ? "起飞时间" : (kind == .lodging ? "入住" : "开始时间"),
                           isOn: $hasStart)
                    if hasStart {
                        DatePicker("", selection: $start)
                            .labelsHidden()
                            #if os(iOS)
                            .datePickerStyle(.compact)
                            #endif
                    }
                    Toggle(kind == .flight ? "降落时间" : (kind == .lodging ? "退房" : "结束时间"),
                           isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("", selection: $end)
                            .labelsHidden()
                            #if os(iOS)
                            .datePickerStyle(.compact)
                            #endif
                    }
                    if hasInvalidRange {
                        Text("结束时间早于开始时间,改一下才能保存。")
                            .font(.subheadline)
                            .foregroundStyle(LodoColor.critical)
                    }
                } footer: {
                    Text(kind == .lodging
                         ? "填了入住和退房,这家住宿会出现在住的每一晚里(退房当天不算)。"
                         : "不填时间也能存,会收进「未排期」。")
                }

                if kind == .flight {
                    Section {
                        TextField("出发航站楼", text: $departureTerminal)
                        TextField("值机柜台", text: $checkInCounter)
                        TextField("登机口", text: $gate)
                        TextField("到达航站楼", text: $arrivalTerminal)
                        TextField("座位", text: $seat)
                        TextField("机型", text: $aircraft)
                    } header: {
                        Text("航班信息")
                    } footer: {
                        Text("都是可选的。在行程里点开这班航班,可以导入登机牌或航班动态截图自动补上。")
                    }
                }

                Section {
                    HStack {
                        Picker("币种", selection: $currency) {
                            ForEach(CurrencyCatalog.common, id: \.code) { entry in
                                Text(entry.code).tag(entry.code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        TextField("金额(可选)", text: $priceText)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                    if hasInvalidPrice {
                        Text("金额无法识别为数字,改成数字或清空这一栏才能保存。")
                            .font(.subheadline)
                            .foregroundStyle(LodoColor.critical)
                    }
                } header: {
                    Text("花费")
                }

                Section("备注") {
                    TextEditor(text: $note)
                        .frame(minHeight: 80)
                }
            }
            .navigationTitle(existing == nil ? "添加行程" : "编辑行程")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    confirmButton("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(item: $searching) { target in
                PlaceSearchView { name, coordinate in
                    switch target {
                    case .place:
                        placeName = name
                        placeCoordinate = coordinate
                    case .origin:
                        originName = name
                        originCoordinate = coordinate
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    private func placeRow(
        title: LocalizedStringKey, name: Binding<String>,
        coordinate: Binding<CLLocationCoordinate2D?>, target: SearchTarget
    ) -> some View {
        HStack {
            TextField(title, text: name)
            if coordinate.wrappedValue != nil {
                Image(systemName: "mappin.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("已记录坐标")
            }
            Button("搜索") { searching = target }
                .buttonStyle(.bordered)
                .font(.subheadline)
        }
        // 手打名字就说明用户不想用刚才搜到的那个点了,旧坐标留着会把地图钉在错的地方。
        .onChange(of: name.wrappedValue) { old, new in
            if old != new, !old.isEmpty { coordinate.wrappedValue = nil }
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let existing else {
            start = defaultDate
            end = defaultDate
            return
        }
        kind = existing.travelKind ?? .place
        title = existing.title
        code = existing.travelCode ?? ""
        loadedCode = code
        flight = FlightDetails.decode(existing.travelFlightData)
        departureTerminal = flight?.departureTerminal ?? ""
        arrivalTerminal = flight?.arrivalTerminal ?? ""
        checkInCounter = flight?.checkInCounter ?? ""
        gate = flight?.gate ?? ""
        seat = flight?.seat ?? ""
        aircraft = flight?.aircraft ?? ""
        note = existing.summary
        if let value = existing.travelStart {
            hasStart = true
            start = value
        } else {
            start = defaultDate
        }
        if let value = existing.travelEnd {
            hasEnd = true
            end = value
        } else {
            end = defaultDate
        }
        priceText = existing.travelPrice.map { String($0) } ?? ""
        currency = existing.travelCurrencyOrDefault
        placeName = existing.travelPlaceName ?? ""
        if let lat = existing.travelLatitude, let lon = existing.travelLongitude {
            placeCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        originName = existing.travelOriginName ?? ""
        if let lat = existing.travelOriginLatitude, let lon = existing.travelOriginLongitude {
            originCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    /// 表单里那几项写回补充信息。航班号改成了别的,截图带来的状态/预计时刻就不是
    /// 这一班的了,只留表单里用户看得见、能自己改的那几项。
    private func editedFlight(code: String) -> FlightDetails? {
        let sameFlight = FlightDetails.normalizedNumber(code)
            == FlightDetails.normalizedNumber(loadedCode)
        var details = sameFlight ? (flight ?? FlightDetails()) : FlightDetails()
        func value(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let before = details
        details.departureTerminal = value(departureTerminal)
        details.arrivalTerminal = value(arrivalTerminal)
        details.checkInCounter = value(checkInCounter)
        details.gate = value(gate)
        details.seat = value(seat)
        details.aircraft = value(aircraft)
        if details != before { details.updatedAt = Date() }
        return details.isEmpty ? nil : details
    }

    private func save() {
        let place = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = originName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // 出发地只对航班有意义,换成别的类型再存时要把它连坐标一起清掉。
        let keepOrigin = kind == .flight && !origin.isEmpty
        let keptFlight = kind == .flight ? editedFlight(code: trimmedCode) : nil
        if let existing {
            TravelStore.update(
                existing, kind: kind, title: title, note: note,
                code: trimmedCode.isEmpty ? nil : trimmedCode,
                start: hasStart ? start : nil, end: hasEnd ? end : nil,
                price: price, currency: price == nil ? nil : currency,
                placeName: place.isEmpty ? nil : place,
                latitude: placeCoordinate?.latitude, longitude: placeCoordinate?.longitude,
                originName: keepOrigin ? origin : nil,
                originLatitude: keepOrigin ? originCoordinate?.latitude : nil,
                originLongitude: keepOrigin ? originCoordinate?.longitude : nil,
                flight: keptFlight,
                context: context)
        } else {
            TravelStore.create(
                tripUUID: tripUUID, kind: kind, title: title, note: note,
                code: trimmedCode.isEmpty ? nil : trimmedCode,
                start: hasStart ? start : nil, end: hasEnd ? end : nil,
                price: price, currency: price == nil ? nil : currency,
                placeName: place.isEmpty ? nil : place,
                latitude: placeCoordinate?.latitude, longitude: placeCoordinate?.longitude,
                originName: keepOrigin ? origin : nil,
                originLatitude: keepOrigin ? originCoordinate?.latitude : nil,
                originLongitude: keepOrigin ? originCoordinate?.longitude : nil,
                flight: keptFlight,
                context: context)
        }
        dismiss()
    }
}
