import SwiftUI
import SwiftData
import MapKit
import LodoCore

/// 一次旅行:顶部是旅行本身的信息(名字/城市·国家/日期),下面按天 / 地图 / 价格
/// 三个视图分段切换。
/// 行程项是打了「旅行」标签的记忆条目,所以这里用 @Query 盯全部 MemoryItem
/// 再按 tripUUID 过滤——增删改能自动刷新(@Query 盯的是条目本身)。
struct TravelDetailView: View {
    @Bindable var trip: TravelTrip

    @Environment(\.modelContext) private var context
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @AppStorage(AppSettings.assetDisplayCurrencyKey) private var displayCurrency = "CNY"
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @Query private var memoryItems: [MemoryItem]

    @State private var mode: Mode = .days
    @State private var editingItem: MemoryItem?
    @State private var viewingFlight: MemoryItem?
    @State private var addingItem = false
    @State private var addingDate: Date = .now
    @State private var importing = false
    @State private var editingTrip = false

    enum Mode: String, CaseIterable, Identifiable {
        case days, map, cost
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .days: return "按天"
            case .map: return "地图"
            case .cost: return "价格"
            }
        }
    }

    private var items: [MemoryItem] {
        memoryItems.filter { $0.isTravel && $0.travelTripUUID == trip.uuid }
    }

    private var entries: [TravelEntry] {
        TravelStore.entries(for: trip.uuid, from: memoryItems)
    }

    private func item(for entry: TravelEntry) -> MemoryItem? {
        items.first { $0.uuid == entry.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("视图", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            switch mode {
            case .days: dayList
            case .map: mapView
            case .cost: costList
            }
        }
        #if os(iOS)
        // 名字已经在页面顶部大字显示,导航栏不再重复一遍(同系统通讯录详情页)。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle(trip.title.isEmpty ? "未命名旅行" : trip.title)
        #endif
        .floatingAddAction {
            Menu {
                Button {
                    addingDate = trip.startDate
                    addingItem = true
                } label: {
                    Label("手动添加", systemImage: "plus")
                }
                Button {
                    importing = true
                } label: {
                    Label("从订单导入", systemImage: "sparkles")
                }
                Divider()
                Button {
                    editingTrip = true
                } label: {
                    Label("编辑旅行", systemImage: "pencil")
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("添加行程")
        }
        .sheet(isPresented: $addingItem) {
            TravelItemEditView(tripUUID: trip.uuid, defaultDate: addingDate)
        }
        .sheet(item: $editingItem) { item in
            TravelItemEditView(tripUUID: trip.uuid, existing: item)
        }
        .sheet(item: $viewingFlight) { item in
            FlightStatusView(item: item, trip: trip)
        }
        .sheet(isPresented: $importing) {
            TravelImportView(trip: trip)
        }
        .sheet(isPresented: $editingTrip) {
            TripEditView(trip: trip)
        }
        #if DEBUG
        .onAppear {
            // 截图验证用:simctl 点不了分段控件,启动参数直接切到对应视图。
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--demo-travel-day") { mode = .days }
            if args.contains("--demo-travel-map") { mode = .map }
            if args.contains("--demo-travel-cost") { mode = .cost }
            if args.contains("--demo-travel-add") { addingItem = true }
            if args.contains("--demo-travel-import") { importing = true }
            if args.contains("--demo-travel-flight") {
                viewingFlight = items.first { $0.travelKind == .flight && $0.travelFlightData != nil }
            }
        }
        #endif
    }

    // MARK: - 旅行信息

    /// 点整块信息直接进编辑,和右上角菜单里的「编辑旅行」同一个入口。
    private var header: some View {
        Button {
            editingTrip = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if trip.title.isEmpty { Text("未命名旅行") } else { Text(trip.title) }
                }
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Group {
                    if let location = trip.locationText {
                        Label(location, systemImage: "mappin.and.ellipse")
                    }
                    Label("\(dateRangeText) · 共 \(trip.dayCount) 天", systemImage: "calendar")
                    if !trip.notes.isEmpty {
                        Text(trip.notes)
                            .lineLimit(3)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .pressableCard()
        .accessibilityHint("编辑旅行")
        .padding(.horizontal)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: - 按天

    private var dayList: some View {
        List {
            ForEach(TravelPlan.group(entries, into: trip.days)) { day in
                Section {
                    if day.entries.isEmpty {
                        Text("这天还没安排")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(day.entries) { entry in
                            entryRow(entry, showDate: false)
                        }
                    }
                } header: {
                    HStack {
                        // 拆成插值而不是先拼好 String 再塞进 Text:String 那个重载是
                        // verbatim 的,拼好的字符串进不了字符串目录。
                        Text("第 \(dayIndex(day.date)) 天 · \(Self.dayFormatter.string(from: day.date))")
                        Spacer()
                        Button {
                            addingDate = day.date
                            addingItem = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("在这天添加行程")
                    }
                }
            }
            let extras = TravelPlan.outOfRange(entries, days: trip.days)
            if !extras.isEmpty {
                Section {
                    ForEach(extras) { entry in entryRow(entry) }
                } header: {
                    Text("行程日期之外")
                } footer: {
                    Text("这些行程项的时间不在这次旅行的日期范围里。改一下旅行日期,或者改这一项的时间。")
                }
            }
            let pending = TravelPlan.unscheduled(entries)
            if !pending.isEmpty {
                Section("未排期") {
                    ForEach(pending) { entry in entryRow(entry) }
                }
            }
        }
    }

    // MARK: - 地图

    /// MapKit 的 SwiftUI `Map` 是系统框架,和 Swift Charts 同理——不算自绘、不算第三方。
    /// 只画有坐标的点:搜地名选过点的才有坐标,手打名字的没有(见 PlaceSearchView)。
    @ViewBuilder
    private var mapView: some View {
        let pins = mapPins
        if pins.isEmpty {
            ContentUnavailableView {
                Label("地图上还没有点", systemImage: "map")
            } description: {
                Text("给行程项填地点时点「搜索」选一下,才会记下坐标画到地图上。")
            }
            .frame(maxHeight: .infinity)
        } else {
            Map(initialPosition: .region(region(for: pins))) {
                ForEach(pins) { pin in
                    Marker(pin.title, systemImage: pin.systemImage, coordinate: pin.coordinate)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private struct MapPin: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let coordinate: CLLocationCoordinate2D
    }

    private var mapPins: [MapPin] {
        entries.flatMap { entry -> [MapPin] in
            var pins: [MapPin] = []
            if let coordinate = entry.coordinate {
                pins.append(MapPin(
                    id: "\(entry.id)-place",
                    title: entry.placeName ?? entry.title,
                    systemImage: entry.kind.systemImage,
                    coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude)))
            }
            if let origin = entry.originCoordinate {
                pins.append(MapPin(
                    id: "\(entry.id)-origin",
                    title: entry.originName ?? entry.title,
                    systemImage: "airplane.departure",
                    coordinate: CLLocationCoordinate2D(latitude: origin.latitude,
                                                       longitude: origin.longitude)))
            }
            return pins
        }
    }

    /// 把所有点框进来。只有一个点时给个固定跨度,否则 span 会算成 0、地图缩到最深。
    private func region(for pins: [MapPin]) -> MKCoordinateRegion {
        let lats = pins.map(\.coordinate.latitude)
        let lons = pins.map(\.coordinate.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60))
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.05),
            longitudeDelta: max((maxLon - minLon) * 1.4, 0.05))
        return MKCoordinateRegion(center: center, span: span)
    }

    // MARK: - 价格

    private var costList: some View {
        List {
            let total = TravelPlan.total(entries, in: displayCurrency) { amount, from, to in
                ExchangeRateStore.shared.convert(amount, from: from, to: to)
            }
            Section {
                LabeledContent("合计") {
                    Text("\(displayCurrency) \(String(format: "%.2f", total.amount))")
                        .font(.body.monospacedDigit())
                }
                if !total.missingCurrencies.isEmpty {
                    // 换不出汇率的不能默默当 0 吞掉,如实说清楚少算了哪几种。
                    Text("以下币种暂时换不到汇率,没有计入合计:\(total.missingCurrencies.joined(separator: "、"))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("总花费")
            } footer: {
                Text("按「设置 → 资产显示币种」折算,汇率与资产总览共用同一份。")
            }

            let lines = TravelPlan.costs(entries)
            if !lines.isEmpty {
                Section("按币种") {
                    ForEach(lines) { line in
                        LabeledContent(line.currency) {
                            Text(String(format: "%.2f", line.amount))
                                .font(.body.monospacedDigit())
                        }
                    }
                }
            }

            ForEach(TravelItemKind.allCases, id: \.self) { kind in
                let kindLines = TravelPlan.costs(entries, kind: kind)
                if !kindLines.isEmpty {
                    Section {
                        ForEach(kindLines) { line in
                            LabeledContent(line.currency) {
                                Text(String(format: "%.2f", line.amount))
                                    .font(.body.monospacedDigit())
                            }
                        }
                        ForEach(entries.filter { $0.kind == kind && ($0.price ?? 0) != 0 }) { entry in
                            LabeledContent(entry.title) {
                                Text("\(entry.currency) \(String(format: "%.2f", entry.price ?? 0))")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Label(LocalizedStrings.text(kind.titleKey, language: language),
                              systemImage: kind.systemImage)
                    }
                }
            }

            if lines.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有记过花费", systemImage: "yensign.circle")
                    } description: {
                        Text("给行程项填上金额,这里就会按币种和类型汇总。")
                    }
                }
            }
        }
        .task { await ExchangeRateStore.shared.refreshIfNeeded() }
    }

    // MARK: - 行

    private func entryRow(_ entry: TravelEntry, showDate: Bool = true) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.kind.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let status = entry.flight?.status, showsStatus(entry) {
                            FlightStatusBadge(status: status)
                        }
                    }
                    if let detail = detailLine(entry, showDate: showDate) {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let flight = entry.flight {
                        FlightInfoLine(flight: flight, planned: entry.start)
                    }
                    if !entry.summary.isEmpty {
                        Text(entry.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                if let price = entry.price, price != 0 {
                    Text("\(entry.currency) \(String(format: "%.0f", price))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .pressableCard()
        // 行操作一律收在向左滑那一侧(全 app 没有 leading swipeActions,见 CLAUDE.md)。
        .swipeActions(edge: .trailing) {
            if let item = item(for: entry) {
                Button(role: .destructive) {
                    TravelStore.remove(item, context: context)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    TravelStore.remove(item, keepMemory: true, context: context)
                } label: {
                    Label("移出行程", systemImage: "tray.and.arrow.up")
                }
                .tint(.orange)
            }
        }
    }

    /// 航班行进航班详情(补充信息、导入截图更新都在那里),其余进编辑表单。
    private func open(_ entry: TravelEntry) {
        guard let item = item(for: entry) else { return }
        if entry.kind == .flight {
            viewingFlight = item
        } else {
            editingItem = item
        }
    }

    /// 列表里的状态胶囊只在航班前后这段时间显示:截图里的状态不会自己更新,
    /// 飞完好几天还挂着「延误」只会误导。
    private func showsStatus(_ entry: TravelEntry) -> Bool {
        guard let reference = entry.end ?? entry.start else { return true }
        return Date() < reference.addingTimeInterval(12 * 3600)
    }

    private func detailLine(_ entry: TravelEntry, showDate: Bool) -> String? {
        var parts: [String] = []
        if let code = entry.code, !code.isEmpty { parts.append(code) }
        if let origin = entry.originName, !origin.isEmpty,
           let place = entry.placeName, !place.isEmpty {
            parts.append("\(origin) → \(place)")
        } else if let place = entry.placeName, !place.isEmpty {
            parts.append(place)
        }
        if let start = entry.start {
            // 住宿一律带日期:它会铺在住的每一晚上,只显示"16:00 – 11:00"会让
            // 第 2、3 天那几行看着像当天就退房了。
            let withDate = showDate || entry.kind == .lodging
            let formatter = withDate ? Self.dateTimeFormatter : Self.timeFormatter
            var span = formatter.string(from: start)
            if let end = entry.end { span += " – " + formatter.string(from: end) }
            parts.append(span)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 格式化

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 EEEE"
        return f
    }()

    private static let rangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    private var dateRangeText: String {
        Self.rangeFormatter.string(from: trip.startDate) + " – "
            + Self.rangeFormatter.string(from: trip.endDate)
    }

    private func dayIndex(_ date: Date) -> Int {
        (trip.days.firstIndex(of: date) ?? 0) + 1
    }
}
