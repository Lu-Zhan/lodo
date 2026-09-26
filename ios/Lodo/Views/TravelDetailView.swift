import SwiftUI
import SwiftData
import MapKit
import LodoCore

/// 一次旅行:**整屏是地图**,行程放在底部一张常驻的半高面板里(系统 sheet 的
/// 分档:露个头 / 半高 / 全屏,半高以下地图照常能拖能点,同系统地图 app)。
/// 面板里是旅行信息 + 按天 / 价格两个视图;点行程里的一条,地图就飞到那个地点。
/// 右上角:显示路线开关(真实路线 ⇄ 直线)和「⋯」菜单(手动添加 / 从订单导入 /
/// 刷新地点位置 / 编辑旅行)。
/// 行程项是打了「旅行」标签的记忆条目,所以这里用 @Query 盯全部 MemoryItem
/// 再按 tripUUID 过滤——增删改能自动刷新(@Query 盯的是条目本身)。
struct TravelDetailView: View {
    @Bindable var trip: TravelTrip

    @Environment(\.modelContext) private var context
    @Environment(\.lodoAccent) private var lodoAccent
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    @AppStorage(AppSettings.assetDisplayCurrencyKey) private var displayCurrency = "CNY"
    /// 地图上画真实路线(`MKDirections`)还是直线。纯展示偏好,存本机。
    @AppStorage("travelMapShowsRoutes") private var showsRoutes = true
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    @Query private var memoryItems: [MemoryItem]

    @State private var mode: Mode = .days
    @State private var editingItem: MemoryItem?
    /// 点开某一条行程项看详情(航班走 viewingFlight 那条)。
    @State private var viewingItem: MemoryItem?
    /// 地图上正在看哪一天(nil = 全部)。
    @State private var mapDay: Date?
    /// 地图镜头。选了某一天就缩放到把那一天框完整,点了某一条就飞到那个点。
    @State private var camera: MapCameraPosition = .automatic
    /// 地图上选中的那个点(`MapPin.id`)。点列表里的行、或者直接点地图上的点都会改它。
    @State private var selectedPin: String?
    @State private var viewingFlight: MemoryItem?
    @State private var addingItem = false
    @State private var addingDate: Date = .now
    @State private var importing = false
    @State private var editingTrip = false
    /// 底部行程面板。页面出现时弹出、离开时收回(返回上一页前必须先收掉)。
    @State private var showsPanel = false
    @State private var panelDetent: PresentationDetent = .medium
    /// 路线加载完一批就 +1,让地图按新缓存重画。
    @State private var routeRevision = 0
    @State private var relocating = false
    /// 地图顶上停留一会儿的提示(刷新地点位置的结果)。
    @State private var mapNotice: String?

    private static let peekDetent = PresentationDetent.height(200)

