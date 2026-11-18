import Foundation
import Testing

@testable import Calando

private let speechLocale = ProcessInfo.processInfo.environment["CALANDO_SPEECH_LOCALE"]

@MainActor
private final class PacedSource {
    private let audio: CapturedAudio
    private var cursor = 0
    private let startedAt = ContinuousClock.now

    init(_ audio: CapturedAudio) {
        self.audio = audio
    }

    func next() -> CapturedAudio? {
        let elapsed = ContinuousClock.now - startedAt
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let due = min(Int(seconds * audio.sampleRate), audio.samples.count)
        guard due > cursor else {
            return CapturedAudio(samples: [Float32](repeating: 0, count: Int(audio.sampleRate / 10)), sampleRate: audio.sampleRate)
        }
        let piece = Array(audio.samples[cursor..<due])
        cursor = due
        return CapturedAudio(samples: piece, sampleRate: audio.sampleRate)
    }
}

@MainActor
@Test func synthesizedNameIsHeardByTheOneShotRecognizerWhenRequested() async throws {
    guard let speechLocale, #available(macOS 26.0, *) else { return }
    #expect(await SpeechModels.state(for: speechLocale) == .installed)
    let voice = try #require(NameSynthesizer.voices(for: speechLocale).first)
    let phrase = try #require(NameSynthesizer.phrases(for: "Rafael", localeIdentifier: speechLocale).dropFirst().first)
    let audio = try #require(await NameSynthesizer.render(phrase, voice: voice))
    #expect(audio.samples.count > Int(audio.sampleRate / 2))

    let heard = try await OneShotTranscription.transcribe(audio, localeIdentifier: speechLocale, contextualNames: ["Rafael"])
    print("said: \(phrase) | heard: \(heard)")
    let triggers = NameMatcher.triggers(names: ["Rafael"], variants: [])
    #expect(NameMatcher.firstTrigger(in: heard, triggers: triggers) == "rafael")
}

@MainActor
@Test func liveTranscriptionSpotsTheNameInAPacedStreamWhenRequested() async throws {
    guard let speechLocale, #available(macOS 26.0, *) else { return }
    let voice = try #require(NameSynthesizer.voices(for: speechLocale).first)
    let phrase = try #require(NameSynthesizer.phrases(for: "Rafael", localeIdentifier: speechLocale).last)
    let audio = try #require(await NameSynthesizer.render(phrase, voice: voice))
    let source = PacedSource(audio)
    let triggers = NameMatcher.triggers(names: ["Rafael"], variants: [])
    let started = ContinuousClock.now
    var heardAfter: Duration?
    var failure: String?

    let session = LiveTranscription()
    session.start(
        localeIdentifier: speechLocale,
        contextualNames: ["Rafael"],
        source: { source.next() },
        onText: { text in
            if heardAfter == nil, NameMatcher.firstTrigger(in: text, triggers: triggers) != nil {
                heardAfter = ContinuousClock.now - started
            }
        },
        onFailure: { failure = $0 }
    )
    let deadline = started + .seconds(20)
    while heardAfter == nil, failure == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
    }
    session.stop()
    let spoken = Double(audio.samples.count) / audio.sampleRate
    print("phrase lasts \(spoken)s | name spotted after \(String(describing: heardAfter)) | failure: \(String(describing: failure))")
    #expect(failure == nil)
    #expect(heardAfter != nil)
}
