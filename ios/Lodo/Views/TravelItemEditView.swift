import SwiftUI
import SwiftData
import MapKit
import LodoCore

/// 行程项的新建/编辑表单(航班/火车/客车/住宿/地点共用一张表,按类型显示不同字段)。
/// 交通三类各有一段自己的补充信息(航班:航站楼/值机/登机口/舱位/机型;火车:
/// 检票口/站台/车厢/座席;客车:检票口/上车点),两端时区也在这里手填——
/// 起降时刻按**当地时间**填和显示,时长照绝对时间算。都是用户手动提供,不联网查。
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
    /// 刚从搜索结果里选中的名字。选中时名字和坐标是一起写的,下面 placeRow 的
    /// onChange 会把"名字变了"误当成用户手动改名、顺手清掉刚选的坐标——OSM 结果
    /// 的名字(「Kiyomizu-dera」「淺草寺」)几乎总和输入框里原来那几个字不一样,
    /// 选完坐标就没了,地图上自然没有点。记下来,等于这个名字的变化不算手动改名。
    @State private var pickedNames: [SearchTarget: String] = [:]
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
    @State private var cabin = ""
    @State private var platform = ""
    @State private var carriage = ""
    /// 出发地/到达地时区(IANA 标识);nil = 本机时区。
    @State private var departureZoneID: String?
    @State private var arrivalZoneID: String?

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
        case .train: return "车次/区间,如 新干线 东京–京都"
        case .coach: return "班次/区间,如 机场大巴 T2–市区"
        case .lodging: return "住宿名称,如 新宿王子酒店"
        case .place: return "地点名称,如 浅草寺"
        }
    }

    /// 单号那一栏的提示语。交通类填车次/航班号,其余填订单号。
    private var codePrompt: LocalizedStringKey {
        switch kind {
        case .flight: return "航班号(可选),如 CA925"
        case .train: return "车次(可选),如 G123、Nozomi 21"
        case .coach: return "班次(可选)"
        case .lodging, .place: return "订单号/房号(可选)"
        }
    }

    private var departureZone: TimeZone? { departureZoneID.flatMap(TimeZone.init(identifier:)) }
    private var arrivalZone: TimeZone? { arrivalZoneID.flatMap(TimeZone.init(identifier:)) }

    /// 交通类的起讫时刻按两端各自的当地时间填;其余类型用本机时区。
    private var startZone: TimeZone { (kind.isTransport ? departureZone : nil) ?? .current }
    private var endZone: TimeZone { (kind.isTransport ? arrivalZone : nil) ?? .current }

    /// 起讫时间那两个开关的名字。
    private var startLabel: LocalizedStringKey {
        switch kind {
        case .flight: return "起飞时间"
        case .train, .coach: return "发车时间"
        case .lodging: return "入住"
        case .place: return "开始时间"
        }
    }

    private var endLabel: LocalizedStringKey {
        switch kind {
        case .flight: return "降落时间"
        case .train, .coach: return "到达时间"
        case .lodging: return "退房"
        case .place: return "结束时间"
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
                    TextField(codePrompt, text: $code)
                }

                Section {
                    if kind.isTransport {
                        placeRow(title: "出发地", name: $originName,
                                 coordinate: $originCoordinate, target: .origin)
                    }
                    placeRow(title: kind.isTransport ? "到达地" : "地点",
                             name: $placeName, coordinate: $placeCoordinate, target: .place)
                } footer: {
                    Text("点「搜索」选地点才会记下坐标,地图上才画得出这个点;只手打名字也能存,只是不上地图。")
                }

                Section {
                    Toggle(startLabel, isOn: $hasStart)
                    if hasStart {
                        DatePicker("", selection: $start)
                            .labelsHidden()
                            #if os(iOS)
                            .datePickerStyle(.compact)
                            #endif
                            // 交通类按出发地当地时间填(东京起飞就填东京时间)。
                            .environment(\.timeZone, startZone)
                    }
                    if kind.isTransport {
                        zoneRow("出发地时区", selection: departureZoneBinding)
                    }
                    Toggle(endLabel, isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("", selection: $end)
                            .labelsHidden()
                            #if os(iOS)
                            .datePickerStyle(.compact)
                            #endif
                            .environment(\.timeZone, endZone)
                    }
                    if kind.isTransport {
                        zoneRow("到达地时区", selection: arrivalZoneBinding)
                    }
                    if kind.isTransport, hasStart, hasEnd,
                       let minutes = FlightDetails.durationMinutes(start: start, end: end) {
                        LabeledContent(LocalizedStringKey(kind == .flight ? "飞行时长" : "行程时长"),
                                       value: CountdownText.durationText(minutes))
                    }
                    if hasInvalidRange {
                        Text("结束时间早于开始时间,改一下才能保存。")
                            .font(.subheadline)
                            .foregroundStyle(LodoColor.critical)
                    }
                } footer: {
                    if kind == .lodging {
                        Text("填了入住和退房,这家住宿会出现在住的每一晚里(退房当天不算)。")
                    } else if kind.isTransport {
                        Text("时间按出发地、到达地的当地时间填,行程里也按当地日期排;时区不填就按手机的时区。")
                    } else {
                        Text("不填时间也能存,会收进「未排期」。")
                    }
                }

                transportSection

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
            .navigationTitle(LocalizedStringKey(existing == nil ? "添加行程" : "编辑行程"))
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
                // 把这趟旅行的城市/国家一起带给搜索:不带的话「清水寺」搜出来的
                // 第一条可能在国内(见 PlaceSearchView 文件头)。
                PlaceSearchView(onPick: { name, coordinate in
                    pickedNames[target] = name
                    switch target {
                    case .place:
                        placeName = name
                        placeCoordinate = coordinate
                    case .origin:
                        originName = name
                        originCoordinate = coordinate
                    }
                }, hint: tripHint, region: tripRegion, anchor: tripAnchor,
                   tripLacksLocation: tripLacksLocation)
            }
            .onAppear(perform: load)
            #if DEBUG
            // 截图验证用:simctl 点不了「搜索」,直接拉起选地点页(配 --demo-travel-add)。
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--demo-place-search") else { return }
                // 等这张表弹完再叠一层,不然系统会忽略第二次呈现。
                try? await Task.sleep(for: .seconds(1.2))
                searching = .place
            }
            #endif
        }
    }

    /// 交通三类各自的补充信息。字段都是可选的、手填的,不联网查。
    @ViewBuilder
    private var transportSection: some View {
        switch kind {
        case .flight:
            Section {
                TextField("出发航站楼,如 T3", text: $departureTerminal)
                TextField("值机柜台", text: $checkInCounter)
                TextField("登机口", text: $gate)
                TextField("到达航站楼", text: $arrivalTerminal)
                TextField("座位", text: $seat)
                TextField("舱位,如 经济舱", text: $cabin)
                TextField("机型", text: $aircraft)
            } header: {
                Label("航班信息", systemImage: TravelItemKind.flight.systemImage)
            } footer: {
                Text("都是可选的。在行程里点开这班航班,可以导入登机牌或航班动态截图自动补上。")
            }
        case .train:
            Section {
                TextField("检票口", text: $gate)
                TextField("站台", text: $platform)
                TextField("车厢", text: $carriage)
                TextField("座位", text: $seat)
                TextField("座席,如 二等座、指定席", text: $cabin)
            } header: {
                Label("火车信息", systemImage: TravelItemKind.train.systemImage)
            } footer: {
                Text("都是可选的,照车票上的填。")
            }
        case .coach:
            Section {
                TextField("检票口", text: $gate)
                TextField("上车点,如 3 号站台", text: $platform)
                TextField("座位", text: $seat)
            } header: {
                Label("客车信息", systemImage: TravelItemKind.coach.systemImage)
            } footer: {
                Text("都是可选的,照车票上的填。")
            }
        case .lodging, .place:
            EmptyView()
        }
    }

    /// 用户换时区时保留已经填好的"钟面时间":填了 10:00 再选东京,意思是东京的
    /// 10:00,而不是把同一个时刻换算成东京的 11:00。放在绑定的 set 里而不是
    /// onChange:load() 读出已存的时区也会触发 onChange,那时时刻本来就是对的。
    private var departureZoneBinding: Binding<String?> {
        Binding(get: { departureZoneID }, set: { new in
            start = Self.keepingWallClock(start, from: zone(departureZoneID), to: zone(new))
            departureZoneID = new
        })
    }

    private var arrivalZoneBinding: Binding<String?> {
        Binding(get: { arrivalZoneID }, set: { new in
            end = Self.keepingWallClock(end, from: zone(arrivalZoneID), to: zone(new))
            arrivalZoneID = new
        })
    }

    private func zone(_ id: String?) -> TimeZone {
        id.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// 把 `date` 在 `from` 时区里的年月日时分,原样搬到 `to` 时区里。
    static func keepingWallClock(_ date: Date, from: TimeZone, to: TimeZone) -> Date {
        guard from.identifier != to.identifier else { return date }
        var source = Calendar(identifier: .gregorian)
        source.timeZone = from
        var target = Calendar(identifier: .gregorian)
        target.timeZone = to
        let parts = source.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return target.date(from: parts) ?? date
    }

    /// 时区那一行:点进去从列表里选,显示"东京 GMT+9",没选时显示"跟随手机"。
    private func zoneRow(_ title: LocalizedStringKey, selection: Binding<String?>) -> some View {
        NavigationLink {
            TimeZonePickerView(selection: selection)
        } label: {
            LabeledContent(title) {
                if let zone = selection.wrappedValue.flatMap(TimeZone.init(identifier:)) {
                    Text(LocalizedContent.timeZoneName(zone, language: language))
                } else {
                    Text("跟随手机")
                }
            }
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
            // 从搜索结果选来的名字不算手动改名(见 pickedNames);选完再手改照样清。
            if old != new, !old.isEmpty, new != pickedNames[target] { coordinate.wrappedValue = nil }
        }
    }

    /// 这次旅行(用来给地名搜索带上城市/国家消歧)。在 load() 里查一次存下来,
    /// 表单里其余字段都不依赖它。
    @State private var tripHint: String?
    @State private var tripRegion: String?
    /// 这趟旅行里已经有坐标的某个地点,给选地点页按远近排序用(同名的寺庙全国有十几座)。
    @State private var tripAnchor: CLLocationCoordinate2D?
    /// 旅行的城市、国家都没填(选地点页搜不到时提醒去填)。
    @State private var tripLacksLocation = false

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        if let trip = TravelStore.trips(in: context).first(where: { $0.uuid == tripUUID }) {
            tripHint = TravelStore.geocodeHint(for: trip)
            tripRegion = TravelStore.expectedRegion(for: trip)
            tripLacksLocation = trip.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && trip.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // 交通类不当锚点:起降机场常在出发地,会把排序拉到另一个城市去。
            tripAnchor = TravelStore.items(for: trip.uuid, in: context)
                .first { $0.travelKind?.isTransport != true && $0.travelLatitude != nil }
                .flatMap { item in item.travelLatitude.flatMap { lat in
                    item.travelLongitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } } }
        }
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
        cabin = flight?.cabin ?? ""
        platform = flight?.platform ?? ""
        carriage = flight?.carriage ?? ""
        departureZoneID = flight?.departureTimeZone
        arrivalZoneID = flight?.arrivalTimeZone
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
        // 各类型只写它表单里露出来的那几项,别的类型的字段清掉(改了类型再存时
        // 不留一个火车上的「站台」挂在航班上)。
        details.aircraft = kind == .flight ? value(aircraft) : nil
        details.checkInCounter = kind == .flight ? value(checkInCounter) : nil
        details.departureTerminal = kind == .flight ? value(departureTerminal) : nil
        details.arrivalTerminal = kind == .flight ? value(arrivalTerminal) : nil
        details.cabin = kind == .coach ? nil : value(cabin)
        details.platform = kind == .flight ? nil : value(platform)
        details.carriage = kind == .train ? value(carriage) : nil
        details.departureTimeZone = departureZoneID
        details.arrivalTimeZone = arrivalZoneID
        if details != before { details.updatedAt = Date() }
        return details.isEmpty ? nil : details
    }

    private func save() {
        let place = placeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = originName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        // 出发地只对交通类(航班/火车/客车)有意义,换成住宿/地点再存时要把它
        // 连坐标一起清掉。交通补充信息(含两端时区)只有交通三类有。
        let keepOrigin = kind.isTransport && !origin.isEmpty
        let keptFlight = kind.isTransport ? editedFlight(code: trimmedCode) : nil
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
