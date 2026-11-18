import Foundation
import Observation

struct ListeningTarget: Equatable {
    let appID: String
    let appName: String
}

@MainActor
@Observable
final class NameAlertController {
    enum Status: Equatable {
        case off
        case unsupportedSystem
        case needsNames
        case speechDenied
        case languageUnsupported
        case downloadingModel
        case modelUnavailable
        case ready
        case listening(String)
        case failed
    }

    struct ActiveAlert: Equatable {
        let appID: String
        let appName: String
        let heard: String
        let didRaiseVolume: Bool
    }

    private(set) var settings: NameAlertSettings
    private(set) var status: Status = .off
    private(set) var activeAlert: ActiveAlert?
    private(set) var isFindingVariants = false
    private(set) var variantProgress = 0.0
    private(set) var variantNote: String?
    private(set) var localeChoices: [SpeechLocaleChoice] = []
    private(set) var resolvedLocaleIdentifier = "en-US"

    @ObservationIgnored var onArmedChange: (@MainActor () -> Void)?
    @ObservationIgnored var captureSource: (@MainActor () -> CapturedAudio?)?
    @ObservationIgnored var raiseVolume: (@MainActor (String) -> Void)?
    @ObservationIgnored var undoRaise: (@MainActor () -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private let notifier = NameAlertNotifier()
    @ObservationIgnored private var target: ListeningTarget?
    @ObservationIgnored private var lastAlert: ContinuousClock.Instant?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var variantTask: Task<Void, Never>?
    @ObservationIgnored private var liveSession: AnyObject?

    static var isSystemSupported: Bool {
        if #available(macOS 26.0, *) {
            return true
        }
        return false
    }

    init(defaults: UserDefaults = .standard, isPreview: Bool = false) {
        self.defaults = defaults
        self.isPreview = isPreview
        settings = isPreview ? NameAlertSettings() : NameAlertSettings.load(from: defaults)
        notifier.onRaiseRequested = { [weak self] in
            self?.raiseNow()
        }
        if settings.isEnabled {
            prepare()
        }
    }

    var isArmed: Bool {
        switch status {
        case .ready, .listening: return true
        default: return false
        }
    }

    var namesText: String {
        settings.names.joined(separator: ", ")
    }

    func setEnabled(_ enabled: Bool) {
        guard settings.isEnabled != enabled else { return }
        settings.isEnabled = enabled
        persist()
        prepare()
    }

    func setNames(_ raw: String) {
        let names = NameMatcher.parseNames(raw)
        guard names != settings.names else { return }
        settings.names = names
        let known = Set(names.map { NameMatcher.tokens($0).joined() })
        settings.suggestions.removeAll { !known.contains($0.name) }
        let remaining = Set(settings.suggestions.map(\.word))
        settings.approvedVariants.removeAll { !remaining.contains($0) }
        persist()
        prepare()
    }

    func setLocaleIdentifier(_ identifier: String) {
        guard settings.localeIdentifier != identifier else { return }
        settings.localeIdentifier = identifier
        settings.suggestions = []
        settings.approvedVariants = []
        persist()
        prepare()
    }

    func setRaisesVolume(_ raises: Bool) {
        guard settings.raisesVolume != raises else { return }
        settings.raisesVolume = raises
        persist()
    }

    func isVariantApproved(_ word: String) -> Bool {
        settings.approvedVariants.contains(word)
    }

    func setVariant(_ word: String, approved: Bool) {
        if approved {
            guard !settings.approvedVariants.contains(word) else { return }
            settings.approvedVariants.append(word)
        } else {
            settings.approvedVariants.removeAll { $0 == word }
        }
        persist()
        restartSessionIfListening()
    }

    func setListeningTarget(_ newTarget: ListeningTarget?) {
        guard newTarget != target else { return }
        target = newTarget
        applyListeningState()
    }

    func dismissAlert() {
        activeAlert = nil
    }

    func raiseNow() {
        guard let alert = activeAlert, !alert.didRaiseVolume else { return }
        raiseVolume?(alert.appID)
        activeAlert = ActiveAlert(appID: alert.appID, appName: alert.appName, heard: alert.heard, didRaiseVolume: true)
    }

    func reportFalseAlarm() {
        guard let alert = activeAlert else { return }
        if alert.didRaiseVolume {
            undoRaise?()
        }
        if settings.approvedVariants.contains(alert.heard) {
            settings.approvedVariants.removeAll { $0 == alert.heard }
            persist()
        }
        activeAlert = nil
    }

