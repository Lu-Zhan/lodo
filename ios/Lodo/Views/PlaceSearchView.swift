import SwiftUI
import MapKit

/// 搜地名选点。用 `MKLocalSearch` —— 系统能力,不需要 API key,也**不要定位权限**
/// (只搜名字,不问"你在哪")。选中一条就把名字和经纬度一起带回去,地图上才画得出点;
/// 用户不搜、直接手输名字也行,那种情况下没有坐标,地图上就不显示这个点。
struct PlaceSearchView: View {
    /// 选中后回传:显示名 + 坐标。
    let onPick: (String, CLLocationCoordinate2D) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var failed = false

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
                } else if results.isEmpty && !query.isEmpty {
                    Text("没有找到这个地方。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(results, id: \.self) { item in
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
            }
            .searchable(text: $query, prompt: "搜索地点")
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
        }
    }

    private func search(_ text: String) async {
        searching = true
        failed = false
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            results = response.mapItems
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            // 用户自己取消/输入变化导致的取消不算失败,别红着脸报错。
            failed = (error as? MKError)?.code != .loadingThrottled
        }
        searching = false
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
