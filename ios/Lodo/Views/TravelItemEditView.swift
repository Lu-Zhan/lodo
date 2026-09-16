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
    @State private var lookingUp = false
    @State private var lookupMessage: String?
    @State private var lookupTask: Task<Void, Never>?

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
                    HStack {
                        TextField(kind == .flight ? "航班号(可选)" : "订单号/房号(可选)", text: $code)
                        // 没配 key 就根本不出现这颗按钮——这是可选增强,不是必需路径,
                        // 不该摆一颗点了只会说"你没配 key"的按钮在那儿。
                        if kind == .flight, FlightLookupClient.isConfigured {
                            if lookingUp {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("查") { lookUpFlight() }
                                    .buttonStyle(.bordered)
                                    .font(.footnote)
                                    .disabled(code.trimmingCharacters(
                                        in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    if let lookupMessage {
                        Text(lookupMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if kind == .flight, FlightLookupClient.isConfigured {
                        Text("填了航班号点「查」,按下面选的日期带出起降时间和机场。查不到不影响手动填。")
                    }
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
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text(kind == .lodging
                         ? "填了入住和退房,这家住宿会出现在住的每一晚里(退房当天不算)。"
                         : "不填时间也能存,会收进「未排期」。")
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
                            .font(.footnote)
                            .foregroundStyle(.red)
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
            .onDisappear { lookupTask?.cancel() }
        }
    }

    /// 按航班号 + 日期查时刻,回填起降时间与机场(含坐标)。
    /// **只覆盖查到的字段**:API 对小机场覆盖不全,拿不到的照旧留着用户自己填的,
    /// 不会因为查了一次就把已经填好的内容清空。
    private func lookUpFlight() {
        lookupMessage = nil
        lookingUp = true
        let number = code
        let day = hasStart ? start : defaultDate
        lookupTask = Task {
            defer { lookingUp = false }
            do {
                let flights = try await FlightLookupClient.lookup(
                    number: number, date: day, host: AppSettings.flightLookupHost)
                guard !Task.isCancelled, let flight = flights.first else { return }
                apply(flight)
                if flights.count > 1 {
                    // 同一航班号一天多班(经停/多段)时用了第一班,说一声,
                    // 免得用户以为查错了。
                    lookupMessage = "这天有 \(flights.count) 班同号航班,用的是第一班,时间不对请手动改。"
                }
            } catch {
                guard !Task.isCancelled else { return }
                lookupMessage = error.localizedDescription
            }
        }
    }

    private func apply(_ flight: FlightLookupClient.Flight) {
        code = flight.number
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = [flight.airlineName, flight.number]
                .compactMap { $0 }.joined(separator: " ")
        }
        if let time = flight.departure.scheduledTime {
            start = time
            hasStart = true
        }
        if let time = flight.arrival.scheduledTime {
            end = time
            hasEnd = true
        }
        if let name = flight.departure.displayName {
            originName = name
            originCoordinate = coordinate(of: flight.departure)
        }
        if let name = flight.arrival.displayName {
            placeName = name
            placeCoordinate = coordinate(of: flight.arrival)
        }
    }

    private func coordinate(of endpoint: FlightLookupClient.Endpoint) -> CLLocationCoordinate2D? {
        guard let lat = endpoint.latitude, let lon = endpoint.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
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
                .font(.footnote)
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

    private func save() {
        let place = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = originName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // 出发地只对航班有意义,换成别的类型再存时要把它连坐标一起清掉。
        let keepOrigin = kind == .flight && !origin.isEmpty
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
                context: context)
        }
        dismiss()
    }
}
