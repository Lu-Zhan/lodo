import SwiftUI
import MapKit
import LodoCore

/// 搜地名选点。用 `MKLocalSearch` —— 系统能力,不需要 API key,也**不要定位权限**
/// (只搜名字,不问"你在哪")。选中一条就把名字和经纬度一起带回去,地图上才画得出点;
/// 用户不搜、直接手输名字也行,那种情况下没有坐标,地图上就不显示这个点。
///
/// 结果**按国家分成两段**:这趟旅行所在国家的排在上面,别的国家的收进「其他地区」。
/// `MKLocalSearch` 会按设备所在地做区域偏置,在国内网络上搜「清水寺」第一条是杭州
/// 一个同名的地方(详见 `PlaceGeocoder` 文件头),不分段的话用户点第一条就把
/// 日本的行程钉到了浙江。不是直接滤掉——中途去别的国家转机、顺道去一趟都是真事,
/// 只是不该排在前面、也不该看不出来它在哪儿。
///
/// **苹果搜不到时可以改搜 OpenStreetMap**(Nominatim,见 `PlaceGeocoder` 文件头:
/// 国内网络上苹果只给中国数据,国外地点在上面那两段里根本不会出现)。
/// Nominatim 的使用规定**不允许边打字边搜**,所以它只在按下键盘上的搜索键、
/// 或点列表里那一行「在 OpenStreetMap 中搜索」时才发一次;打字过程中仍然只用苹果。
/// 按旅行的国家筛,数据按 ODbL 要求在分段脚注里署名。
struct PlaceSearchView: View {
    /// 选中后回传:显示名 + 坐标。
    let onPick: (String, CLLocationCoordinate2D) -> Void
    /// 消歧用的城市/国家,如"东京 日本"。带着它先搜一次,搜不到再单搜用户输入的词。
    var hint: String?
    /// 这趟旅行应该在哪个国家(ISO 码);认不出来时 nil,那就不分段。
    var region: String?
    /// 这趟旅行里已有的某个坐标。OpenStreetMap 的结果按离它的远近排——同名的
    /// 「清水寺」日本有十几座,Nominatim 自己的排序会把福冈那座排在京都前面。
    var anchor: CLLocationCoordinate2D?

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var failed = false
    /// OpenStreetMap 那一段:结果、这批结果对应的查询词、是否正在查。
    @State private var osmResults: [OSMGeocode.Place] = []
    @State private var osmQuery: String?
    @State private var osmSearching = false
    @State private var osmFailed = false

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if searching {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在搜索…").foregroundStyle(.secondary)
                    }
                } else if failed {
                    Text("搜索失败,检查一下网络再试。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if results.isEmpty && osmResults.isEmpty && !query.isEmpty
                            && osmQuery == trimmedQuery && !osmSearching {
                    Text("没有找到这个地方。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(inRegion, id: \.self) { row($0) }
                osmSection
                if !elsewhere.isEmpty {
                    Section {
                        ForEach(elsewhere, id: \.self) { row($0) }
                    } header: {
                        Text("其他地区")
                    } footer: {
                        Text("这些不在这次旅行的国家/地区,选了会画到别的地方去。")
                    }
                }
            }
            .searchable(text: $query, prompt: "搜索地点")
            // 按下搜索键:苹果那边在目标国家里没有结果时,顺手查一次 OpenStreetMap。
            .onSubmit(of: .search) {
                if inRegion.isEmpty || region == nil && results.isEmpty { searchOSM() }
            }
            .navigationTitle("选择地点")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            // 每次输入都取消上一次请求再起一个,并等 400ms——不防抖的话打字过程中
            // 每个字都会发一次网络请求,结果还会乱序回来盖掉最新那次。
            .onChange(of: query) { _, text in
                searchTask?.cancel()
                // OSM 的结果对应的是上一个词,换词就收掉(新词要再按一次搜索)。
                if osmQuery != nil {
                    osmResults = []
                    osmQuery = nil
                    osmFailed = false
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    results = []
                    searching = false
                    failed = false
                    return
                }
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    await search(trimmed)
                }
            }
            .onDisappear { searchTask?.cancel() }
            #if DEBUG
            // 截图验证用:--demo-place-search 后面跟一个词,填进去并在苹果搜完后查一次 OSM。
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard let index = args.firstIndex(of: "--demo-place-search"),
                      index + 1 < args.count else { return }
                query = args[index + 1]
                try? await Task.sleep(for: .seconds(4))
                searchOSM()
            }
            #endif
        }
    }

    /// OpenStreetMap 那一段:还没查过时是一行「在 OpenStreetMap 中搜索」,查过就列结果。
    @ViewBuilder
    private var osmSection: some View {
        if !trimmedQuery.isEmpty && !searching {
            if osmQuery == trimmedQuery && !osmResults.isEmpty {
                Section {
                    ForEach(osmResults) { place in
                        Button {
                            onPick(place.name, CLLocationCoordinate2D(latitude: place.latitude,
                                                                      longitude: place.longitude))
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).foregroundStyle(.primary)
                                if !place.displayName.isEmpty {
                                    Text(place.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                } header: {
                    Text("OpenStreetMap")
                } footer: {
                    Text("地图数据 © OpenStreetMap 贡献者")
                }
            } else if osmSearching {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在搜索 OpenStreetMap…").foregroundStyle(.secondary)
                }
            } else if osmQuery != trimmedQuery && (inRegion.isEmpty || region == nil) {
                Section {
                    Button {
                        searchOSM()
                    } label: {
                        Label("在 OpenStreetMap 中搜索「\(trimmedQuery)」", systemImage: "globe.asia.australia")
                    }
                } footer: {
                    Text(osmFailed ? "OpenStreetMap 搜索失败,检查一下网络再试。"
                                   : "苹果地图在当前网络下可能只有中国大陆的数据,找不到国外地点时可以试试这里。")
                }
            }
        }
    }

    private func searchOSM() {
        let text = trimmedQuery
        guard !text.isEmpty, !osmSearching, osmQuery != text else { return }
        osmSearching = true
        osmFailed = false
        Task {
            // 不给 viewbox:它会让 Nominatim 只挑附近的,把别的城市里最有名的那个挤掉;
            // 附近的挪到前面由 arrangeForPicker 做。
            let places = await PlaceGeocoder.osmSearch(text, region: region, anchor: nil).map {
                OSMGeocode.arrangeForPicker($0, anchor: anchor.map {
                    TravelCoordinate(latitude: $0.latitude, longitude: $0.longitude) })
            }
            // 查的时候用户又改了词:这批结果作废。
            guard text == trimmedQuery else {
                osmSearching = false
                return
            }
            osmResults = places ?? []
            osmFailed = places == nil
            osmQuery = places == nil ? nil : text
            osmSearching = false
        }
    }

    /// 在目标国家里的结果(不知道国家时就是全部)。
    private var inRegion: [MKMapItem] {
        guard region != nil else { return results }
        return results.filter { PlaceRegion.matches(region, $0.placemark.isoCountryCode) }
    }

    /// 不在目标国家的结果。
    private var elsewhere: [MKMapItem] {
        guard region != nil else { return [] }
        return results.filter { !PlaceRegion.matches(region, $0.placemark.isoCountryCode) }
    }

    private func row(_ item: MKMapItem) -> some View {
        Button {
            onPick(displayName(of: item), item.placemark.coordinate)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(of: item))
                    .foregroundStyle(.primary)
                if let address = addressLine(of: item) {
                    Text(address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func search(_ text: String) async {
        searching = true
        failed = false
        // 先带上城市/国家搜一次(同 PlaceGeocoder):「清水寺 京都 日本」比光搜
        // 「清水寺」更容易落在对的地方。这一次在目标国家里没结果才退回单搜。
        if let qualified = qualifiedQuery(text), await run(qualified), !inRegion.isEmpty {
            searching = false
            return
        }
        guard !Task.isCancelled else { return }
        _ = await run(text)
        searching = false
    }

    private func qualifiedQuery(_ text: String) -> String? {
        guard let hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hint.isEmpty, !text.contains(hint) else { return nil }
        return "\(text) \(hint)"
    }

    /// 发一次搜索,回传"这次有没有拿到结果"(取消/失败都算没有)。
    private func run(_ query: String) async -> Bool {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return false }
            results = response.mapItems
            failed = false
            return !response.mapItems.isEmpty
        } catch {
            guard !Task.isCancelled else { return false }
            results = []
            // 只有真正的网络/服务错误才算失败。「找不到」(带城市那次搜常见,见
            // PlaceGeocoder 文件头)和被限流都不是——原来把「找不到」也算成失败,
            // 后面那次单搜成功了还挂着「搜索失败」。
            let code = (error as? MKError)?.code
            failed = code != .loadingThrottled && code != .placemarkNotFound
            return false
        }
    }

    private func displayName(of item: MKMapItem) -> String {
        item.name ?? item.placemark.title ?? "未命名"
    }

    private func addressLine(of item: MKMapItem) -> String? {
        let placemark = item.placemark
        let parts = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
        return parts.isEmpty ? placemark.title : parts.joined(separator: " · ")
    }
}