    func loadLocaleChoices() {
        guard !isPreview, localeChoices.isEmpty else { return }
        if #available(macOS 26.0, *) {
            Task { [weak self] in
                let choices = await SpeechModels.localeChoices()
                let fallback = await SpeechModels.defaultLocaleIdentifier()
                guard let self else { return }
                self.localeChoices = choices
                if self.settings.localeIdentifier == nil {
                    self.resolvedLocaleIdentifier = fallback
                }
            }
        }
    }

    func findVariants() {
        guard !isPreview, !isFindingVariants, !settings.names.isEmpty else { return }
        guard #available(macOS 26.0, *) else { return }
        isFindingVariants = true
        variantProgress = 0
        variantNote = nil
        let names = settings.names
        variantTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.collectVariants(for: names)
            self.isFindingVariants = false
            self.variantTask = nil
            guard let outcome else { return }
            self.settings.suggestions = outcome
            let offered = Set(outcome.map(\.word))
            self.settings.approvedVariants.removeAll { !offered.contains($0) }
            self.persist()
            self.variantNote = outcome.isEmpty
                ? "The recognizer heard no consistent variation. Your names are used as typed."
                : nil
        }
    }

    func handleTranscript(_ text: String) {
        nameAlertLog.debug("Transcript update with \(NameMatcher.tokens(text).count) words")
        guard let target, let heard = NameMatcher.firstTrigger(in: text, triggers: settings.triggers) else { return }
        let now = ContinuousClock.now
        guard NameAlertPolicy.canAlert(now: now, lastAlert: lastAlert) else { return }
        lastAlert = now
        let raises = settings.raisesVolume
        activeAlert = ActiveAlert(appID: target.appID, appName: target.appName, heard: heard, didRaiseVolume: raises)
        nameAlertLog.notice("Name alert fired for \(target.appName, privacy: .public)")
        notifier.post(heard: heard, appName: target.appName, didRaiseVolume: raises)
        if raises {
            raiseVolume?(target.appID)
        }
    }

    private func persist() {
        guard !isPreview else { return }
        settings.save(to: defaults)
    }

    private func setStatus(_ newStatus: Status) {
        let wasArmed = isArmed
        status = newStatus
        nameAlertLog.notice("Name Alert status: \(String(describing: newStatus), privacy: .public)")
        if wasArmed != isArmed {
            onArmedChange?()
        }
        applyListeningState()
    }

    private func prepare() {
        preparationTask?.cancel()
        preparationTask = nil
        guard !isPreview else { return }
        guard settings.isEnabled else {
            setStatus(.off)
            return
        }
        guard Self.isSystemSupported else {
            setStatus(.unsupportedSystem)
            return
        }
        guard !settings.names.isEmpty else {
            setStatus(.needsNames)
            return
        }
        guard #available(macOS 26.0, *) else { return }
        preparationTask = Task { [weak self] in
            guard let self else { return }
            let identifier: String
            if let chosen = self.settings.localeIdentifier {
                identifier = chosen
            } else {
                identifier = await SpeechModels.defaultLocaleIdentifier()
            }
            guard !Task.isCancelled else { return }
            self.resolvedLocaleIdentifier = identifier
            guard await SpeechModels.requestSpeechAuthorization() else {
                if !Task.isCancelled { self.setStatus(.speechDenied) }
                return
            }
            await self.notifier.prepare()
            var modelState = await SpeechModels.state(for: identifier)
            guard !Task.isCancelled else { return }
            if modelState == .unsupported {
                self.setStatus(.languageUnsupported)
                return
            }
            if modelState != .installed {
                self.setStatus(.downloadingModel)
                do {
                    try await SpeechModels.install(identifier)
                } catch {
                    nameAlertLog.error("Speech model install failed: \(String(describing: error), privacy: .public)")
                }
                modelState = await SpeechModels.state(for: identifier)
                guard !Task.isCancelled else { return }
            }
            self.setStatus(modelState == .installed ? .ready : .modelUnavailable)
        }
    }

    private func applyListeningState() {
        guard #available(macOS 26.0, *) else { return }
        let session = liveSession as? LiveTranscription
        guard isArmed, let target else {
            if session?.isRunning == true {
                nameAlertLog.notice("Name Alert stopped listening")
            }
            session?.stop()
            if case .listening = status {
                status = .ready
            }
            return
        }
        if case .listening(let name) = status, name == target.appName, session?.isRunning == true {
            return
        }
        status = .listening(target.appName)
        nameAlertLog.notice("Name Alert listening to \(target.appName, privacy: .public) in \(self.resolvedLocaleIdentifier, privacy: .public)")
        startSession()
    }

    private func restartSessionIfListening() {
        guard #available(macOS 26.0, *), case .listening = status else { return }
        startSession()
    }

    @available(macOS 26.0, *)
    private func startSession() {
        let session = (liveSession as? LiveTranscription) ?? LiveTranscription()
        liveSession = session
        session.start(
            localeIdentifier: resolvedLocaleIdentifier,
            contextualNames: settings.names,
            source: { [weak self] in self?.captureSource?() },
            onText: { [weak self] text in self?.handleTranscript(text) },
            onFailure: { [weak self] _ in
                guard let self else { return }
                (self.liveSession as? LiveTranscription)?.stop()
                self.setStatus(.failed)
            }
        )
    }

    @available(macOS 26.0, *)
    private func collectVariants(for names: [String]) async -> [VariantSuggestion]? {
        let identifier = resolvedLocaleIdentifier
        guard await SpeechModels.state(for: identifier) == .installed else {
            variantNote = "The speech model for this language is not installed yet."
            return nil
        }
        let voices = NameSynthesizer.voices(for: identifier)
        guard !voices.isEmpty else {
            variantNote = "No system voice is installed for this language, so variations cannot be generated."
            return nil
        }
        let jobs = names.flatMap { name in
            voices.flatMap { voice in
                NameSynthesizer.phrases(for: name, localeIdentifier: identifier).map { (name, voice, $0) }
            }
        }
        var tallies: [String: [String: Int]] = [:]
        for (index, job) in jobs.enumerated() {
            if Task.isCancelled { return nil }
            let (name, voice, phrase) = job
            if let audio = await NameSynthesizer.render(phrase, voice: voice),
               let heard = try? await OneShotTranscription.transcribe(audio, localeIdentifier: identifier, contextualNames: names) {
                let key = NameMatcher.tokens(name).joined()
                for word in VariantFinder.candidates(heard: heard, said: phrase, name: name) {
                    tallies[key, default: [:]][word, default: 0] += 1
                }
            }
            variantProgress = Double(index + 1) / Double(jobs.count)
        }
        return VariantFinder.suggestions(from: tallies)
    }
}
