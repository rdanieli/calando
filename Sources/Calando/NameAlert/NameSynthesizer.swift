import AVFoundation
import Foundation

private final class SynthesisCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float32] = []
    private var sampleRate: Double = 0
    private var continuation: CheckedContinuation<CapturedAudio?, Never>?
    private var isFinished = false

    func attach(_ continuation: CheckedContinuation<CapturedAudio?, Never>) {
        lock.lock()
        if isFinished {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var chunk = [Float32](repeating: 0, count: frames)
        if let floats = buffer.floatChannelData?[0] {
            for index in 0..<frames { chunk[index] = floats[index] }
        } else if let shorts = buffer.int16ChannelData?[0] {
            for index in 0..<frames { chunk[index] = Float32(shorts[index]) / 32_768 }
        } else if let longs = buffer.int32ChannelData?[0] {
            for index in 0..<frames { chunk[index] = Float32(longs[index]) / 2_147_483_648 }
        } else {
            return
        }
        lock.lock()
        sampleRate = buffer.format.sampleRate
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let pending = continuation
        continuation = nil
        let audio = samples.isEmpty || sampleRate <= 0 ? nil : CapturedAudio(samples: samples, sampleRate: sampleRate)
        lock.unlock()
        pending?.resume(returning: audio)
    }
}

@MainActor
enum NameSynthesizer {
    static let voiceLimit = 4
    private static let timeout: Duration = .seconds(12)

    private static let carriersByLanguage: [String: [String]] = [
        "pt": ["%@", "%@, pode falar?", "O que o %@ acha disso?", "Vou perguntar para o %@."],
        "en": ["%@", "%@, can you hear me?", "What does %@ think about this?", "Let me ask %@."],
        "es": ["%@", "%@, ¿puedes hablar?", "¿Qué opina %@ de esto?", "Voy a preguntarle a %@."],
    ]
    private static let fallbackCarriers = ["%@", "%@, %@."]

    static func phrases(for name: String, localeIdentifier: String) -> [String] {
        let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? ""
        let carriers = carriersByLanguage[language] ?? fallbackCarriers
        return carriers.map { $0.replacingOccurrences(of: "%@", with: name) }
    }

    static func voices(for localeIdentifier: String) -> [AVSpeechSynthesisVoice] {
        let wanted = Locale(identifier: localeIdentifier).identifier(.bcp47)
        let matching = AVSpeechSynthesisVoice.speechVoices().filter {
            Locale(identifier: $0.language).identifier(.bcp47) == wanted
        }
        return Array(matching.prefix(voiceLimit))
    }

    static func render(_ text: String, voice: AVSpeechSynthesisVoice) async -> CapturedAudio? {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let collector = SynthesisCollector()
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            collector.finish()
        }
        let audio = await withCheckedContinuation { (continuation: CheckedContinuation<CapturedAudio?, Never>) in
            collector.attach(continuation)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    collector.finish()
                    return
                }
                collector.append(pcm)
            }
        }
        watchdog.cancel()
        return withExtendedLifetime(synthesizer) { audio }
    }
}
