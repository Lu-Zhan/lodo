import SwiftUI
import SwiftData
import LodoCore

/// "旅行"页:第六个平级页面。顶部是最近那次旅行的总览卡(进行中优先,其次最近要出发的,
/// 都没有才拿最近结束的那次),下面是其余进行中/即将出发的旅行,已经结束的收在最底下的
/// 折叠栏里(默认收起)。点进去顶部是旅行信息,下面按天/地图/价格三个视图。
/// 一次旅行里的航班/住宿/地点本身就是记忆条目(打了「旅行」保留标签),所以订票
/// 确认单能当附件存、能被记忆搜索和"问 AI"命中。
struct TravelListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\TravelTrip.startDate, order: .reverse)])
    private var trips: [TravelTrip]
    @Query private var memoryItems: [MemoryItem]

    @State private var path: [TravelTrip] = []
    @State private var creating = false
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
                            Text("建一次旅行,把航班、住宿、想去的地方都放进去,可以按天看,也可以看花了多少。")
                        } actions: {
                            Button("新建旅行") { creating = true }
                                .glassProminentButton()
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
                        Text(featured.isOngoing() || featured.isUpcoming() ? "最近旅行" : "上一次旅行")
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
            .navigationTitle("旅行")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sidebarToolbarButton()
            .floatingAddAction(isVisible: path.isEmpty && !(sidebarChrome?.hidesChrome ?? false)) {
                Button { creating = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建旅行")
            }
            .navigationDestination(for: TravelTrip.self) { trip in
                TravelDetailView(trip: trip)
            }
            .sheet(isPresented: $creating) {
                TripEditView(trip: nil) { path = [$0] }
            }
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
                Text("这次旅行下面的航班、住宿、地点会一起删掉(它们同时是记忆条目)。")
            }
            #if DEBUG
            .onAppear(perform: applyDemoArgumentsIfNeeded)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    @Environment(\.sidebarChrome) private var sidebarChrome

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
            Group {
                if trip.title.isEmpty { Text("未命名旅行") } else { Text(trip.title) }
            }
            .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                if let location = trip.locationText {
                    Label(location, systemImage: "mappin.and.ellipse")
                }
                Label("\(dateRange(trip)) · 共 \(trip.dayCount) 天", systemImage: "calendar")
            }
            .font(.body)
            .foregroundStyle(.secondary)

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
                            Text("\(next.title) · \(Self.nextFormatter.string(from: start))")
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

    private static let nextFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    // MARK: - 行

    private func row(_ trip: TravelTrip) -> some View {
        let count = memoryItems.filter { $0.isTravel && $0.travelTripUUID == trip.uuid }.count
        return VStack(alignment: .leading, spacing: 3) {
            Text(trip.title.isEmpty ? "未命名旅行" : trip.title)
                .font(.body.weight(.medium))
            if let location = trip.locationText {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(dateRange(trip)) · \(trip.dayCount) 天 · \(count) 项")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// 日期区间先拼成一个串,让上面那句只剩三个占位符——字符串目录里
    /// "%@ · %lld 天 · %lld 项" 比五个占位符好翻译得多。
    private func dateRange(_ trip: TravelTrip) -> String {
        Self.formatter.string(from: trip.startDate) + " – "
            + Self.formatter.string(from: trip.endDate)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日"
        return f
    }()

    #if DEBUG
    /// 截图验证用:simctl 点不了表单,启动参数直接塞一次样板旅行。
    private func applyDemoArgumentsIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--demo-travel") else { return }
        // 种子只在空库时铺,但"直接 push 进详情"每次都要生效——第二次启动时库里
        // 已经有旅行了,不能连 push 一起挡掉。
        let trip = trips.first ?? seedDemoTrip()
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
        TravelStore.create(
            tripUUID: trip.uuid, kind: .place, title: "teamLab 无边界",
            start: at(2, 13), price: 3800, currency: "JPY",
            placeName: "台场", latitude: 35.6256, longitude: 139.7756, context: context)
        TravelStore.create(
            tripUUID: trip.uuid, kind: .place, title: "秋叶原(还没定时间)",
            currency: "JPY", placeName: "秋叶原", context: context)
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
    @State private var start = Date()
    @State private var end = Date()
    @State private var notes = ""
    @State private var city = ""
    @State private var country = ""
    @State private var didLoad = false

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
                    TextField("名字,如 东京四日", text: $title)
                }
                Section("目的地") {
                    TextField("城市,如 东京", text: $city)
                    TextField("国家,如 日本", text: $country)
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
                Section("备注") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 80)
                }
            }
            .navigationTitle(trip == nil ? "新建旅行" : "编辑旅行")
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

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let trip else {
            end = Calendar.current.date(byAdding: .day, value: 2, to: start) ?? start
            return
        }
        title = trip.title
        start = trip.startDate
        end = trip.endDate
        notes = trip.notes
        city = trip.city
        country = trip.country
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let city = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let country = country.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trip {
            trip.title = trimmed
            trip.startDate = start
            trip.endDate = end
            trip.notes = notes
            trip.city = city
            trip.country = country
            try? context.save()
        } else {
            let created = TravelTrip(title: trimmed, startDate: start, endDate: end, notes: notes,
                                     city: city, country: country)
            context.insert(created)
            try? context.save()
            onCreated(created)
        }
        dismiss()
    }
}