    enum Mode: String, CaseIterable, Identifiable {
        case days, cost
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .days: return "按天"
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
        ZStack(alignment: .topLeading) {
            mapLayer
                .ignoresSafeArea()
            mapOverlays
        }
        #if os(iOS)
        // 名字在面板顶上大字显示,导航栏不再重复一遍;导航栏浮在地图上。
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #else
        .navigationTitle(trip.title.isEmpty ? "未命名旅行" : trip.title)
        #endif
        // 页面自己的操作收在右上角(原来「⋯」在左上角、紧挨着返回键)。
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(.lodoAware(.snappy)) { showsRoutes.toggle() }
                } label: {
                    Label(showsRoutes ? "显示直线" : "显示路线",
                          systemImage: showsRoutes ? "point.topleft.down.to.point.bottomright.curvepath.fill"
                                                   : "point.topleft.down.to.point.bottomright.curvepath")
                }
                .accessibilityHint("在真实路线和直线之间切换")
                actionMenu
            }
        }
        .sheet(isPresented: $showsPanel) { panel }
        .onAppear { showsPanel = true }
        .onDisappear { showsPanel = false }
        // 手打的地名、AI 规划出来的安排都没有坐标,打开这一页时补一遍,地图上才
        // 有点可画(查不到的照旧留空,见 TravelStore.fillMissingCoordinates);
        // 同一轮里先把存错国家的坐标清掉(见 TravelStore.pruneMisplacedCoordinates)。
        .task(id: trip.uuid) {
            await TravelStore.refreshCoordinates(for: trip, context: context)
        }
        // 真实路线:点或开关变了就把缺的那几段规划一遍(缓存过的不再请求)。
        .task(id: routeLoadKey) {
            guard showsRoutes else { return }
            if await TravelRouteLoader.load(allLegs) { routeRevision += 1 }
        }
        .onChange(of: pinSignature) { _, _ in
            if selectedPin == nil { focusCamera(animated: true) }
        }
        #if DEBUG
        .onAppear(perform: applyDemoArguments)
        #endif
    }

    private var actionMenu: some View {
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
            Button {
                relocate()
            } label: {
                Label("刷新地点位置", systemImage: "location.magnifyingglass")
            }
            .disabled(relocating)
            Divider()
            Button {
                editingTrip = true
            } label: {
                Label("编辑旅行", systemImage: "pencil")
            }
        } label: {
            Label("行程操作", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - 底部面板

    /// 常驻的行程面板。三档:露个头(只看旅行名和日期,地图几乎整屏)、半高(默认)、
    /// 全屏。半高及以下地图照常可以操作。面板是独立的呈现宿主,所以强调色、
    /// 「问问 AI」和面板里要弹的那几张表单都挂在它里面。
    private var panel: some View {
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
            case .cost: costList
            }
        }
        .padding(.top, 14)
        // 这一页也给一条「问问 AI」:focus 带上**这次旅行的名字**,含糊的
        // "第二天改去奈良""这趟一共多少钱"默认就问/改这一次旅行,不用每句话都报名字。
        .askBar(focus: .travel(trip: trip.title))
        .presentationDetents([Self.peekDetent, .medium, .large], selection: $panelDetent)
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        // sheet 是独立呈现宿主,不继承根上的 tint(同 SettingsView)。
        .tint(lodoAccent.accent)
        .environment(\.lodoAccent, lodoAccent)
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
    }

    #if DEBUG
    private func applyDemoArguments() {
        // 截图验证用:simctl 点不了分段控件/行/面板,启动参数直接摆状态。
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo-travel-day") { mode = .days }
        if args.contains("--demo-travel-cost") { mode = .cost }
        if args.contains("--demo-travel-map-day") {
            mapDay = trip.days.count > 1 ? trip.days[1] : trip.days.first
        }
        if args.contains("--demo-travel-panel-peek") { panelDetent = Self.peekDetent }
        if args.contains("--demo-travel-panel-large") { panelDetent = .large }
        if args.contains("--demo-travel-straight") { showsRoutes = false }
        if args.contains("--demo-travel-focus"),
           let entry = entries.first(where: { $0.coordinate != nil && $0.kind == .place }) {
            select(entry)
        }
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
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .pressableCard()
        .accessibilityHint("编辑旅行")
        .padding(.horizontal)
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
    /// 打开这一页时按地名自动补的那一遍(`TravelStore.fillMissingCoordinates`),要么是
    /// 右上角「刷新地点位置」手动重查的;都没搜到的项不上地图——不编一个大概的位置。
    ///
    /// 每天把当天的地点按时间连起来,一天一个颜色。开着「显示路线」时每一段用
    /// `MKDirections` 规划真实路线(`TravelRouteLoader`),规划不出来的那段退回虚线直线;
    /// 关掉就全部画直线。
    private var mapLayer: some View {
        Map(position: $camera, selection: $selectedPin) {
            ForEach(mapPins(for: mapDay)) { pin in
                Marker(pin.title, systemImage: pin.systemImage, coordinate: pin.coordinate)
                    .tint(pin.color)
                    .tag(pin.id)
            }
            ForEach(mapLegs(for: mapDay)) { leg in
                MapPolyline(coordinates: leg.coordinates)
                    .stroke(leg.color, style: StrokeStyle(
                        lineWidth: 4, lineCap: .round, lineJoin: .round,
                        dash: leg.isStraightFallback ? [6, 6] : []))
            }
        }
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .onAppear { focusCamera(animated: false) }
        .onChange(of: mapDay) { _, _ in
            selectedPin = nil
            focusCamera(animated: true)
        }
        // 直接点地图上的点也一样飞过去(和点列表里那一行同一个效果)。
        .onChange(of: selectedPin) { _, id in
            guard let id, let pin = mapPins(for: nil).first(where: { $0.id == id }) else { return }
            focus(on: [pin], animated: true)
        }
        .onChange(of: panelDetent) { _, _ in
            // 面板高度变了,露出来的那截地图也变了,重新取一次景。
            if let id = selectedPin, let pin = mapPins(for: nil).first(where: { $0.id == id }) {
                focus(on: [pin], animated: true)
            } else {
                focusCamera(animated: true)
            }
        }
    }

    /// 地图上浮着的东西:左上角按天筛选、顶上一条提示。都在安全区之内(导航栏下面)。
    private var mapOverlays: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if trip.days.count > 1 { dayFilterRail }
                Spacer(minLength: 0)
            }
            if let notice = mapNotice ?? emptyMapNotice {
                HStack(spacing: 8) {
                    if relocating { ProgressView().controlSize(.small) }
                    Text(notice)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassBackground(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            }
        }
        .padding(12)
        .animation(.lodoAware(.snappy), value: mapNotice)
    }

    private var emptyMapNotice: String? {
        mapPins(for: nil).isEmpty
            ? String(localized: "填了地点的行程项会自动找坐标画到地图上;可以在右上角「刷新地点位置」重查一遍。")
            : nil
    }

    /// 地图左上角那条玻璃胶囊:全部 / 第几天。选中某一天时地图只画那天的点和线,
    /// 并缩放到把那一天完整框进来(`focusCamera`)。天数多了能上下滑。
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
        // 高度按条目数算,天多了才滚;面板半高时地图只露出上半截,上限压到 6 个。
        .frame(maxHeight: CGFloat(min(trip.days.count + 1, 6)) * 40 + 12)
        .fixedSize(horizontal: true, vertical: false)
        .glassBackground(RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    /// 地图底部被面板盖住的比例:取景只往露出来的那截里放。
    private var coveredFraction: Double {
        switch panelDetent {
        case Self.peekDetent: return 0.25
        default: return 0.55
        }
    }

    /// 选中那一天(或全部)时把镜头挪过去。切换是用户主动点的,给个动画;
    /// 首次出现时直接定位,不要从世界地图飞过来。
    private func focusCamera(animated: Bool) {
        // 这一天没有任何带坐标的点时不动镜头——把地图甩到 (0,0) 比留在原处更糟。
        // 取景只看目的地:回程航班的出发机场在北京、东京的行程就会被拉成半个东亚,
        // 所以有别的点时交通类的点不参与取景(照样画在地图上)。
        let pins = mapPins(for: mapDay)
        let destinations = pins.filter { !$0.isTransport }
        focus(on: destinations.isEmpty ? pins : destinations, animated: animated)
    }

    private func focus(on pins: [MapPin], animated: Bool) {
        let points = pins.map { TravelCoordinate(latitude: $0.coordinate.latitude,
                                                 longitude: $0.coordinate.longitude) }
        guard let frame = TravelMapFraming.frame(
            points, coveredFraction: coveredFraction,
            // 顶上还有状态栏 + 导航栏按钮和按天胶囊,点落在那一截会被挡住。
            topCoveredFraction: 0.14,
            minimumSpan: pins.count == 1 ? 0.012 : 0.05) else { return }
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: frame.center.latitude,
                                           longitude: frame.center.longitude),
            span: MKCoordinateSpan(latitudeDelta: frame.latitudeDelta,
                                   longitudeDelta: frame.longitudeDelta))
        if animated {
            withAnimation(.lodoAware(.easeInOut(duration: 0.45))) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }

    /// 点列表里的一行:有坐标就让地图飞过去并选中那个点(面板在全屏时降回半高,
    /// 不然看不见地图);没坐标就直接打开详情。
    private func select(_ entry: TravelEntry) {
        guard let pin = mapPins(for: nil).first(where: { $0.entryID == entry.id }) else {
            open(entry)
            return
        }
        // 当前按天筛选看不到这个点时,先退回「全部」。
        if !mapPins(for: mapDay).contains(where: { $0.id == pin.id }) { mapDay = nil }
        if panelDetent == .large { panelDetent = .medium }
        selectedPin = pin.id
        focus(on: [pin], animated: true)
    }

    private func relocate() {
        relocating = true
        mapNotice = String(localized: "正在按地名重新查找位置…")
        Task {
            let result = await TravelStore.relocateAll(for: trip, context: context)
            relocating = false
            if result.updated == 0 && result.missed == 0 {
                mapNotice = String(localized: "这次旅行里没有可以查位置的地点。")
            } else if result.missed == 0 {
                mapNotice = String(localized: "已更新 \(result.updated) 个地点的位置。")
            } else {
                mapNotice = String(localized: "已更新 \(result.updated) 个地点,\(result.missed) 个没搜到(保留原来的位置)。")
            }
            selectedPin = nil
            focusCamera(animated: true)
            try? await Task.sleep(for: .seconds(3))
            if !relocating { mapNotice = nil }
        }
    }

    // MARK: - 路线

    /// 某一天(nil = 全部)要连线的点:当天按时间排的地点(`TravelPlan.route`,
    /// 住宿和交通只画点不连线——傍晚才入住的酒店连到早上的景点会画出折返线)。
    private func routeDays(for day: Date?) -> [(index: Int, date: Date, points: [TravelCoordinate])] {
        TravelPlan.group(entries, into: trip.days)
            .enumerated()
            .filter { day == nil || $0.element.date == day }
            .map { index, grouped in
                (index, grouped.date, TravelPlan.route(grouped).compactMap(\.coordinate))
            }
    }

    private var allLegs: [(from: TravelCoordinate, to: TravelCoordinate)] {
        routeDays(for: nil).flatMap { TravelMapFraming.legs($0.points) }
    }

    private var routeLoadKey: String {
        "\(showsRoutes)|" + allLegs.map { TravelMapFraming.legKey($0.from, $0.to) }.joined(separator: ";")
    }

    /// 点的集合变了(补上了坐标、增删了行程项)就重新取景。
    private var pinSignature: String {
        mapPins(for: mapDay).map(\.id).joined(separator: ",")
    }

    /// 地图上的每一段线。开着路线时优先用规划出来的真实路线,没有就画虚线直线。
    private func mapLegs(for day: Date?) -> [MapLeg] {
        _ = routeRevision  // 路线缓存更新后借它触发重画
        return routeDays(for: day).flatMap { index, date, points in
            TravelMapFraming.legs(points).enumerated().map { offset, leg in
                let straight = [leg.from, leg.to].map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                let road = showsRoutes ? TravelRouteLoader.cached(leg.from, leg.to) : nil
                return MapLeg(id: "\(date.timeIntervalSince1970)-\(offset)",
                              coordinates: road ?? straight,
                              color: Self.dayColor(index),
                              isStraightFallback: showsRoutes && road == nil)
            }
        }
    }

    private struct MapLeg: Identifiable {
        let id: String
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
        /// 想要真实路线但没规划出来(或还在规划)的那一段,画成虚线以示区别。
        let isStraightFallback: Bool
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
        let entryID: UUID
        let isTransport: Bool
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
                    id: "\(entry.id)-place", entryID: entry.id, isTransport: entry.kind.isTransport,
                    title: entry.placeName ?? entry.title,
                    systemImage: entry.kind.systemImage,
                    coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude),
                    color: color))
            }
            if let origin = entry.originCoordinate {
                pins.append(MapPin(
                    id: "\(entry.id)-origin", entryID: entry.id, isTransport: true,
                    title: entry.originName ?? entry.title,
                    systemImage: entry.kind == .flight ? "airplane.departure" : entry.kind.systemImage,
                    coordinate: CLLocationCoordinate2D(latitude: origin.latitude,
                                                       longitude: origin.longitude),
                    color: color))
            }
            return pins
        }
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
        HStack(spacing: 8) {
        Button {
            select(entry)
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
            // 点行是在地图上定位;详情从右边这颗进(没坐标的行点整行也直接进详情)。
            Button {
                open(entry)
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(.tint)
            }
            .pressable()
            .accessibilityLabel("详情")
        }
        .listRowBackground(isSelected(entry) ? lodoAccent.accent.opacity(0.12) : nil)
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

    private func isSelected(_ entry: TravelEntry) -> Bool {
        guard let selectedPin else { return false }
        return selectedPin.hasPrefix(entry.id.uuidString)
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
