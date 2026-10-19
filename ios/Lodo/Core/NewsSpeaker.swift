import Foundation
import AVFoundation
import NaturalLanguage
import Observation
import LodoCore

/// 新闻朗读:系统 AVSpeechSynthesizer 在本机合成,不联网、不走 AI 服务商。
/// 要念的文字由纯逻辑 `NewsSpeech` 拼好、切段;这里按文字本身认语言挑语音
/// (英文文章用英文语音念,不跟应用内语言走)。
///
/// 同一时间只念一样东西:`speakingID` 标着正在念的是哪一篇/哪份总结,
/// 各处按钮据此显示「停止朗读」。iOS 上音频会话设成 `.playback`,静音键开着也能听到;
/// 离开 app 后会停(没开后台音频模式)。
@MainActor
@Observable
final class NewsSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = NewsSpeaker()

    /// 正在念的那一项(文章 uuid、"digest"…),没在念时为 nil。
    private(set) var speakingID: String?

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// 还没念完的段数;念完最后一段才算结束(中途被打断的不算)。
    @ObservationIgnored private var remaining = 0

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ id: String) -> Bool { speakingID == id }

    /// 正在念这一项就停,否则从头念它(念别的会被打断)。
    func toggle(id: String, text: String) {
        if speakingID == id {
            stop()
        } else {
            speak(id: id, text: text)
        }
    }

    func speak(id: String, text: String) {
        stop()
        let chunks = NewsSpeech.chunks(text)
        guard !chunks.isEmpty else { return }
        activateSession()
        let voice = Self.voice(for: text)
        remaining = chunks.count
        speakingID = id
        for chunk in chunks {
            let utterance = AVSpeechUtterance(string: chunk)
            utterance.voice = voice
            utterance.postUtteranceDelay = 0.15
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        guard speakingID != nil || synthesizer.isSpeaking else { return }
        remaining = 0
        speakingID = nil
        synthesizer.stopSpeaking(at: .immediate)
        deactivateSession()
    }

    // MARK: - 语音

    /// 认出文字的主要语言,挑那种语言的系统语音;认不出就按应用内语言。
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1000)))
        let code: String
        switch recognizer.dominantLanguage {
        case .simplifiedChinese?: code = "zh-CN"
        case .traditionalChinese?: code = "zh-TW"
        case .english?: code = "en-US"
        case .japanese?: code = "ja-JP"
        case .korean?: code = "ko-KR"
        case let language?: code = language.rawValue
        case nil: code = AppSettings.language == .en ? "en-US" : "zh-CN"
        }
        return AVSpeechSynthesisVoice(language: code)
            ?? AVSpeechSynthesisVoice(language: AppSettings.language == .en ? "en-US" : "zh-CN")
    }

    // MARK: - 音频会话

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.remaining > 0 else { return }
            self.remaining -= 1
            if self.remaining == 0 {
                self.speakingID = nil
                self.deactivateSession()
            }
        }
    }
}
