import SwiftUI
import SwiftData
import MapKit
import PhotosUI
import UniformTypeIdentifiers
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
    @State private var noticeTask: Task<Void, Never>?
    /// 当前这条提示是"没填城市和国家"的提醒:带「去填写」和关闭两颗按钮,一直挂着。
    @State private var noticeOffersTripEdit = false
    /// 切换 mapDay 后要选中的点。行选中需要先把按天筛选退回「全部」,而 mapDay 的
    /// onChange 默认会清掉选中、框全部点——有这个就改成飞到这个点。
    @State private var pendingPin: String?
    /// 左侧按天胶囊点了哪一天,面板列表滚过去(nil 且 token 变了 = 滚到第一天)。
    @State private var panelScrollDay: Date?
    @State private var panelScrollToken = 0
    /// 正在按地名查位置的那一条(点了还没坐标的地点)。
    @State private var locatingEntry: UUID?

    private static let peekDetent = PresentationDetent.height(200)

    enum Mode: String, CaseIterable, Identifiable {
        case overview, days, packing, cost, files
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .overview: return "总览"
            case .days: return "日程"
            case .packing: return "清单"
            case .cost: return "消费"
            case .files: return "文件"
            }
        }
    }

    // 「文件」页的几个入口。
    @State private var importingFiles = false
    @State private var pickingPhotos = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var pickingMemories = false
    @State private var viewingFile: MemoryItem?

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
        .navigationTitle(trip.title.isEmpty
                         ? String(localized: "未命名旅行", bundle: .appLanguage(language), locale: language.locale)
                         : trip.title)
        #endif
        // 页面自己的操作收在右上角(原来「⋯」在左上角、紧挨着返回键)。
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(.lodoAware(.snappy)) { showsRoutes.toggle() }
                } label: {
                    Label(LocalizedStringKey(showsRoutes ? "显示直线" : "显示路线"),
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
            remindToFillLocationIfNeeded()
        }
        // 用户按提醒去「编辑旅行」填了城市/国家:收起提醒,按新的判据再补一遍坐标。
        .onChange(of: tripLocationKey) { _, _ in
            guard !tripLacksLocation else { return }
            if noticeOffersTripEdit { showNotice(nil) }
            Task {
                await TravelStore.refreshCoordinates(for: trip, context: context)
                focusCamera(animated: true)
            }
        }
        // 真实路线:点或开关变了就把缺的那几段规划一遍(缓存过的不再请求)。
        .task(id: routeLoadKey) {
            guard showsRoutes else { return }
            if await TravelRouteLoader.load(selectedDayLegs) { routeRevision += 1 }
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
            modePicker
                .padding(.horizontal)
                .padding(.bottom, 8)

            switch mode {
            case .overview: overviewList
            case .days: dayList
            case .packing: TravelPackingList(trip: trip)
            case .cost: costList
            case .files: filesList
            }
        }
        .padding(.top, 14)
        // 这一页也给一条「问问 AI」:focus 带上**这次旅行的名字**,含糊的
        // "第二天改去奈良""这趟一共多少钱"默认就问/改这一次旅行,不用每句话都报名字。
        .askBar(focus: .travel(trip: trip.title))
        .presentationDetents([Self.peekDetent, .medium, .large], selection: $panelDetent)
        // 三档都允许和背后的地图交互:只放到半高的话,拉满时系统会把背后压暗,
        // 玻璃采样到的颜色跟着变,面板一拉一放就跳色。
        .presentationBackgroundInteraction(.enabled)
        .presentationDragIndicator(.visible)
        // 面板底色透明,上拉时地图会透到旅行标题与切换条周围;列表卡片仍用固定行底色。
        .presentationBackground { TravelPanelBackground() }
        // Sheet 是独立呈现宿主,页面根上的滚动边缘效果不会传进来。
        // 这里让行程列表滚到顶部时在切换条下方柔和淡出。
        .softTopScrollEdgeTransition()
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

    /// 「总览 / 日程 / 消费 / 文件」切换,样式见 `SlidingSwitch`。
    private var modePicker: some View {
        SlidingSwitch(options: Mode.allCases, selection: $mode) { Text($0.title) }
    }

    #if DEBUG
    private func applyDemoArguments() {
        // 截图验证用:simctl 点不了分段控件/行/面板,启动参数直接摆状态。
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--demo-travel-day") { mode = .days }
        if args.contains("--demo-travel-overview") { mode = .overview }
        if args.contains("--demo-travel-files") { mode = .files }
        if args.contains("--demo-travel-cost") { mode = .cost }
        if args.contains("--demo-travel-packing") { mode = .packing }
        if args.contains("--demo-travel-map-day") {
            // 走左侧胶囊同一条路(连面板滚动一起);等面板弹出来、列表建好再点。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                selectDay(trip.days.count > 1 ? trip.days[1] : trip.days.first)
            }
        }
        // 截图验证用:--demo-travel-rail-select N 直接在左侧胶囊里选第 N 天;
        // N = 0 表示先选第 5 天、再切回「全部」(看回到顶上时有没有往上窜)。
        if let index = args.firstIndex(of: "--demo-travel-rail-select"), index + 1 < args.count,
           let n = Int(args[index + 1]) {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                if n == 0, trip.days.count >= 5 {
                    selectDay(trip.days[4])
                    try? await Task.sleep(for: .seconds(1.5))
                    selectDay(nil)
                } else if trip.days.indices.contains(n - 1) {
                    selectDay(trip.days[n - 1])
                }
            }
        }
        if args.contains("--demo-travel-panel-peek") { panelDetent = Self.peekDetent }
        if args.contains("--demo-travel-panel-large") { panelDetent = .large }
        if args.contains("--demo-travel-straight") { showsRoutes = false }
        if args.contains("--demo-travel-focus"),
           let entry = entries.first(where: { $0.coordinate != nil && $0.kind == .place }) {
            select(entry)
        }
        // 截图验证用:simctl 点不了右上角菜单,直接跑一遍「刷新地点位置」(真发网络请求)。
        if args.contains("--demo-travel-relocate") { relocate() }
        if args.contains("--demo-travel-add") { addingItem = true }
        if args.contains("--demo-travel-import") { importing = true }
        // 截图验证用:simctl 点不了行,直接打开第一条非航班项的详情 / 编辑旅行。
        if args.contains("--demo-travel-item") {
            viewingItem = items.first { $0.travelKind != .flight }
        }
        // 截图验证用:编辑第一条有地名的地点(配 --demo-place-search <词> --demo-place-pick
        // 复现"选了搜索结果、坐标却被清掉"那个问题)。
        if args.contains("--demo-travel-edit-place") {
            editingItem = items.first { $0.travelKind == .place && !($0.travelPlaceName ?? "").isEmpty }
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
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.primary)
                Group {
                    if let location = trip.locationText {
                        Label(location, systemImage: "mappin.and.ellipse")
                    }
                    Label("\(dateRangeText) · 共 \(trip.dayCount) 天", systemImage: "calendar")
                    // 备注(那句概述)只在旅行列表页显示:进到这一页要看的是行程本身,
                    // 那句话每天翻十遍不再带来信息,反而把第一天压到屏幕外面去。
                }
                .font(.subheadline)
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
        ScrollViewReader { proxy in
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
                                entryRow(entry, group: "day-\(day.date.timeIntervalSince1970)",
                                         showDate: false,
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
                    Text("第 \(dayIndex(day.date)) 天 · \(LocalizedContent.dateAndWeekday(day.date, language: language))")
                        .dropDestination(for: String.self) { ids, _ in
                            moveDropped(ids, to: day.date)
                        }
                }
                // 左侧按天胶囊选中某一天时滚到这里(见 selectDay)。List 的分区标题不能当
                // scrollTo 的目标,实际对准的是分区第一行,锚点因此往下让出一截标题。
                .id(day.date)
                .listRowBackground(Self.panelRowBackground)
            }
            let extras = TravelPlan.outOfRange(entries, days: trip.days)
            if !extras.isEmpty {
                Section {
                    ForEach(extras) { entry in entryRow(entry, group: "extras") }
                } header: {
                    Text("行程日期之外")
                } footer: {
                    Text("这些行程项的时间不在这次旅行的日期范围里。改一下旅行日期,或者改这一项的时间。")
                }
                .listRowBackground(Self.panelRowBackground)
            }
            let pending = TravelPlan.unscheduled(entries)
            if !pending.isEmpty {
                Section("未排期") {
                    ForEach(pending) { entry in entryRow(entry, group: "unscheduled") }
                }
                .listRowBackground(Self.panelRowBackground)
            }
        }
        // 列表自己不铺底色,透出面板那层玻璃。
        .scrollContentBackground(.hidden)
        .backgroundPreferenceValue(EntryGroupFramesKey.self) { entryGroupGlass($0) }
        .onChange(of: panelScrollToken) { _, _ in
            guard let target = panelScrollDay ?? trip.days.first else { return }
            // 等面板从露头升到半高、分段切回「按天」这一帧布局完再滚。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.lodoAware(.snappy)) {
                    proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.14))
                }
            }
        }
        }
    }

    // MARK: - 总览

    /// 总览:交通(航班/火车/客车,整趟按时间排)+ 待安排(还没定日期的地点、餐馆,
    /// 相当于这次旅行的收件箱)。点一行和日程里一样:有坐标就在地图上定位。
    private var overviewList: some View {
        let transport = entries.filter { $0.kind.isTransport }
        let pending = TravelPlan.unscheduled(entries).filter { !$0.kind.isTransport }
        return List {
            Section {
                if transport.isEmpty {
                    Text("还没有记下航班、火车或客车。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(transport) { entry in entryRow(entry, group: "transport") }
                }
            } header: {
                Label("交通", systemImage: "airplane")
            }
            .listRowBackground(Self.panelRowBackground)
            Section {
                if pending.isEmpty {
                    Text("想去但还没定哪天的地点和餐馆会放在这里。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(pending) { entry in entryRow(entry, group: "inbox") }
                }
            } header: {
                Label("待安排", systemImage: "tray")
            } footer: {
                if !pending.isEmpty {
                    Text("点行尾的 ⓘ 给它排个时间,就会出现在日程里。")
                }
            }
            .listRowBackground(Self.panelRowBackground)
        }
        .scrollContentBackground(.hidden)
        .backgroundPreferenceValue(EntryGroupFramesKey.self) { entryGroupGlass($0) }
    }

    // MARK: - 文件

    private var tripFiles: [MemoryItem] {
        TravelStore.files(for: trip.uuid, from: memoryItems)
    }

    /// 文件:这次旅行相关的资料。就是挂着这次旅行的记忆条目,所以和记忆库是同一份
    /// ——在这里加的文件照常 AI 整理、能在记忆页和「问问 AI」里搜到;从记忆库也能
    /// 挑已有的条目挂过来。只显示这一次旅行的。
    private var filesList: some View {
        List {
            Section {
                Menu {
                    Button {
                        importingFiles = true
                    } label: {
                        Label("选择文件", systemImage: "folder")
                    }
                    Button {
                        pickingPhotos = true
                    } label: {
                        Label("照片", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        pickingMemories = true
                    } label: {
                        Label("从记忆库选择", systemImage: "tray.full")
                    }
                } label: {
                    Label("添加文件", systemImage: "plus.circle.fill")
                        .font(.body.weight(.medium))
                }
            }
            .listRowBackground(Self.panelRowBackground)
            if tripFiles.isEmpty {
                Section {
                    Text("机票行程单、签证、保险、攻略截图……放在这里,在记忆里也能搜到。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Self.panelRowBackground)
            } else {
                Section {
                    ForEach(tripFiles) { file in fileRow(file) }
                } footer: {
                    Text("和记忆库是同一份:删掉会从记忆里一起删掉,「移出旅行」只是不再挂在这次旅行上。")
                }
                .listRowBackground(Self.panelRowBackground)
            }
        }
        .scrollContentBackground(.hidden)
        .fileImporter(isPresented: $importingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                TravelStore.attachFile(url, to: trip, context: context)
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoSelection, matching: .images)
        .onChange(of: photoSelection) { _, selection in
            guard !selection.isEmpty else { return }
            Task {
                for item in selection {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        TravelStore.attachImage(data, to: trip, context: context)
                    }
                }
                photoSelection = []
            }
        }
        .sheet(isPresented: $pickingMemories) {
            MemoryPickerView(excluding: Set(tripFiles.map(\.uuid))) { picked in
                TravelStore.attachMemories(picked, to: trip, context: context)
            }
            .tint(lodoAccent.accent)
            .environment(\.lodoAccent, lodoAccent)
        }
        .sheet(item: $viewingFile) { file in
            NavigationStack { MemoryDetailView(item: file) }
                .tint(lodoAccent.accent)
                .environment(\.lodoAccent, lodoAccent)
        }
    }

    private func fileRow(_ file: MemoryItem) -> some View {
        Button {
            viewingFile = file
        } label: {
            HStack(spacing: 10) {
                Image(systemName: file.kind.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.title.isEmpty
                         ? (file.originalFileName ?? String(localized: "未命名", bundle: .appLanguage(language), locale: language.locale))
                         : file.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(file.summary.isEmpty ? (file.originalFileName ?? "") : file.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if file.travelKind != nil {
                    // 行程项自带的附件(导入订单时存下的确认单),标一下它属于哪一条。
                    Image(systemName: "paperclip")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .pressableCard()
        .swipeActions(edge: .trailing) {
            // 行程项的附件在日程里管,这里只管挂到旅行上的文件。
            if file.travelKind == nil {
                Button(role: .destructive) {
                    MemoryPipeline.delete(file, context: context)
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    TravelStore.detachFile(file, context: context)
                } label: {
                    Label("移出旅行", systemImage: "tray.and.arrow.up")
                }
                .tint(LodoColor.neutralAction)
            }
        }
    }

    /// 面板里各个列表的行底色。**固定下来**,不跟系统走:系统面板拉到全屏时会把
    /// 列表行和底板都换成更实的白色,半高时又是透明的,一拉一放颜色就跳。
    static var panelRowBackground: Color {
        // 固定色值,不用 secondarySystemGroupedBackground:实测面板在半高时系统会把那个
        // 语义色解析成更深的一档,和全屏时的白卡片对不上。
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(white: 0.17, alpha: 1) : .white
        })
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
            // 以 renderKey(id + 坐标)做标识:刷新地点位置后同一个点换了坐标,
            // 按 id 不变的话不保证 MapKit 会把标记挪过去。选中仍按 tag(pin.id)。
            ForEach(mapPins(for: mapDay), id: \.renderKey) { pin in
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
            if let pin = pendingPin.flatMap({ id in mapPins(for: nil).first { $0.id == id } }) {
                pendingPin = nil
                selectedPin = pin.id
                focus(on: [pin], animated: true)
            } else {
                selectedPin = nil
                focusCamera(animated: true)
            }
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        if relocating { ProgressView().controlSize(.small) }
                        Text(notice)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        if noticeOffersTripEdit {
                            Spacer(minLength: 0)
                            Button {
                                showNotice(nil)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .pressable()
                            .accessibilityLabel("关闭提醒")
                        }
                    }
                    if noticeOffersTripEdit || (mapNotice == nil && tripLacksLocation) {
                        Button("去填写城市和国家") { editingTrip = true }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(lodoAccent.accent)
                            .pressable()
                    }
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
        guard mapPins(for: nil).isEmpty else { return nil }
        return tripLacksLocation
            ? fillLocationReminder
            : String(localized: "填了地点的行程项会自动找坐标画到地图上;可以在右上角「刷新地点位置」重查一遍。",
                     bundle: .appLanguage(language), locale: language.locale)
    }

    // MARK: - 没填城市和国家的提醒

    /// 城市、国家两栏都没填。这种旅行查地名只能靠从旅行名里猜城市,经常猜不出来,
    /// 查不到是正常的——该做的是提醒用户去填,而不是只说"没找到"。
    private var tripLacksLocation: Bool {
        trip.city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && trip.country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var tripLocationKey: String { trip.city + "|" + trip.country }

    /// 有地名(或标题)、却还没坐标的非交通类行程项。
    private var unlocatedCount: Int {
        entries.filter { $0.coordinate == nil && !$0.kind.isTransport }.count
    }

    private var fillLocationReminder: String {
        String(localized: "这次旅行还没填城市和国家,地点查不到位置。填上以后地图才能准确定位。",
               bundle: .appLanguage(language), locale: language.locale)
    }

    /// 查位置之后还有地点没找到、并且旅行没填城市国家时,挂一条带「去填写」的提醒。
    private func remindToFillLocationIfNeeded() {
        guard tripLacksLocation, unlocatedCount > 0 else { return }
        showNotice(fillLocationReminder, sticky: true, offersTripEdit: true)
    }

    /// 地图左上角那条玻璃胶囊:全部 / 第几天。选中某一天时地图只画那天的点和线,
    /// 并缩放到把那一天完整框进来(`focusCamera`)。天数多了能上下滑。
    /// 胶囊宽度和左上角返回键一样(48pt),里面的按钮一律 36pt 圆。
    private static let railWidth: CGFloat = 48
    private static let railButtonSize: CGFloat = 36
    private static let railSpacing: CGFloat = 4
    private static var railInset: CGFloat { (railWidth - railButtonSize) / 2 }
    /// 一次最多露出几格(「全部」+ 1…5 天),再多就滚。
    private static let railVisibleSlots = 6
    /// 内容最顶/最底的零高度定位点。滚到「全部」或最后一天时对准它们,而不是对准那颗
    /// 按钮本身——对准按钮会把它外侧那截内边距滚掉,选「全部」时整条会往上窜一点。
    private static let railTopAnchor = -2
    private static let railBottomAnchor = -3

    private var dayFilterRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.railTopAnchor)
                    VStack(spacing: Self.railSpacing) {
                        railButton(title: "全部", selected: mapDay == nil) { selectDay(nil) }
                        ForEach(Array(trip.days.enumerated()), id: \.element) { index, day in
                            railButton(title: "\(index + 1)", selected: mapDay == day) {
                                selectDay(mapDay == day ? nil : day)
                            }
                            .id(index)
                        }
                    }
                    .padding(Self.railInset)
                    Color.clear.frame(height: 0).id(Self.railBottomAnchor)
                }
            }
            .frame(width: Self.railWidth,
                   height: CGFloat(min(trip.days.count + 1, Self.railVisibleSlots))
                       * (Self.railButtonSize + Self.railSpacing) - Self.railSpacing + Self.railInset * 2)
            .glassBackground(RoundedRectangle(cornerRadius: Self.railWidth / 2, style: .continuous))
            // 天数比能露出的格数多时,选中某天后让它后面两天也露出来(选 4 看得到 6、
            // 选 5 看得到 7),往后翻不用自己拖;选「全部」回到顶上。
            .onChange(of: mapDay) { _, day in
                guard trip.days.count + 1 > Self.railVisibleSlots else { return }
                withAnimation(.lodoAware(.snappy)) {
                    if let day, let index = trip.days.firstIndex(of: day) {
                        let target = index + 2
                        if target >= trip.days.count - 1 {
                            proxy.scrollTo(Self.railBottomAnchor, anchor: .bottom)
                        } else {
                            proxy.scrollTo(target, anchor: .bottom)
                        }
                    } else {
                        proxy.scrollTo(Self.railTopAnchor, anchor: .top)
                    }
                }
            }
        }
    }

    private func railButton(title: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? lodoAccent.onFill : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Self.railButtonSize, height: Self.railButtonSize)
                .background {
                    if selected { Circle().fill(lodoAccent.fill) }
                }
                .contentShape(Circle())
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

    /// 左侧按天胶囊选了某一天(nil = 全部):地图只画那天,面板列表也滚到那一天
    /// (面板在「价格」时切回「按天」,露头时升到半高,不然看不见列表)。
    /// 只有胶囊触发滚动——点列表里的行引起的切天不滚,列表不该在手指底下跳走。
    private func selectDay(_ day: Date?) {
        mapDay = day
        if mode != .days { mode = .days }
        if panelDetent == Self.peekDetent { panelDetent = .medium }
        panelScrollDay = day
        panelScrollToken += 1
    }

    /// 点列表里的一行:有坐标就让地图飞过去并选中那个点(面板在全屏时降回半高,
    /// 不然看不见地图);地点还没坐标就当场按地名查一次,查到了再飞过去;
    /// 交通类(起降点来自订单)没坐标就直接打开详情。
    private func select(_ entry: TravelEntry) {
        guard let pin = mapPins(for: nil).first(where: { $0.entryID == entry.id }) else {
            if entry.kind.isTransport { open(entry) } else { locateAndFocus(entry) }
            return
        }
        if panelDetent == .large { panelDetent = .medium }
        if mapPins(for: mapDay).contains(where: { $0.id == pin.id }) {
            selectedPin = pin.id
            focus(on: [pin], animated: true)
        } else {
            // 当前按天筛选看不到这个点:退回「全部」,由 mapDay 的 onChange 接着飞过去。
            pendingPin = pin.id
            mapDay = nil
        }
    }

    private func locateAndFocus(_ entry: TravelEntry) {
        guard locatingEntry == nil, let item = item(for: entry) else { return }
        locatingEntry = entry.id
        showNotice(String(localized: "正在查找「\(entry.placeName ?? entry.title)」的位置…",
                          bundle: .appLanguage(language), locale: language.locale), sticky: true)
        Task {
            let found = await TravelStore.locate(item, in: trip, context: context)
            locatingEntry = nil
            if found, let pin = mapPins(for: nil).first(where: { $0.entryID == entry.id }) {
                showNotice(nil)
                if panelDetent == .large { panelDetent = .medium }
                if mapPins(for: mapDay).contains(where: { $0.id == pin.id }) {
                    selectedPin = pin.id
                    focus(on: [pin], animated: true)
                } else {
                    pendingPin = pin.id
                    mapDay = nil
                }
            } else if tripLacksLocation {
                showNotice(fillLocationReminder, sticky: true, offersTripEdit: true)
            } else {
                showNotice(String(localized: "没找到「\(entry.placeName ?? entry.title)」的位置,可以点 ⓘ 进编辑,用「搜索」手动选点。",
                                  bundle: .appLanguage(language), locale: language.locale))
            }
        }
    }

    /// 地图顶上的提示。sticky 的一直挂着(进行中/需要用户处理),否则几秒后自己消失。
    private func showNotice(_ text: String?, sticky: Bool = false, offersTripEdit: Bool = false) {
        noticeTask?.cancel()
        mapNotice = text
        noticeOffersTripEdit = text != nil && offersTripEdit
        guard text != nil, !sticky else { return }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            mapNotice = nil
        }
    }

    private func relocate() {
        relocating = true
        showNotice(String(localized: "正在按地名重新查找位置…", bundle: .appLanguage(language), locale: language.locale), sticky: true)
        Task {
            let result = await TravelStore.relocateAll(for: trip, context: context)
            relocating = false
            if tripLacksLocation && (result.destinationUnknown || result.missed > 0) {
                showNotice(fillLocationReminder, sticky: true, offersTripEdit: true)
            } else {
                showNotice(relocateMessage(result))
            }
            // 选中的点还在就飞到它的新位置,否则把全部点重新框一遍。
            if let id = selectedPin, let pin = mapPins(for: nil).first(where: { $0.id == id }) {
                focus(on: [pin], animated: true)
            } else {
                selectedPin = nil
                focusCamera(animated: true)
            }
        }
    }

    /// 分开说"变了几个 / 没变 / 没搜到",看得出刷新到底有没有生效。
    private func relocateMessage(_ result: TravelStore.RelocateResult) -> String {
        if result.destinationUnknown {
            return String(localized: "认不出这次旅行在哪个城市,请在「编辑旅行」里填上城市或国家。",
                          bundle: .appLanguage(language), locale: language.locale)
        }
        if result.total == 0 {
            return String(localized: "这次旅行里没有可以查位置的地点。", bundle: .appLanguage(language), locale: language.locale)
        }
        if result.moved == 0 && result.missed == 0 {
            return String(localized: "已重新查找 \(result.total) 个地点,位置都没有变化。",
                          bundle: .appLanguage(language), locale: language.locale)
        }
        if result.missed == 0 {
            return result.unchanged == 0
                ? String(localized: "已重新查找 \(result.total) 个地点:\(result.moved) 个位置有更新。",
                         bundle: .appLanguage(language), locale: language.locale)
                : String(localized: "已重新查找 \(result.total) 个地点:\(result.moved) 个位置有更新,\(result.unchanged) 个没变。",
                         bundle: .appLanguage(language), locale: language.locale)
        }
        return String(localized: "已重新查找 \(result.total) 个地点:\(result.moved) 个位置有更新,\(result.unchanged) 个没变,\(result.missed) 个没搜到(保留原来的位置)。",
                      bundle: .appLanguage(language), locale: language.locale)
    }

    // MARK: - 路线

    /// 某一天(nil = 全部)要连线的点:前一晚的酒店出发 → 当天按时间排的地点 → 当晚的酒店
    /// (`TravelPlan.dayRoute`);交通类照旧只画点不连线(两头分处两地)。
    private func routeDays(for day: Date?) -> [(index: Int, date: Date, points: [TravelCoordinate])] {
        TravelPlan.group(entries, into: trip.days)
            .enumerated()
            .filter { day == nil || $0.element.date == day }
            .map { index, grouped in
                (index, grouped.date,
                 TravelPlan.dayRoute(grouped, entries: entries).compactMap(\.coordinate))
            }
    }

    /// 选中那一天要规划的几段;「全部」时不画线,也就不规划。
    private var selectedDayLegs: [(from: TravelCoordinate, to: TravelCoordinate)] {
        guard mapDay != nil else { return [] }
        return routeDays(for: mapDay).flatMap { TravelMapFraming.legs($0.points) }
    }

    private var routeLoadKey: String {
        "\(showsRoutes)|" + selectedDayLegs.map { TravelMapFraming.legKey($0.from, $0.to) }.joined(separator: ";")
    }

    /// 点的集合变了(补上了坐标、增删了行程项)就重新取景。
    private var pinSignature: String {
        mapPins(for: mapDay).map(\.id).joined(separator: ",")
    }

    /// 地图上的每一段线。开着路线时优先用规划出来的真实路线,没有就画虚线直线。
    /// 地图上的线。**选「全部」时一条都不画**:每天都从同一家酒店出发、回到酒店,
    /// 几天的线在酒店交汇,看上去像把不同日期的地点串在了一起;选中某一天才画那天的路线。
    private func mapLegs(for day: Date?) -> [MapLeg] {
        _ = routeRevision  // 路线缓存更新后借它触发重画
        guard day != nil else { return [] }
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

        var renderKey: String {
            String(format: "%@|%.5f,%.5f", id, coordinate.latitude, coordinate.longitude)
        }
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
                    systemImage: entry.symbolName,
                    coordinate: CLLocationCoordinate2D(latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude),
                    color: color))
            }
            if let origin = entry.originCoordinate {
                pins.append(MapPin(
                    id: "\(entry.id)-origin", entryID: entry.id, isTransport: true,
                    title: entry.originName ?? entry.title,
                    systemImage: entry.kind == .flight ? "airplane.departure" : entry.symbolName,
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
            .listRowBackground(Self.panelRowBackground)

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
                .listRowBackground(Self.panelRowBackground)
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
                    .listRowBackground(Self.panelRowBackground)
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
        .scrollContentBackground(.hidden)
        .task { await ExchangeRateStore.shared.refreshIfNeeded() }
    }

    // MARK: - 行

    /// `night` 只有按天视图里的住宿才传:那一晚是入住当晚 / 最后一晚时各挂一枚标签。
    /// `group` 标出这一行属于哪一组(哪一天、交通、待安排……),同组的行在列表背后
    /// 共用一整块玻璃,见 `entryGroupGlass`。
    private func entryRow(_ entry: TravelEntry, group: String, showDate: Bool = true,
                          night: LodgingNight? = nil) -> some View {
        HStack(spacing: 8) {
        Button {
            select(entry)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.symbolName)
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
        // 同一组的行共用一整块 Liquid Glass(用户要求,同侧栏导航行那条例外),行间
        // 不留空隙、不要分隔线。行自己不画底,只报告位置,玻璃由列表背后的
        // `entryGroupGlass` 按整组的范围画——每行各垫一块时相邻两块亮度对不上,
        // 交界处有一道接缝。行内边距清零、由这里的 padding 撑回来,位置才是整行。
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .anchorPreference(key: EntryGroupFramesKey.self, value: .bounds) {
            [group: [EntryGroupFrame(bounds: $0, selected: isSelected(entry))]]
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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

    /// 行程项分组的玻璃底:按每组各行报上来的位置取并集,画一整块圆角玻璃;选中
    /// (地图上正定位着它)那行在玻璃上叠一层淡淡的强调色,裁在同一个圆角里。
    /// 旧系统 /「减弱透明度」退回固定底色——理由见 `panelRowBackground`。
    ///
    /// 列表是懒加载的,滚出屏幕的行不报位置,并集只覆盖当前建出来的那几行;它们
    /// 本来就在可见区外面,顶/底的圆角因此不会出现在屏幕中间。
    private func entryGroupGlass(_ groups: [String: [EntryGroupFrame]]) -> some View {
        GeometryReader { proxy in
            ForEach(groups.keys.sorted(), id: \.self) { key in
                let frames = groups[key] ?? []
                let rects = frames.map { proxy[$0.bounds] }
                if let first = rects.first {
                    let union = rects.dropFirst().reduce(first) { $0.union($1) }
                    let selected = zip(frames, rects).filter { $0.0.selected }.map(\.1)
                    let shape = RoundedRectangle(cornerRadius: Self.entryGroupRadius, style: .continuous)
                    ZStack(alignment: .topLeading) {
                        GlassRowBackground(selected: false, tint: .clear, shape: shape) {
                            shape.fill(Self.panelRowBackground)
                        }
                        ForEach(Array(selected.enumerated()), id: \.offset) { _, rect in
                            Rectangle()
                                .fill(lodoAccent.accent.opacity(0.12))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX - union.minX, y: rect.minY - union.minY)
                        }
                    }
                    .frame(width: union.width, height: union.height, alignment: .topLeading)
                    .clipShape(shape)
                    .offset(x: union.minX, y: union.minY)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 分组玻璃的圆角,对上 List 分区自己的圆角(面板里别的分区还是系统画的)。
    private static let entryGroupRadius: CGFloat = 22

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
            // 交通类按两端当地时间显示(东京起飞写东京时间)。
            var span = withDate
                ? LocalizedContent.dateTime(start, language: language, timeZone: entry.startTimeZone)
                : LocalizedContent.time(start, language: language, timeZone: entry.startTimeZone)
            if let end = entry.end {
                let endText = withDate
                    ? LocalizedContent.dateTime(end, language: language, timeZone: entry.endTimeZone)
                    : LocalizedContent.time(end, language: language, timeZone: entry.endTimeZone)
                span += " – " + endText
            }
            parts.append(span)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 格式化

    private var dateRangeText: String {
        LocalizedContent.dateRangeEndpoint(trip.startDate, language: language) + " – "
            + LocalizedContent.dateRangeEndpoint(trip.endDate, language: language)
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

/// 旅行详情行程面板的底色。「减弱透明度」开启时使用不透明面色,其余情况保持透明。
private struct TravelPanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 固定色值(同 panelRowBackground 的理由):浅色 242/242/247,深色纯黑一档。
    static let panelColor = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.06, alpha: 1)
            : UIColor(red: 242 / 255, green: 242 / 255, blue: 247 / 255, alpha: 1)
    })

    var body: some View {
        DesignMetrics.reducesTransparency(reduceTransparency) ? Self.panelColor : .clear
    }
}

/// 一行行程项在列表里的位置,供 `entryGroupGlass` 在列表背后按组画玻璃。
private struct EntryGroupFrame {
    let bounds: Anchor<CGRect>
    let selected: Bool
}

private struct EntryGroupFramesKey: PreferenceKey {
    static let defaultValue: [String: [EntryGroupFrame]] = [:]
    static func reduce(value: inout [String: [EntryGroupFrame]],
                       nextValue: () -> [String: [EntryGroupFrame]]) {
        value.merge(nextValue()) { $0 + $1 }
    }
}
