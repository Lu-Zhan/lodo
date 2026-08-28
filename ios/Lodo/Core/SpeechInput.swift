import Foundation
import Speech
import AVFoundation
import LodoCore

/// 语音听写:两条引擎路径由 AppSettings.sttEngine 决定——
/// "system"(默认改前的行为)是 AVAudioEngine 采集 + SFSpeechRecognizer 实时转写,
/// 边说边出局部文本;"qwenASR"(现默认)是 AVAudioRecorder 整段录音,停止后一次性
/// 上传给 QwenASRClient 拿转写结果,没有局部文本,靠 isProcessing 表示"识别中"。
/// 转写结果通过 `transcript` 更新,停止后保留最终文本。`stop()` 结束采集并转写/
/// 保留结果;`cancel()` 同样结束采集,但丢弃已录内容、不转写、不留 transcript。
@MainActor
@Observable
final class SpeechInput {
    var transcript = ""
    var isRecording = false
    /// 云端引擎专用:录音已停止、转写请求仍在进行中。系统引擎路径这个值恒为 false。
    var isProcessing = false
    var errorText: String?
    /// 录音中的实时电平,归一化到 0...1,供 UI 画波形动画用。非录音状态恒为 0。
    private(set) var audioLevel: Float = 0

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 静音自动停止:最近一次识别到新内容/检测到声音(或开始录音)的时刻。
    private var lastActivityAt = Date()
    private var silenceWatchTask: Task<Void, Never>?
    /// 云端引擎专用:比静音检测(300ms 一次)更密的电平采样循环,给波形动画用。
    /// 系统引擎路径不需要这个——它的电平直接在 installTap 的缓冲区回调里顺带算。
    private var levelWatchTask: Task<Void, Never>?

    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?
    /// 电平低于这个值(dBFS)视为静音,用于云端引擎路径的静音自动停止判断。
    private static let silenceThresholdDB: Float = -35
    /// 波形电平归一化的 dB 下限——低于这个值一律视为静止(振幅 0)。
    private static let levelFloorDB: Float = -50

    func toggle() {
        if isRecording {
            stop()
        } else {
            Task { await start() }
        }
    }

    private func start() async {
        errorText = nil
        transcript = ""
        if AppSettings.sttEngine == "qwenASR" {
            await startQwenASR()
        } else {
            await startSystem()
        }
    }

