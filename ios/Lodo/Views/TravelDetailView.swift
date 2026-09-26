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
    @Environment(\.lodoAccent) private var lodoAccent
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @AppStorage(AppSettings.assetDisplayCurrencyKey) private var displayCurrency = "CNY"
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @Query private var memoryItems: [MemoryItem]

    @State private var mode: Mode = .days
    @State private var editingItem: MemoryItem?
    /// 点开某一条行程项看详情(航班走 viewingFlight 那条)。
    @State private var viewingItem: MemoryItem?
    /// 地图上正在看哪一天(nil = 全部)。
    @State private var mapDay: Date?
    /// 地图镜头。选了某一天就缩放到把那一天框完整。
    @State private var camera: MapCameraPosition = .automatic
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
        // 右下角那颗「+」去掉了:底下常驻的「问问 AI」就是这一页的新建入口
        // (说一句"第二天加个锦市场"走 edit_trip)。AI 接不了的两条——手动填一条、
        // 把订单/截图交给 OCR——和「编辑旅行」一起收到右上角(同人脉页/记忆页那套
        // "页面自己的操作收在右上角")。
        .toolbar {
            // 放在左上角(返回键旁边),不是右上角。
            ToolbarItem(placement: Self.menuPlacement) {
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
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("行程操作")
            }
        }
        // 这一页也给一条「问问 AI」:focus 带上**这次旅行的名字**,含糊的
        // "第二天改去奈良""这趟一共多少钱"默认就问/改这一次旅行,不用每句话都报名字。
        .askBar(focus: .travel(trip: trip.title))
        .sheet(isPresented: $addingItem) {
            TravelItemEditView(tripUUID: trip.uuid, defaultDate: addingDate)
        }
        .sheet(item: $editingItem) { item in
            TravelItemEditView(tripUUID: trip.uuid, existing: item)
        }
        .sheet(item: $viewingItem) { item in
            TravelItemDetailView(item: item, trip: trip)
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
        // 手打的地名、AI 规划出来的安排都没有坐标,打开这一页时补一遍,地图上才
        // 有点可画(查不到的照旧留空,见 TravelStore.fillMissingCoordinates);
        // 同一轮里先把存错国家的坐标清掉(见 TravelStore.pruneMisplacedCoordinates)。
        .task(id: trip.uuid) {
            await TravelStore.refreshCoordinates(for: trip, context: context)
        }
        #if DEBUG
        .onAppear {
            // 截图验证用:simctl 点不了分段控件,启动参数直接切到对应视图。
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--demo-travel-day") { mode = .days }
            if args.contains("--demo-travel-map") { mode = .map }
            // 截图验证用:simctl 点不了地图左边那条按天胶囊,直接选中第 2 天
            // (镜头会缩放到那一天,见 focusCamera)。
            if args.contains("--demo-travel-map-day") {
                mode = .map
                mapDay = trip.days.count > 1 ? trip.days[1] : trip.days.first
            }
            if args.contains("--demo-travel-cost") { mode = .cost }
            if args.contains("--demo-travel-add") { addingItem = true }
            if args.contains("--demo-travel-import") { importing = true }
            // 截图验证用:simctl 点不了行,直接打开第一条非航班项的详情 / 编辑旅行。
            if args.contains("--demo-travel-item") {
                viewingItem = items.first { $0.travelKind != .flight }
            }
            if args.contains("--demo-travel-trip-edit") { editingTrip = true }
            if args.contains("--demo-travel-flight") {
                viewingFlight = items.first { $0.travelKind == .flight && $0.travelFlightData != nil }
            }
        }
        #endif
    }

    private static var menuPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .primaryAction
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
                    // 备注(那句概述)只在旅行列表页显示:进到这一页要看的是行程本身,
                    // 那句话每天翻十遍不再带来信息,反而把第一天压到屏幕外面去。
                }
                .font(.body)
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
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .dropDestination(for: String.self) { ids, _ in
                                moveDropped(ids, to: day.date)
                            }
                    } else {
                        ForEach(day.entries) { entry in
                            draggable(entry) {
                                entryRow(entry, showDate: false,
                                         night: TravelPlan.lodgingNight(entry, day: day.date))
                            }
                            // 拖到这天任意一行上都算放进这一天。
                            .dropDestination(for: String.self) { ids, _ in
                                moveDropped(ids, to: day.date)
                            }
                        }
                    }
                } header: {
                    // 分区表头上原来右边还有一颗「在这天添加」的「+」,和右下角那颗
                    // FAB 一起去掉了:新建走底下的「问问 AI」("第二天加个锦市场"),
                    // 手动填仍在右上角菜单里。
                    // 拆成插值而不是先拼好 String 再塞进 Text:String 那个重载是
                    // verbatim 的,拼好的字符串进不了字符串目录。
                    Text("第 \(dayIndex(day.date)) 天 · \(Self.dayFormatter.string(from: day.date))")
                        .dropDestination(for: String.self) { ids, _ in
                            moveDropped(ids, to: day.date)
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

    // MARK: - 拖动改天

    /// 长按拖起一行、放到另一天,就把它挪到那天(几点不变)。
    /// 交通类(航班/火车/客车)不给拖:班次时刻是订单上的真实数据,
    /// 拖一下就悄悄改掉太危险,要改走编辑表单。
    @ViewBuilder
    private func draggable<Row: View>(_ entry: TravelEntry,
                                      @ViewBuilder row: () -> Row) -> some View {
        if entry.kind.isTransport {
            row()
        } else {
            row().draggable(entry.id.uuidString)
        }
    }

    private func moveDropped(_ ids: [String], to day: Date) -> Bool {
        var moved = false
        for id in ids {
            guard let uuid = UUID(uuidString: id),
                  let item = memoryItems.first(where: { $0.uuid == uuid && $0.isTravel }),
                  item.travelKind?.isTransport != true else { continue }
            TravelStore.move(item, toDay: day, context: context)
            moved = true
        }
        return moved
    }

    // MARK: - 地图

    /// MapKit 的 SwiftUI `Map` 是系统框架,和 Swift Charts 同理——不算自绘、不算第三方。
    /// 只画有坐标的点。坐标要么来自表单里的「搜索」选点(`PlaceSearchView`),要么来自
/// 打开这一页时按地名自动补的那一遍(`TravelStore.fillMissingCoordinates`);
/// 两条路都没搜到的项不上地图——不编一个大概的位置。
    @ViewBuilder
    private var mapView: some View {
        let pins = mapPins(for: mapDay)
        if mapPins(for: nil).isEmpty {
            ContentUnavailableView {
                Label("地图上还没有点", systemImage: "map")
            } description: {
                Text("填了地点的行程项会自动找坐标画到地图上;这里空着,说明还没填地点,或者按名字没搜到。")
            }
            .frame(maxHeight: .infinity)
        } else {
            Map(position: $camera) {
                ForEach(pins) { pin in
                    Marker(pin.title, systemImage: pin.systemImage, coordinate: pin.coordinate)
                        .tint(pin.color)
                }
                // 每天一条线、一个颜色:一眼看出哪几个点是同一天串起来的。
                ForEach(routes(for: mapDay)) { route in
                    MapPolyline(coordinates: route.coordinates)
                        .stroke(route.color,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .leading) { dayFilterRail }
            .onAppear { focusCamera(animated: false) }
            .onChange(of: mapDay) { _, _ in focusCamera(animated: true) }
        }
    }

    /// 地图左边那条玻璃胶囊:全部 / 第几天。选中某一天时地图只画那天的点和线,
    /// 并缩放到把那一天完整框进来(`focusCamera`)。
    /// 天数多了能上下滑。
    private var dayFilterRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 6) {
                railButton(title: "全部", selected: mapDay == nil) { mapDay = nil }
                ForEach(Array(trip.days.enumerated()), id: \.element) { index, day in
                    railButton(title: "\(index + 1)", selected: mapDay == day) {
                        mapDay = (mapDay == day) ? nil : day
                    }
                }
            }
            .padding(6)
        }
        // 高度按条目数算,不要让 ScrollView 贪满整屏(4 天的旅行配一条顶天立地的
        // 长条很怪);天多了才滚,上限约 8 个。
        .frame(maxHeight: CGFloat(min(trip.days.count + 1, 8)) * 40 + 12)
        .fixedSize(horizontal: true, vertical: false)
        .glassBackground(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.leading, 12)
        .padding(.vertical, 12)
    }

    private func railButton(title: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? lodoAccent.onFill : .primary)
                .frame(minWidth: 34, minHeight: 34)
                .padding(.horizontal, 4)
                // 胶囊而不是圆:「全部」两个字比数字宽,套圆会被撑成椭圆。
                .background {
                    if selected {
                        Capsule().fill(lodoAccent.fill)
                    }
                }
                .contentShape(Capsule())
        }
        .pressable()
    }

    /// 选中那一天(或全部)时把镜头挪过去。切换是用户主动点的,给个动画;
    /// 首次出现时直接定位,不要从世界地图飞过来。
    private func focusCamera(animated: Bool) {
        let pins = mapPins(for: mapDay)
        // 这一天没有任何带坐标的点时不动镜头——把地图甩到 (0,0) 比留在原处更糟。
        guard !pins.isEmpty else { return }
        let region = region(for: pins)
        if animated {
            withAnimation(.lodoAware(.easeInOut(duration: 0.4))) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }

    /// 某一天(nil = 全部)的路线:当天按时间串起来的地点连线 + 那天的颜色。
    private func routes(for day: Date?) -> [MapRoute] {
        TravelPlan.group(entries, into: trip.days)
            .enumerated()
            .filter { day == nil || $0.element.date == day }
            .compactMap { index, grouped in
                let coordinates = TravelPlan.route(grouped).compactMap(\.coordinate).map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                guard coordinates.count >= 2 else { return nil }
                return MapRoute(id: grouped.date, coordinates: coordinates,
                                color: Self.dayColor(index))
            }
    }

    private struct MapRoute: Identifiable {
        let id: Date
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    /// 第几天用哪个颜色。**只是区分第几天,不承载语义**(不是 `LodoColor` 那套
    /// 状态色),所以单独一张表;天数超过表长就循环。强调色不进这张表——
    /// 它会跟着用户设置变,和某一天绑在一起只会让两天看起来是同一天。
    private static let dayColors: [Color] = [
        Color(red: 0.00, green: 0.48, blue: 0.80),
        Color(red: 0.85, green: 0.37, blue: 0.10),
        Color(red: 0.21, green: 0.55, blue: 0.24),
        Color(red: 0.55, green: 0.27, blue: 0.68),
        Color(red: 0.78, green: 0.16, blue: 0.40),
        Color(red: 0.13, green: 0.52, blue: 0.55),
    ]

    private static func dayColor(_ index: Int) -> Color {
        dayColors[index % dayColors.count]
    }

    private struct MapPin: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let coordinate: CLLocationCoordinate2D
        let color: Color
    }

    /// 地图上的点。`day` 为 nil = 全部(含未排期和日期之外的);给了某一天就只要那天的。
    private func mapPins(for day: Date?) -> [MapPin] {
        let visible: [TravelEntry]
        if let day {
            visible = TravelPlan.group(entries, into: trip.days)
                .first { $0.date == day }?.entries ?? []
        } else {
            visible = entries
        }
        let colorByDay = Dictionary(uniqueKeysWithValues:
            trip.days.enumerated().map { ($0.element, Self.dayColor($0.offset)) })
        return visible.flatMap { entry -> [MapPin] in
            // 点的颜色跟着它所在的那一天走,和线对上;跨多天的住宿取入住那天,
            // 未排期/区间外的没有对应的天,用次要灰。
            let color = entry.start
                .map { Calendar.current.startOfDay(for: $0) }
                .flatMap { colorByDay[$0] } ?? LodoColor.muted
            var pins: [MapPin] = []
            if let coordinate = entry.coordinate {
                pins.append(MapPin(
                    id: "\(entry.id)-place",
                    title: entry.placeName ?? entry.title,
                    systemImage: entry.kind.systemImage,
                    coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude),
                    color: color))
            }
            if let origin = entry.originCoordinate {
                pins.append(MapPin(
                    id: "\(entry.id)-origin",
                    title: entry.originName ?? entry.title,
                    systemImage: entry.kind == .flight ? "airplane.departure" : entry.kind.systemImage,
                    coordinate: CLLocationCoordinate2D(latitude: origin.latitude,
                                                       longitude: origin.longitude),
                    color: color))
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
                        .font(.subheadline)
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
                                    .font(.subheadline.monospacedDigit())
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

    /// `night` 只有按天视图里的住宿才传:那一晚是入住当晚 / 最后一晚时各挂一枚标签。
    private func entryRow(_ entry: TravelEntry, showDate: Bool = true,
                          night: LodgingNight? = nil) -> some View {
        Button {
            open(entry)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.kind.systemImage)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if let status = entry.flight?.status, showsStatus(entry) {
                            FlightStatusBadge(status: status)
                        }
                        if night?.isCheckIn == true {
                            LodgingNightBadge(title: "入住", color: lodoAccent.accent)
                        }
                        if night?.isLastNight == true {
                            LodgingNightBadge(title: "明日离开", color: LodoColor.muted)
                        }
                    }
                    // 一行副标题就够:时间 · 地点 · 单号。备注、航班的航站楼登机口
                    // 那些都收进详情页——按天这一页要的是密度,一眼扫完一天有几件事。
                    if let detail = detailLine(entry, showDate: showDate) {
                        Text(detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let price = entry.price, price != 0 {
                    Text("\(entry.currency) \(String(format: "%.0f", price))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 1)
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
                .tint(LodoColor.neutralAction)
            }
        }
    }

    /// 航班行进航班详情(补充信息、导入截图更新都在那里),其余进行程项详情
    /// (`TravelItemDetailView`,备注在第一个 section,编辑在它的工具栏里)。
    /// 行本身只剩标题 + 一行摘要,展开的信息都在这一层。
    private func open(_ entry: TravelEntry) {
        guard let item = item(for: entry) else { return }
        if entry.kind == .flight {
            viewingFlight = item
        } else {
            viewingItem = item
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

/// 按天视图里住宿行上的那两枚小标签(「入住」/「明日离开」)。
/// 样式对齐 `FlightStatusBadge`,只是颜色由调用方给:入住是强调色(这一天的
/// 起点),明日离开是灰(提个醒,不是主操作)。
private struct LodgingNightBadge: View {
    let title: LocalizedStringKey
    let color: Color

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
    }
}
