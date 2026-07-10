#if os(iOS)
import Foundation
import Speech
import AVFoundation

/// 中文语音听写:AVAudioEngine 采集 + SFSpeechRecognizer 实时转写。
/// 转写结果通过 `transcript` 增量更新,停止后保留最终文本。
@MainActor
@Observable
final class SpeechInput {
    var transcript = ""
    var isRecording = false
    var errorText: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

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
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
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

    /// 停止采集;识别任务继续把已缓冲的音频出完最终结果。
    func stop() {
        guard isRecording || audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }
}
#endif
