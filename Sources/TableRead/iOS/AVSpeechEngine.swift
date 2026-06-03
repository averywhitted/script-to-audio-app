#if os(iOS)
import Foundation
import AVFoundation

// MARK: - System voice engine (AVSpeechSynthesizer)

/// On-device TTS using iOS system voices, including iOS 16+ enhanced/premium neural voices.
/// Completely private, free, zero dependencies. Audio is written as CAF (Core Audio Format).
final class AVSpeechEngine: IOSTTSEngine, @unchecked Sendable {
    let name = "System Voices"
    let audioExtension = ".caf"

    func isAvailable() -> Bool { true }

    func listVoices() -> [IOSVoiceInfo] {
        let all = AVSpeechSynthesisVoice.speechVoices()
        return all
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name < rhs.name
            }
            .map { v in
                let noteStr: String? = switch v.quality {
                case .premium: "Premium"
                case .enhanced: "Enhanced"
                default: nil
                }
                let genderStr: String? = switch v.gender {
                case .male: "M"
                case .female: "F"
                default: nil
                }
                return IOSVoiceInfo(
                    id: v.identifier,
                    label: v.name,
                    gender: genderStr,
                    locale: v.language,
                    note: noteStr
                )
            }
    }

    /// Synthesizes using AVSpeechSynthesizer.write(_:toBufferCallback:) and writes
    /// the resulting PCM buffers to a CAF file at `outputURL`.
    func synthesize(text: String, voiceID: String, outputURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID)
                ?? AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate

            let synthesizer = AVSpeechSynthesizer()
            var audioFile: AVAudioFile?
            var hasFailed = false

            synthesizer.write(utterance) { buffer in
                guard !hasFailed else { return }
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }

                if pcmBuffer.frameLength == 0 {
                    // Empty buffer signals completion.
                    continuation.resume()
                    return
                }

                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(
                            forWriting: outputURL,
                            settings: pcmBuffer.format.settings
                        )
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    hasFailed = true
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Default voice suggestions per gender

extension AVSpeechEngine {
    /// Returns the best available system voice matching the requested gender hint.
    /// Falls back to any English voice if no match exists.
    func defaultVoice(gender: String?) -> IOSVoiceInfo? {
        let voices = listVoices()
        if let g = gender {
            if let match = voices.first(where: { $0.gender == g }) { return match }
        }
        return voices.first
    }
}
#endif