    private func startSystem() async {
        let auth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard auth == .authorized else {
            errorText = "语音识别未授权,请到系统设置中开启。"
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorText = "麦克风未授权,请到系统设置中开启。"
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            errorText = "语音识别暂不可用。"
            return
        }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                request.append(buffer)
                let level = Self.normalizedLevel(fromDB: Self.averageDB(of: buffer))
                Task { @MainActor in self?.audioLevel = level }
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            lastActivityAt = Date()
            watchSilence()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        self.lastActivityAt = Date()
                    }
                    if error != nil || result?.isFinal == true {
                        self.stop()
                        self.task = nil
                        self.request = nil
                    }
                }
            }
        } catch {
            errorText = "无法启动录音:\(error.localizedDescription)"
            stop()
        }
    }

    /// 云端引擎只需要麦克风权限,不用 SFSpeechRecognizer 就不请求语音识别权限。
    private func startQwenASR() async {
        guard QwenASRClient.isConfigured else {
            errorText = QwenASRError.noKey.localizedDescription
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            errorText = "麦克风未授权,请到系统设置中开启。"
            return
        }

        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

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
            recorder.record()
            audioRecorder = recorder
            recordingURL = url
            isRecording = true
            lastActivityAt = Date()
            watchSilence()
            watchLevel()
        } catch {
            errorText = "无法启动录音:\(error.localizedDescription)"
            stop()
        }
    }

    /// 云端引擎专用:每 80ms 读一次 AVAudioRecorder 的电平,写进 audioLevel。
    private func watchLevel() {
        levelWatchTask?.cancel()
        levelWatchTask = Task { [weak self] in
            while let self, self.isRecording, !Task.isCancelled {
                self.audioRecorder?.updateMeters()
                let db = self.audioRecorder?.averagePower(forChannel: 0) ?? Self.levelFloorDB
                self.audioLevel = Self.normalizedLevel(fromDB: db)
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    /// 静音超过设置时长(0 = 关闭,不自动停止)自动停止录音。系统引擎靠"最近一次
    /// 出局部转写文本"判断活跃;云端引擎没有局部结果,靠录音电平判断。
    private func watchSilence() {
        silenceWatchTask?.cancel()
        silenceWatchTask = Task { [weak self] in
            while let self, self.isRecording, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled, self.isRecording else { return }
                if AppSettings.sttEngine == "qwenASR" {
                    self.audioRecorder?.updateMeters()
                    let level = self.audioRecorder?.averagePower(forChannel: 0) ?? -160
                    if level > Self.silenceThresholdDB { self.lastActivityAt = Date() }
                }
                let timeout = AppSettings.agentSilenceTimeoutSeconds
                guard timeout > 0 else { continue }
                if Date().timeIntervalSince(self.lastActivityAt) >= Double(timeout) {
                    self.stop()
                    return
                }
            }
        }
    }

    /// 停止采集。系统引擎:识别任务继续把已缓冲的音频出完最终结果。
    /// 云端引擎:异步把整段录音发给 QwenASRClient,结果/错误写回 transcript/errorText。
    func stop() {
        guard isRecording || audioEngine.isRunning || (audioRecorder?.isRecording ?? false) else { return }
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        levelWatchTask?.cancel()
        levelWatchTask = nil
        isRecording = false
        audioLevel = 0

        if AppSettings.sttEngine == "qwenASR" {
            audioRecorder?.stop()
            audioRecorder = nil
            let url = recordingURL
            recordingURL = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
            #endif
            guard let url else { return }
            Task { await transcribeQwenASR(fileURL: url) }
        } else {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            request?.endAudio()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    /// 取消采集:和 stop() 一样结束录音/引擎,但丢弃已录内容——不转写、不留
    /// transcript。系统引擎路径用 task?.cancel() 而不是 endAudio() 等最终结果,
    /// 避免取消后异步冒出一段迟到的转写文本。
    func cancel() {
        guard isRecording else { return }
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        levelWatchTask?.cancel()
        levelWatchTask = nil
        isRecording = false
        audioLevel = 0
        transcript = ""
        errorText = nil

        if AppSettings.sttEngine == "qwenASR" {
            audioRecorder?.stop()
            audioRecorder = nil
            let url = recordingURL
            recordingURL = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
            #endif
            if let url { try? FileManager.default.removeItem(at: url) }
        } else {
            task?.cancel()
            task = nil
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            request?.endAudio()
            request = nil
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    /// 缓冲区的均方根电平(dBFS),用于系统引擎路径的波形动画——安静时数值很小,
    /// log10(0) 会得 -inf,提前收口到 levelFloorDB。
    private static func averageDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return levelFloorDB }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return levelFloorDB }
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        guard rms > 0 else { return levelFloorDB }
        return 20 * log10(rms)
    }

    /// dBFS 归一化到 0...1,levelFloorDB 以下视为静止,0dB(满量程)视为最大振幅。
    private static func normalizedLevel(fromDB db: Float) -> Float {
        let clamped = max(levelFloorDB, min(0, db))
        return (clamped - levelFloorDB) / -levelFloorDB
    }

    private func transcribeQwenASR(fileURL: URL) async {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let data = try? Data(contentsOf: fileURL) else {
            errorText = "无法读取录音文件。"
            return
        }
        isProcessing = true
        defer { isProcessing = false }
        do {
            transcript = try await QwenASRClient.transcribe(wavData: data)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
