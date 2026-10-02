import SwiftUI
import SwiftData
import LodoCore

/// "旅行"页:第六个平级页面。顶部是最近那次旅行的总览卡(进行中优先,其次最近要出发的,
/// 都没有才拿最近结束的那次),下面是其余进行中/即将出发的旅行,已经结束的收在最底下的
/// 折叠栏里(默认收起)。点进去顶部是旅行信息,下面按天/地图/价格三个视图。
/// 一次旅行里的航班/住宿/地点本身就是记忆条目(打了「旅行」保留标签),所以订票
/// 确认单能当附件存、能被记忆搜索和"问 AI"命中。
struct TravelListView: View {
    /// 非 nil 时 push 进这次旅行的详情页(AI 对话里那条跳转小条,经外壳的
    /// `ItemNavigator` 递进来),消费后置回 nil。
    @Binding var openTripRequest: UUID?

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\TravelTrip.startDate, order: .reverse)])
    private var trips: [TravelTrip]
    @Query private var memoryItems: [MemoryItem]

    @State private var path: [TravelTrip] = []
    @State private var pendingDelete: TravelTrip?
    @State private var showsPast = false
    @AppStorage(AppSettings.languageKey) private var languageRaw = AppLanguage.zhHans.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .zhHans }

    /// 进行中与即将出发的,按出发日从近到远(@Query 是倒序,这里翻过来)。
    private var active: [TravelTrip] {
        trips.filter { $0.isOngoing() || $0.isUpcoming() }
            .sorted { $0.startDate < $1.startDate }
    }
    /// 已结束的,最近结束的在前。
    private var past: [TravelTrip] {
        trips.filter { !$0.isOngoing() && !$0.isUpcoming() }
            .sorted { $0.endDate > $1.endDate }
    }

    /// 总览卡上的那一次:进行中/最近要出发的;一次都没有才退回最近结束的那次,
    /// 免得只剩历史旅行时整页只有一条收起的折叠栏。
    private var featured: TravelTrip? { active.first ?? past.first }
    private var others: [TravelTrip] { active.filter { $0.uuid != featured?.uuid } }
    private var folded: [TravelTrip] { past.filter { $0.uuid != featured?.uuid } }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if trips.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("还没有旅行", systemImage: "suitcase.rolling")
                        } description: {
                            Text("在底下那条「问问 AI」里说一句要去哪儿玩几天,AI 会排出行程;航班、住宿、想去的地方都放进去之后,可以按天看,也可以看花了多少。")
                        }
                    }
                }
                if let featured {
                    Section {
                        NavigationLink(value: featured) {
                            overviewCard(featured)
                        }
                        .swipeActions(edge: .trailing) { deleteButton(featured) }
                    } header: {
                        Text(LocalizedStringKey(featured.isOngoing() || featured.isUpcoming()
                                                ? "最近旅行" : "上一次旅行"))
                    }
                }
                if !others.isEmpty {
                    Section("其他旅行") {
                        ForEach(others) { tripLink($0) }
                    }
                }
                if !folded.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showsPast) {
                            ForEach(folded) { tripLink($0) }
                        } label: {
                            Text("已结束 · \(folded.count)")
                        }
                    }
                }
            }
            .pageTitle("旅行")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sidebarToolbarButton()
            .askBar(focus: .travel, isVisible: path.isEmpty)
            .navigationDestination(for: TravelTrip.self) { trip in
                TravelDetailView(trip: trip)
            }
            // 从别的页面(目前是 AI 对话里的跳转小条)点进某一次旅行。onAppear 也要
            // 收一次:请求往往和"切到旅行页"同时到来,而这一页可能是这时才第一次
            // 构建的(没打开过的页面不构建,见 AppShellView.visited),那一下不会走
            // onChange。
            .onChange(of: openTripRequest) { _, _ in consumeOpenRequest() }
            .onAppear { consumeOpenRequest() }
            .onChange(of: trips.count) { _, _ in consumeOpenRequest() }
            .alert("删除这次旅行?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let trip = pendingDelete {
                        TravelStore.deleteTrip(trip, context: context)
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                switch pendingDelete?.shareRole {
                case .owner:
                    Text("这次旅行下面的航班、住宿、地点会一起删掉,并停止共享;成员会保留各自的副本,但不再同步。")
                case .participant:
                    Text("会退出这次共享并删掉你这边的副本,其他成员不受影响。")
                case nil:
                    Text("这次旅行下面的航班、住宿、地点会一起删掉(它们同时是记忆条目)。")
                }
            }
            #if DEBUG
            .onAppear(perform: applyDemoArgumentsIfNeeded)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    /// 消费一次"打开某次旅行"的请求。旅行已经被删掉(撤销写入、在别处删了)时
    /// 什么都不做,只把请求清掉——push 一个不存在的 trip 会直接进到一张空详情页。
    private func consumeOpenRequest() {
        guard let uuid = openTripRequest else { return }
        // 冷启动时 @Query 可能还没取到数据:请求先留着,等列表有了再试(trips.count 的 onChange)。
        // 不留的话这一下被当成"旅行已删",请求直接丢了。
        guard !trips.isEmpty else { return }
        openTripRequest = nil
        guard let trip = trips.first(where: { $0.uuid == uuid }) else { return }
        // 已经站在这次旅行的详情页上就什么都不用做;站在别的二级页上要换过去,
        // 所以整条 path 直接换掉而不是 append。
        guard path.last?.uuid != uuid else { return }
        path = [trip]
    }

    private func tripLink(_ trip: TravelTrip) -> some View {
        NavigationLink(value: trip) {
            row(trip)
        }
        .swipeActions(edge: .trailing) { deleteButton(trip) }
    }

    private func deleteButton(_ trip: TravelTrip) -> some View {
        Button(role: .destructive) {
            pendingDelete = trip
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 总览卡

    private func overviewCard(_ trip: TravelTrip) -> some View {
        let entries = TravelStore.entries(for: trip.uuid, from: memoryItems)
        return VStack(alignment: .leading, spacing: 8) {
            statusText(trip)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(trip.isOngoing() || trip.isUpcoming() ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text(trip.displayEmoji)
                    if trip.title.isEmpty { Text("未命名旅行") } else { Text(trip.title) }
                }
                .font(.title2.weight(.semibold))
                sharedBadge(trip)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let location = trip.locationText {
                    Label(location, systemImage: "mappin.and.ellipse")
                }
                Label("\(dateRange(trip)) · 共 \(trip.dayCount) 天", systemImage: "calendar")
            }
            .font(.body)
            .foregroundStyle(.secondary)

            // 那句概述只在这一页显示(详情页里不再重复,见 TravelDetailView.header)。
            if !trip.notes.isEmpty {
                Text(trip.notes)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            if entries.isEmpty {
                Text("还没有行程,点进去添加航班、住宿和想去的地方。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 16) {
                    ForEach(TravelItemKind.allCases, id: \.self) { kind in
                        let count = entries.filter { $0.kind == kind }.count
                        if count > 0 {
                            Label("\(count)", systemImage: kind.systemImage)
                                .accessibilityLabel(
                                    "\(LocalizedStrings.text(kind.titleKey, language: language)) \(count)")
                        }
                    }
                }
                .font(.body.monospacedDigit())
                if let next = nextEntry(entries), let start = next.start {
                    Divider()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("接下来")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Label {
                            Text("\(next.title) · \(LocalizedContent.dateTime(start, language: language))")
                        } icon: {
                            Image(systemName: next.kind.systemImage)
                                .foregroundStyle(.tint)
                        }
                        .font(.body)
                        .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// "进行中 · 第 2 天" / "明天出发" / "还有 5 天出发" / "已结束"。
    @ViewBuilder
    private func statusText(_ trip: TravelTrip) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = calendar.startOfDay(for: trip.startDate)
        let days = calendar.dateComponents([.day], from: today, to: start).day ?? 0
        if trip.isOngoing() {
            Text("进行中 · 第 \(1 - days) 天")
        } else if trip.isUpcoming() {
            if days <= 1 { Text("明天出发") } else { Text("还有 \(days) 天出发") }
        } else {
            Text("已结束")
        }
    }

    /// 还没开始的第一项(住宿铺在多天上,已入住的不算"接下来")。
    private func nextEntry(_ entries: [TravelEntry]) -> TravelEntry? {
        let now = Date()
        return entries
            .filter { ($0.start ?? .distantPast) >= now }
            .min { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    // MARK: - 行

    private func row(_ trip: TravelTrip) -> some View {
        let count = memoryItems.filter { $0.isTravel && $0.travelTripUUID == trip.uuid && $0.travelKind != nil }.count
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(trip.displayEmoji + " " + (trip.title.isEmpty
                     ? String(localized: "未命名旅行", bundle: .appLanguage(language), locale: language.locale)
                     : trip.title))
                    .font(.body.weight(.medium))
                sharedBadge(trip)
            }
            if let location = trip.locationText {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(dateRange(trip)) · \(trip.dayCount) 天 · \(count) 项")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !trip.notes.isEmpty {
                Text(trip.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    /// 共享中的旅行标题旁边一枚小人像。
    @ViewBuilder
    private func sharedBadge(_ trip: TravelTrip) -> some View {
        if trip.isShared {
            Image(systemName: "person.2.fill")
                .font(.footnote)
                .foregroundStyle(.tint)
                .accessibilityLabel("已共享")
        }
    }

    /// 日期区间先拼成一个串,让上面那句只剩三个占位符——字符串目录里
    /// "%@ · %lld 天 · %lld 项" 比五个占位符好翻译得多。
    private func dateRange(_ trip: TravelTrip) -> String {
        LocalizedContent.dateOnly(trip.startDate, language: language) + " – "
            + LocalizedContent.dateOnly(trip.endDate, language: language)
    }

    #if DEBUG
    /// 截图验证用:simctl 点不了表单,启动参数直接塞一次样板旅行。
    private func applyDemoArgumentsIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo-travel") else { return }
        // 种子只在空库时铺,但"直接 push 进详情"每次都要生效——第二次启动时库里
        // 已经有旅行了,不能连 push 一起挡掉。
        var trip = trips.first ?? seedDemoTrip()
        // 看共享旅行的头部(「已共享」标记)用:只改本地标记,不碰 CloudKit。
        if args.contains("--demo-travel-shared") {
            trip.shareRoleRaw = SharedTripRole.owner.rawValue
        }
        // 验证"认不出国家时刷新地点位置"用:一趟只有名字、城市国家都空、行程项都没坐标的旅行。
        if args.contains("--demo-travel-unknown-country") {
            trip = trips.first { $0.title == "京都三日" } ?? seedUnknownCountryTrip()
        }
        // 验证按天胶囊超过 6 格时的滚动:一趟 8 天的旅行。
        if args.contains("--demo-travel-long") {
            trip = trips.first { $0.title == "北海道八日" } ?? seedLongTrip()
        }
        // 验证"没填城市国家时提醒去填"用:名字里也看不出目的地。
        if args.contains("--demo-travel-no-location") {
            trip = trips.first { $0.title == "毕业旅行" } ?? seedUnknownCountryTrip(title: "毕业旅行")
        }
        // 截图验证用:给这次旅行挂两份样板文件(「文件」页),只铺一遍。
        if args.contains("--demo-travel-file-sample"),
           !TravelStore.files(for: trip.uuid, from: memoryItems).contains(where: { $0.title == "日本签证" }) {
            context.insert(MemoryItem(
                kind: .text, title: "日本签证", summary: "单次入境,停留 15 天,有效期至 2027 年 3 月",
                tags: [MemoryItem.travelTagName], sourceText: "日本签证 单次入境", status: .ready,
                travelTripUUID: trip.uuid))
            context.insert(MemoryItem(
                kind: .image, title: "酒店预订截图", summary: "新宿王子酒店 3 晚,含早",
                tags: [MemoryItem.travelTagName], status: .ready, travelTripUUID: trip.uuid))
            try? context.save()
        }
        if args.contains("--demo-travel-flight") {
            attachDemoFlight(to: trip)
        }
        if args.contains("--demo-travel-detail") {
            path = [trip]
        }
        if args.contains("--demo-travel-more") {
            seedMoreDemoTrips()
        }
        if args.contains("--demo-travel-past-expanded") {
            showsPast = true
        }
    }

    /// AI 规划出来的老旅行的样子:只有「京都三日」这个名字,城市国家都空,行程项都没坐标。
    private func seedLongTrip() -> TravelTrip {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: 20, to: calendar.startOfDay(for: Date()))!
        let trip = TravelTrip(title: "北海道八日", startDate: start,
                              endDate: calendar.date(byAdding: .day, value: 7, to: start)!,
                              city: "札幌", country: "日本")
        context.insert(trip)
        let places = ["大通公园", "小樽运河", "二世古", "洞爷湖", "登别地狱谷", "富良野", "美瑛", "旭山动物园"]
        for (offset, name) in places.enumerated() {
            TravelStore.create(
                tripUUID: trip.uuid, kind: .place, title: name,
                start: calendar.date(byAdding: .hour, value: 24 * offset + 10, to: start),
                placeName: name, context: context)
        }
        try? context.save()
        return trip
    }

    private func seedUnknownCountryTrip(title: String = "京都三日") -> TravelTrip {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: 10, to: calendar.startOfDay(for: Date()))!
        let trip = TravelTrip(title: title, startDate: start,
                              endDate: calendar.date(byAdding: .day, value: 2, to: start)!)
        context.insert(trip)
        for (offset, name) in [(0, "清水寺"), (1, "金阁寺"), (1, "岚山"), (2, "伏见稻荷大社")] {
            TravelStore.create(
                tripUUID: trip.uuid, kind: .place, title: name,
                start: calendar.date(byAdding: .hour, value: 24 * offset + 10, to: start),
                placeName: name, context: context)
        }
        try? context.save()
        return trip
    }

    /// 看"其他旅行"与"已结束"折叠栏的排版:一次更远的出发 + 两次已结束的,只铺一遍。
    private func seedMoreDemoTrips() {
        guard !trips.contains(where: { $0.title == "首尔周末" }) else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        context.insert(TravelTrip(title: "首尔周末", startDate: day(40), endDate: day(42),
                                  city: "首尔", country: "韩国"))
        context.insert(TravelTrip(title: "大理慢游", startDate: day(-60), endDate: day(-55),
                                  city: "大理", country: "中国"))
        context.insert(TravelTrip(title: "曼谷", startDate: day(-200), endDate: day(-196),
                                  city: "曼谷", country: "泰国"))
        try? context.save()
    }

    /// simctl 选不了相册里的截图,直接挂一份"导入过登机牌+航班动态截图"之后的样板信息看排版。
    private func attachDemoFlight(to trip: TravelTrip) {
        guard let item = TravelStore.items(for: trip.uuid, in: context)
            .filter({ $0.travelKind == .flight })
            .min(by: { ($0.travelStart ?? .distantFuture) < ($1.travelStart ?? .distantFuture) }),
              let start = item.travelStart else { return }
        let details = FlightDetails(
            airline: "中国国际航空", departureCode: "PEK", arrivalCode: "NRT",
            departureTerminal: "T3", arrivalTerminal: "T1", checkInCounter: "F01-F12",
            gate: "E23", boardingTime: start.addingTimeInterval(-40 * 60),
            estimatedDeparture: start.addingTimeInterval(25 * 60),
            seat: "32A", cabin: "经济舱", aircraft: "空客 A330-300",
            status: .delayed, updatedAt: Date().addingTimeInterval(-8 * 60))
        item.travelFlightData = FlightDetails.encode(details)
        try? context.save()
    }

    private func seedDemoTrip() -> TravelTrip {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: 3, to: calendar.startOfDay(for: Date()))!
        // 四日游就是 4 天(含首尾),别和标题对不上。
        let end = calendar.date(byAdding: .day, value: 3, to: start)!
        let trip = TravelTrip(title: "东京四日", startDate: start, endDate: end,
                              notes: "看樱花,顺便逛秋叶原。", city: "东京", country: "日本")
        context.insert(trip)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(byAdding: .hour, value: hour,
                          to: calendar.date(byAdding: .day, value: dayOffset, to: start)!)!
                .addingTimeInterval(TimeInterval(minute * 60))
        }
        TravelStore.create(
            tripUUID: trip.uuid, kind: .flight, title: "国航 北京–东京", code: "CA167",
            start: at(0, 9), end: at(0, 14), price: 3200, currency: "CNY",
            placeName: "东京成田机场", latitude: 35.7647, longitude: 140.3863,
            originName: "北京首都机场", originLatitude: 40.0799, originLongitude: 116.6031,
            context: context)
        TravelStore.create(
            tripUUID: trip.uuid, kind: .lodging, title: "新宿王子酒店",
            note: "含早,离车站 3 分钟。", start: at(0, 16), end: at(3, 11),
            price: 48000, currency: "JPY",
            placeName: "新宿", latitude: 35.6938, longitude: 139.7034, context: context)
        TravelStore.create(
            tripUUID: trip.uuid, kind: .place, title: "浅草寺",
            start: at(1, 10), price: 0, currency: "JPY",
            placeName: "浅草", latitude: 35.7148, longitude: 139.7967, context: context)
        // 和浅草寺同一天,按天视图里两点连成一条路线(地图上每天一个颜色)。
        TravelStore.create(
            tripUUID: trip.uuid, kind: .place, title: "上野公园",
            start: at(1, 14), price: 0, currency: "JPY",
            placeName: "上野", latitude: 35.7156, longitude: 139.7745, context: context)
        TravelStore.create(
            tripUUID: trip.uuid, kind: .train, title: "JR 山手线 上野–东京",
            start: at(1, 17), end: at(1, 17, 10), price: 170, currency: "JPY",
            placeName: "东京站", originName: "上野站", context: context)
        TravelStore.create(
            tripUUID: trip.uuid, kind: .place, title: "teamLab 无边界",
            start: at(2, 13), price: 3800, currency: "JPY",
            placeName: "台场", latitude: 35.6256, longitude: 139.7756, context: context)
        // 这一条**故意不给坐标**:打开详情页时由 TravelStore.fillMissingCoordinates
        // 按地名补上,截图里能看到它自己跑到地图上去。地名用当地写法「秋葉原」——
        // 简体的「秋叶原」在 Apple Maps 上只匹配得到国内的同名店铺,正好会被
        // PlaceGeocoder 的距离判据挡掉(那条判据本身也是这么试出来的)。
        TravelStore.create(
            tripUUID: trip.uuid, kind: .place, title: "秋叶原(还没定时间)",
            currency: "JPY", placeName: "秋葉原", context: context)
        TravelStore.create(
            tripUUID: trip.uuid, kind: .flight, title: "国航 东京–北京", code: "CA168",
            start: at(3, 15), end: at(3, 18), price: 2800, currency: "CNY",
            placeName: "北京首都机场", latitude: 40.0799, longitude: 116.6031,
            originName: "东京成田机场", originLatitude: 35.7647, originLongitude: 140.3863,
            context: context)
        try? context.save()
        return trip
    }
    #endif
}

/// 新建/编辑一次旅行本身(名字、城市、国家、日期、备注)。
struct TripEditView: View {
    /// nil = 新建。
    var trip: TravelTrip?
    /// 新建成功后把新旅行交出去(列表页拿它直接 push 进详情)。
    var onCreated: (TravelTrip) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    /// 标题前的 emoji,空串 = 默认 ✈️。
    @State private var emoji = ""
    @State private var start = Date()
    @State private var end = Date()
    @State private var notes = ""
    /// 目的地,至少一格。第一个就是 trip.city/country,其余存 extraDestinations
    /// (见 `TripDestination`)。
    @State private var destinations = [TripDestination()]
    @State private var didLoad = false
    /// 正在让 AI 重写备注。
    @State private var regenerating = false
    @State private var noteError: String?
    @Query private var memoryItems: [MemoryItem]

    /// 常用的旅行图标(交通、海岛、雪山、城市、美食……)。
    private static let emojiChoices = [
        "✈️", "🏖️", "🏝️", "🏔️", "⛷️", "🏙️", "🗼", "🏯", "⛩️", "🗽",
        "🎡", "🍜", "🍣", "🚄", "🚗", "⛺️", "🌸", "🍁", "🎒", "💼",
    ]

    private var hasInvalidRange: Bool {
        Calendar.current.startOfDay(for: end) < Calendar.current.startOfDay(for: start)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasInvalidRange
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        // 系统没有 emoji 选择器控件:这一格就是个输入框,切到 emoji 键盘
                        // 选一个即可,只留最后一个(见 TravelTrip.normalizedEmoji);
                        // 下面一排常用的点一下直接换。
                        TextField(TravelTrip.defaultEmoji, text: $emoji)
                            .font(.title2)
                            .multilineTextAlignment(.center)
                            .frame(width: 44)
                            .accessibilityLabel("旅行图标")
                            .onChange(of: emoji) { _, value in
                                let normalized = TravelTrip.normalizedEmoji(value)
                                if normalized != value { emoji = normalized }
                            }
                        Divider()
                        TextField("名字,如 东京四日", text: $title)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Self.emojiChoices, id: \.self) { choice in
                                Button {
                                    emoji = choice
                                } label: {
                                    Text(choice)
                                        .font(.title3)
                                        .frame(width: 40, height: 40)
                                        .background(
                                            Circle().fill(Color.accentColor.opacity(
                                                (emoji.isEmpty ? TravelTrip.defaultEmoji : emoji) == choice
                                                    ? 0.18 : 0)))
                                }
                                .pressable()
                                .accessibilityLabel(choice)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                } footer: {
                    Text("左边的图标会显示在旅行名前面,可以点下面的换,也可以切到 emoji 键盘输入。")
                }
                // 一次去好几个地方(北海道 + 上海)时每个目的地一段:搜地点、补地图坐标
                // 都会在这几个地方里找(见 TravelStore.geocodeContexts)。
                ForEach(destinations.indices, id: \.self) { index in
                    Section {
                        TextField("城市,如 东京", text: $destinations[index].city)
                        TextField("国家,如 日本", text: $destinations[index].country)
                        if index == destinations.count - 1 {
                            Button {
                                withAnimation(.lodoAware(.snappy)) {
                                    destinations.append(TripDestination())
                                }
                            } label: {
                                Label("添加目的地", systemImage: "plus.circle")
                            }
                        }
                    } header: {
                        HStack {
                            if destinations.count > 1 {
                                Text("目的地 \(index + 1)")
                            } else {
                                Text("目的地")
                            }
                            Spacer()
                            if destinations.count > 1 {
                                Button("移除", role: .destructive) {
                                    withAnimation(.lodoAware(.snappy)) {
                                        _ = destinations.remove(at: index)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .font(.footnote)
                                .textCase(nil)
                            }
                        }
                    } footer: {
                        if index == destinations.count - 1 && destinations.count > 1 {
                            Text("搜地点、在地图上找位置时会在这几个地方里找。")
                        }
                    }
                }
                Section("日期") {
                    DatePicker("出发", selection: $start, displayedComponents: .date)
                    DatePicker("返程", selection: $end, displayedComponents: .date)
                    if hasInvalidRange {
                        Text("返程早于出发,改一下才能保存。")
                            .font(.subheadline)
                            .foregroundStyle(LodoColor.critical)
                    }
                }
                Section {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                } header: {
                    HStack {
                        Text("备注")
                        Spacer()
                        // 备注就是旅行卡片上那句概述(AI 规划时也是它写的),所以这里
                        // 给一颗重写按钮:把旅行名/日期/行程摘要发过去,换一句新的。
                        // 没配 AI 或还没保存过这次旅行时不显示——前者调不通,后者
                        // 还没有行程可以参考,重写出来的只能是空话。
                        if DeepSeekClient.isConfigured, let trip {
                            Button {
                                regenerateNote(trip)
                            } label: {
                                if regenerating {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("重新生成", systemImage: "sparkles")
                                        .labelStyle(.titleAndIcon)
                                        .font(.footnote)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(regenerating)
                            .textCase(nil)
                        }
                    }
                } footer: {
                    if let noteError {
                        Text(noteError)
                            .foregroundStyle(LodoColor.critical)
                    } else {
                        Text("这句话会显示在旅行列表的卡片上。")
                    }
                }
            }
            .navigationTitle(LocalizedStringKey(trip == nil ? "新建旅行" : "编辑旅行"))
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
            .onAppear(perform: load)
        }
    }

    /// 让 AI 按这次旅行的行程重写一句备注。失败只在 footer 上报一行,不动原文
    /// ——重写不成还把用户自己写的那句冲掉就太蠢了。
    private func regenerateNote(_ trip: TravelTrip) {
        regenerating = true
        noteError = nil
        let entries = TravelStore.entries(for: trip.uuid, from: memoryItems)
        let days = TravelTrip(title: title, startDate: start, endDate: end).days
        let summary = TravelPlan.promptSummary(
            tripTitle: title.isEmpty ? trip.title : title, days: days, entries: entries)
        Task {
            do {
                notes = try await DeepSeekClient.suggestTripNote(summary: summary)
            } catch {
                noteError = error.localizedDescription
            }
            regenerating = false
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let trip else {
            end = Calendar.current.date(byAdding: .day, value: 2, to: start) ?? start
            return
        }
        title = trip.title
        emoji = trip.emoji
        start = trip.startDate
        end = trip.endDate
        notes = trip.notes
        destinations = trip.destinations.isEmpty ? [TripDestination()] : trip.destinations
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trip {
            trip.title = trimmed
            trip.emoji = emoji
            trip.startDate = start
            trip.endDate = end
            trip.notes = notes
            trip.destinations = destinations
            try? context.save()
        } else {
            let created = TravelTrip(title: trimmed, startDate: start, endDate: end, notes: notes)
            created.destinations = destinations
            created.emoji = emoji
            context.insert(created)
            try? context.save()
            onCreated(created)
        }
        dismiss()
    }
}
