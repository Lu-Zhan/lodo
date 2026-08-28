import Foundation
import CoreLocation

/// 定时任务用的单次定位:只在联网型任务执行时尝试一次,拿到大致城市名拼进
/// prompt 上下文,不持续追踪、不在后台常驻。未授权/定位失败/超时一律静默
/// 返回 nil——定时任务本身不因为定位失败而报错,用户仍可以在 prompt 里自己
/// 写死城市名。macOS 没有"使用时"授权这一档,只有 authorizedAlways。
@MainActor
final class LocationHelper: NSObject, CLLocationManagerDelegate {
    private static let shared = LocationHelper()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    private override init() {
        super.init()
        manager.delegate = self
    }

    /// 反地理编码出的城市名;拿不到城市名时退化用省/州名,都拿不到返回 nil。
    static func requestCity() async -> String? {
        guard let location = await shared.requestLocation() else { return nil }
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let placemark = placemarks?.first else { return nil }
        return placemark.locality ?? placemark.administrativeArea
    }

    private var isAuthorized: Bool {
        #if os(macOS)
        manager.authorizationStatus == .authorizedAlways
        #else
        manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways
        #endif
    }

    private func requestLocation() async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined {
            #if os(macOS)
            manager.requestAlwaysAuthorization()
            #else
            manager.requestWhenInUseAuthorization()
            #endif
            // 授权弹窗结果通过 delegate 回调,这里轮询等一下,避免无限期挂起。
            for _ in 0..<20 where manager.authorizationStatus == .notDetermined {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard isAuthorized else { return nil }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.resume(with: nil)
            }
        }
    }

    private func resume(with location: CLLocation?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: location)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.resume(with: locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resume(with: nil) }
    }
}
