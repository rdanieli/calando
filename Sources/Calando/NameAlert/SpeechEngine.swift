import AVFoundation
import Foundation
import Speech
import os

let nameAlertLog = Logger(subsystem: "io.github.rdanieli.calando", category: "NameAlert")

enum SpeechModelState: Equatable {
    case unsupported
    case notInstalled
    case downloading
    case installed
}

struct SpeechLocaleChoice: Identifiable, Equatable {
    let id: String
    let displayName: String
}

enum SpeechEngineError: Error {
    case localeUnsupported
    case noAudioFormat
}

@available(macOS 26.0, *)
enum SpeechModels {
    static func transcriber(for identifier: String) async -> SpeechTranscriber? {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            return nil
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    static func state(for identifier: String) async -> SpeechModelState {
        guard let transcriber = await transcriber(for: identifier) else { return .unsupported }
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .unsupported: return .unsupported
        case .supported:
            let pendingInstall = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])
            return pendingInstall == nil ? .installed : .notInstalled
        @unknown default: return .unsupported
        }
    }

    static func install(_ identifier: String) async throws {
        guard let transcriber = await transcriber(for: identifier) else { throw SpeechEngineError.localeUnsupported }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    static func localeChoices() async -> [SpeechLocaleChoice] {
        let display = Locale.current
        return await SpeechTranscriber.supportedLocales
            .map { locale in
                let identifier = locale.identifier(.bcp47)
                return SpeechLocaleChoice(id: identifier, displayName: display.localizedString(forIdentifier: identifier) ?? identifier)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func defaultLocaleIdentifier() async -> String {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return match.identifier(.bcp47)
        }
        return "en-US"
    }

    static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

@available(macOS 26.0, *)
final class AnalyzerFeed {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func input(from audio: CapturedAudio) -> AnalyzerInput? {
        guard !audio.samples.isEmpty, audio.sampleRate > 0 else { return nil }
        if source?.sampleRate != audio.sampleRate {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1) else { return nil }
            source = format
            converter = AVAudioConverter(from: format, to: target)
        }
        guard
            let source,
            let converter,
            let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(audio.samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        audio.samples.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var delivered = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, output.frameLength > 0 else { return nil }
        return AnalyzerInput(buffer: output)
    }
}

@available(macOS 26.0, *)
@MainActor
final class LiveTranscription {
    private var task: Task<Void, Never>?

    private static let pollInterval: Duration = .milliseconds(100)

    var isRunning: Bool { task != nil }

    func start(
        localeIdentifier: String,
        contextualNames: [String],
        source: @escaping @MainActor () -> CapturedAudio?,
        onText: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        stop()
        task = Task.detached(priority: .utility) {
            do {
                try await Self.run(
                    localeIdentifier: localeIdentifier,
                    contextualNames: contextualNames,
                    source: source,
                    onText: onText
                )
            } catch is CancellationError {
                return
            } catch {
                let description = String(describing: error)
                nameAlertLog.error("Live transcription stopped: \(description, privacy: .public)")
                await onFailure(description)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private nonisolated static func run(
        localeIdentifier: String,
        contextualNames: [String],
        source: @escaping @MainActor () -> CapturedAudio?,
        onText: @escaping @MainActor (String) -> Void
    ) async throws {
        guard let transcriber = await SpeechModels.transcriber(for: localeIdentifier) else {
            throw SpeechEngineError.localeUnsupported
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualNames.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualNames
            try await analyzer.setContext(context)
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noAudioFormat
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let reader = Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                await onText(text)
            }
        }
        defer {
            input.finish()
            reader.cancel()
        }
        try await analyzer.start(inputSequence: stream)
        let feed = AnalyzerFeed(target: target)
        while !Task.isCancelled {
            if let audio = await source(), let chunk = feed.input(from: audio) {
                input.yield(chunk)
            }
            try await Task.sleep(for: pollInterval)
        }
        await analyzer.cancelAndFinishNow()
    }
}

@available(macOS 26.0, *)
enum OneShotTranscription {
    private static let chunkSeconds = 0.1
    private static let tailSeconds = 1.5

    static func transcribe(_ audio: CapturedAudio, localeIdentifier: String, contextualNames: [String]) async throws -> String {
        guard let transcriber = await SpeechModels.transcriber(for: localeIdentifier) else {
            throw SpeechEngineError.localeUnsupported
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualNames.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualNames
            try await analyzer.setContext(context)
        }
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.noAudioFormat
        }
        let (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let reader = Task {
            var finals: [String] = []
            var volatile = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isFinal {
                    if !text.isEmpty { finals.append(text) }
                    volatile = ""
                } else {
                    volatile = text
                }
            }
            return finals.isEmpty ? volatile : finals.joined(separator: " ")
        }
        try await analyzer.start(inputSequence: stream)

        let feed = AnalyzerFeed(target: target)
        let chunkSize = max(Int(audio.sampleRate * chunkSeconds), 1)
        let padded = audio.samples + [Float32](repeating: 0, count: Int(audio.sampleRate * tailSeconds))
        var offset = 0
        while offset < padded.count {
            let end = min(offset + chunkSize, padded.count)
            let piece = CapturedAudio(samples: Array(padded[offset..<end]), sampleRate: audio.sampleRate)
            if let chunk = feed.input(from: piece) {
                input.yield(chunk)
            }
            offset = end
        }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await reader.value
    }
}
