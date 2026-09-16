import SwiftUI
import SwiftData
import LodoCore

/// "旅行"页:第六个平级页面。列出每一次旅行,点进去是总览/按天/地图/价格四个视图。
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

    private var ongoing: [TravelTrip] { trips.filter { $0.isOngoing() } }
    private var upcoming: [TravelTrip] { trips.filter { $0.isUpcoming() } }
    private var past: [TravelTrip] {
        trips.filter { !$0.isOngoing() && !$0.isUpcoming() }
    }

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
                section("进行中", ongoing)
                section("即将出发", upcoming)
                section("已结束", past)
            }
            .navigationTitle("旅行")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .sidebarToolbarButton()
            .toolbar {
                if let chrome = sidebarChrome, !chrome.hidesChrome {
                    ToolbarItem(placement: .primaryAction) {
                        Button { creating = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("新建旅行")
                    }
                }
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

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ list: [TravelTrip]) -> some View {
        if !list.isEmpty {
            Section(title) {
                ForEach(list) { trip in
                    NavigationLink(value: trip) {
                        row(trip)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            pendingDelete = trip
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private func row(_ trip: TravelTrip) -> some View {
        let count = memoryItems.filter { $0.isTravel && $0.travelTripUUID == trip.uuid }.count
        return VStack(alignment: .leading, spacing: 3) {
            Text(trip.title.isEmpty ? "未命名旅行" : trip.title)
                .font(.subheadline.weight(.medium))
            Text("\(dateRange(trip)) · \(trip.dayCount) 天 · \(count) 项")
                .font(.footnote)
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
                              notes: "看樱花,顺便逛秋叶原。")
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

/// 新建/编辑一次旅行本身(名字、日期、备注)。
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
                    TextField("去哪儿,如 东京四日", text: $title)
                    DatePicker("出发", selection: $start, displayedComponents: .date)
                    DatePicker("返程", selection: $end, displayedComponents: .date)
                    if hasInvalidRange {
                        Text("返程早于出发,改一下才能保存。")
                            .font(.footnote)
                            .foregroundStyle(.red)
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
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trip {
            trip.title = trimmed
            trip.startDate = start
            trip.endDate = end
            trip.notes = notes
            try? context.save()
        } else {
            let created = TravelTrip(title: trimmed, startDate: start, endDate: end, notes: notes)
            context.insert(created)
            try? context.save()
            onCreated(created)
        }
        dismiss()
    }
}
