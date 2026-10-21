import Foundation
import AVFoundation
import LodoCore

/// Watch 的语音输入:watchOS 没有 Speech 框架(SDK 里没有 SFSpeechRecognizer /
/// SpeechAnalyzer),所以只走 iPhone 那条云端路径——AVAudioRecorder 整段录音,停下后
/// 一次性交给 `QwenASRClient` 转写(内置 key,和手机共用同一个服务)。
///
/// 和 iPhone `SpeechInput` 的 qwenASR 分支同一套参数:16kHz 单声道 16 位 PCM、
/// 80ms 一次电平(给波形动画)、300ms 一次静音检测。手表上**静音自动停**是主路径
/// (抬腕说完就等结果,不用再点一下),所以设置里关掉(0)时这里仍按 2 秒算。
@MainActor
@Observable
final class WatchSpeechInput {
    enum State: Equatable {
        case idle
        /// 在等麦克风权限 / 起音频会话。界面上和 idle 一样,但不许再点一次重入。
        case starting
        case recording
        /// 录音已停、转写请求还在路上。
        case transcribing
    }

    private(set) var state: State = .idle
    /// 录音中的实时电平,0...1,喂给波形。
    private(set) var audioLevel: Float = 0

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var levelTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?
    /// 每次 start / cancel 都换一个代次:取消后再开始的新一轮,不会被上一轮迟到的
    /// 权限结果或转写结果串进来(旧的那一轮回来时核对代次,对不上就丢掉)。
    private var generation = 0
    private var lastActivityAt = Date()
    /// 一直没出声就自动停的上限,免得抬腕误触后录个没完。
    private static let maxDuration: TimeInterval = 60
    private var startedAt = Date()
    /// 一次也没超过静音阈值(全程没说话)就不发转写请求。
    private var heardVoice = false

    private static let silenceThresholdDB: Float = -35
    private static let levelFloorDB: Float = -50

    private static var silenceTimeout: TimeInterval {
        let configured = AppSettings.agentSilenceTimeoutSeconds
        return configured > 0 ? TimeInterval(configured) : 2
    }

    /// 开始录音;没权限/没配置转写服务时返回错误文案,调用方显示出来。
    /// `onFinish` 在自动或手动停下并转写完之后回调:成功是文字,没说话是空串。
    func start(onFinish: @escaping (Result<String, Error>) -> Void) async -> String? {
        guard state == .idle else { return nil }
        guard QwenASRClient.isConfigured else {
            return QwenASRError.noKey.localizedDescription
        }
        generation += 1
        let round = generation
        state = .starting
        let granted = await AVAudioApplication.requestRecordPermission()
        // 等权限期间被取消(关掉了助手、又开了新的一轮):什么都不做,也不报错。
        guard round == generation, state == .starting else { return nil }
        guard granted else {
            state = .idle
            return LocalizedStrings.text(.ios_core_microphone_permission_denied,
                                         language: AppSettings.language)
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("wav")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                throw NSError(domain: "WatchSpeechInput", code: 1)
            }
            self.recorder = recorder
            fileURL = url
            state = .recording
            startedAt = Date()
            lastActivityAt = Date()
            heardVoice = false
            watch(onFinish: onFinish)
            return nil
        } catch {
            teardown()
            return LocalizedStrings.text(.ios_core_recording_start_failed,
                                         language: AppSettings.language) + error.localizedDescription
        }
    }

    /// 电平 + 静音检测合在一个循环里(手表上少一个常驻 Task)。
    private func watch(onFinish: @escaping (Result<String, Error>) -> Void) {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            var tick = 0
            while let self, self.state == .recording, !Task.isCancelled {
                self.recorder?.updateMeters()
                let db = self.recorder?.averagePower(forChannel: 0) ?? Self.levelFloorDB
                self.audioLevel = Self.normalized(db)
                tick += 1
                // 80ms × 4 ≈ 300ms 判一次静音,和手机同频。
                if tick % 4 == 0 {
                    if db > Self.silenceThresholdDB {
                        self.lastActivityAt = Date()
                        self.heardVoice = true
                    }
                    let silent = Date().timeIntervalSince(self.lastActivityAt)
                    // 没开口之前多给一点时间(抬腕到开口本来就要一两秒)。
                    let limit = self.heardVoice ? Self.silenceTimeout : max(Self.silenceTimeout, 5)
                    if silent >= limit || Date().timeIntervalSince(self.startedAt) >= Self.maxDuration {
                        self.finish(onFinish: onFinish)
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    /// 手动点「完成」。
    func stop(onFinish: @escaping (Result<String, Error>) -> Void) {
        guard state == .recording else { return }
        finish(onFinish: onFinish)
    }

    private func finish(onFinish: @escaping (Result<String, Error>) -> Void) {
        let url = fileURL
        let heard = heardVoice
        recorder?.stop()
        teardown()
        guard let url else { return }
        guard heard else {
            try? FileManager.default.removeItem(at: url)
            onFinish(.success(""))
            return
        }
        state = .transcribing
        let round = generation
        transcribeTask = Task {
            defer {
                try? FileManager.default.removeItem(at: url)
                if round == self.generation {
                    if self.state == .transcribing { self.state = .idle }
                    self.transcribeTask = nil
                }
            }
            let result: Result<String, Error>
            do {
                let data = try Data(contentsOf: url)
                result = .success(try await QwenASRClient.transcribe(wavData: data))
            } catch {
                result = .failure(error)
            }
            // 取消过(或已经开始了下一轮)的结果一律丢掉。
            guard !Task.isCancelled, round == self.generation, self.state == .transcribing else { return }
            onFinish(result)
        }
    }

    /// 取消:丢掉录音,不转写;转写中取消则丢掉结果。
    func cancel() {
        generation += 1
        transcribeTask?.cancel()
        transcribeTask = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        recorder?.stop()
        teardown()
    }

    private func teardown() {
        levelTask?.cancel()
        levelTask = nil
        recorder = nil
        fileURL = nil
        audioLevel = 0
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private static func normalized(_ db: Float) -> Float {
        let clamped = max(levelFloorDB, min(0, db))
        return (clamped - levelFloorDB) / -levelFloorDB
    }
}
