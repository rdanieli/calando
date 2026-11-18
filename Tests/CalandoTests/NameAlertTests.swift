import Foundation
import Testing

@testable import Calando

@Test func namesAreParsedTrimmedAndDeduplicated() {
    #expect(NameMatcher.parseNames(" Rafael, rafa ;RAFAEL\nDanieli,, ") == ["Rafael", "rafa", "Danieli"])
    #expect(NameMatcher.parseNames("  ,; ").isEmpty)
}

@Test func triggerMatchingIgnoresCaseAccentsAndPunctuation() {
    let triggers = NameMatcher.triggers(names: ["Rafael", "João Pedro"], variants: ["daniel"])
    #expect(NameMatcher.firstTrigger(in: "Então, RAFAEL, deu certo?", triggers: triggers) == "rafael")
    #expect(NameMatcher.firstTrigger(in: "o joao pedro chegou", triggers: triggers) == "joao pedro")
    #expect(NameMatcher.firstTrigger(in: "O Daniel ficou de revisar", triggers: triggers) == "daniel")
}

@Test func triggerMatchingNeedsWholeWordsInOrder() {
    let triggers = NameMatcher.triggers(names: ["Rafael", "João Pedro"], variants: [])
    #expect(NameMatcher.firstTrigger(in: "A Rafaela vai apresentar", triggers: triggers) == nil)
    #expect(NameMatcher.firstTrigger(in: "o Pedro e o João saíram", triggers: triggers) == nil)
    #expect(NameMatcher.firstTrigger(in: "", triggers: triggers) == nil)
    #expect(NameMatcher.firstTrigger(in: "Rafael", triggers: []) == nil)
}

@Test func earliestTriggerInTheSentenceWins() {
    let triggers = NameMatcher.triggers(names: ["Danieli", "Rafa"], variants: [])
    #expect(NameMatcher.firstTrigger(in: "o Rafa e o Danieli", triggers: triggers) == "rafa")
}

@Test func editDistanceCountsSingleCharacterEdits() {
    #expect(VariantFinder.editDistance("rafa", "rafa") == 0)
    #expect(VariantFinder.editDistance("danieli", "daniel") == 1)
    #expect(VariantFinder.editDistance("rafa", "rabo") == 2)
    #expect(VariantFinder.editDistance("", "abc") == 3)
}

@Test func variantCandidatesKeepOnlyWordsCloseToTheName() {
    let heard = "Faço a palavra para o Daniel agora"
    let said = "Passo a palavra para o Danieli agora."
    #expect(VariantFinder.candidates(heard: heard, said: said, name: "Danieli") == ["daniel"])
    #expect(VariantFinder.candidates(heard: "Danieli, pode falar?", said: "Danieli, pode falar?", name: "Danieli").isEmpty)
    #expect(VariantFinder.candidates(heard: "o rabo já gerou", said: "o Rafa já chegou", name: "Rafa") == ["rabo"])
}

@Test func suggestionsNeedRepeatedOccurrencesAndSortByFrequency() {
    let suggestions = VariantFinder.suggestions(from: [
        "danieli": ["daniel": 4, "daniele": 3, "dani": 1],
        "rafa": ["rava": 2],
    ])
    #expect(suggestions.map(\.word) == ["daniel", "daniele", "rava"])
    #expect(suggestions.first?.name == "danieli")
}

@Test func listeningNeedsAnArmedQuietPlayingPriorityApp() {
    func listens(
        isArmed: Bool = true,
        role: AppRole = .priority,
        isPlaying: Bool = true,
        volume: Float = 1,
        isMuted: Bool = false,
        isMasterMuted: Bool = false
    ) -> Bool {
        NameAlertPolicy.shouldListen(
            isArmed: isArmed,
            role: role,
            isPlaying: isPlaying,
            volume: volume,
            isMuted: isMuted,
            isMasterMuted: isMasterMuted
        )
    }
    #expect(listens() == false)
    #expect(listens(isMuted: true))
    #expect(listens(volume: 0.3))
    #expect(listens(isMasterMuted: true))
    #expect(listens(volume: 0.5) == false)
    #expect(listens(isArmed: false, isMuted: true) == false)
    #expect(listens(role: .normal, isMuted: true) == false)
    #expect(listens(role: .ducked, isMuted: true) == false)
    #expect(listens(isPlaying: false, isMuted: true) == false)
}

@Test func alertsRespectTheCooldown() {
    let now = ContinuousClock.now
    #expect(NameAlertPolicy.canAlert(now: now, lastAlert: nil))
    #expect(NameAlertPolicy.canAlert(now: now, lastAlert: now - .seconds(5)) == false)
    #expect(NameAlertPolicy.canAlert(now: now, lastAlert: now - .seconds(15)))
}

@Test func settingsSurviveASaveAndLoadRoundTrip() throws {
    let suiteName = "calando.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(NameAlertSettings.load(from: defaults) == NameAlertSettings())

    var settings = NameAlertSettings()
    settings.isEnabled = true
    settings.names = ["Rafael", "Rafa"]
    settings.approvedVariants = ["daniel"]
    settings.suggestions = [VariantSuggestion(word: "daniel", name: "danieli", occurrences: 4)]
    settings.localeIdentifier = "pt-BR"
    settings.raisesVolume = false
    settings.save(to: defaults)

    let loaded = NameAlertSettings.load(from: defaults)
    #expect(loaded == settings)
    #expect(loaded.triggers == [["rafael"], ["rafa"], ["daniel"]])
}

@MainActor
@Test func aHeardNameRaisesTheVolumeOnceAndNotMeUndoesIt() throws {
    let suiteName = "calando.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var settings = NameAlertSettings()
    settings.names = ["Rafael"]
    settings.approvedVariants = ["daniel"]
    settings.suggestions = [VariantSuggestion(word: "daniel", name: "rafael", occurrences: 2)]
    settings.save(to: defaults)

    let controller = NameAlertController(defaults: defaults)
    var raised: [String] = []
    var undone = 0
    controller.raiseVolume = { raised.append($0) }
    controller.undoRaise = { undone += 1 }

    controller.handleTranscript("o daniel pode falar")
    #expect(controller.activeAlert == nil)

    controller.setListeningTarget(ListeningTarget(appID: "com.example.calls", appName: "Calls"))
    controller.handleTranscript("vamos começar a reunião")
    #expect(controller.activeAlert == nil)

    controller.handleTranscript("o daniel pode falar")
    #expect(raised == ["com.example.calls"])
    #expect(controller.activeAlert?.heard == "daniel")
    #expect(controller.activeAlert?.didRaiseVolume == true)

    controller.handleTranscript("Rafael, você está aí?")
    #expect(raised.count == 1)

    controller.reportFalseAlarm()
    #expect(undone == 1)
    #expect(controller.activeAlert == nil)
    #expect(controller.settings.approvedVariants.isEmpty)
    #expect(NameAlertSettings.load(from: defaults).approvedVariants.isEmpty)
}

@MainActor
@Test func withoutAutomaticRaiseTheAlertWaitsForTheUser() throws {
    let suiteName = "calando.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var settings = NameAlertSettings()
    settings.names = ["Rafael"]
    settings.raisesVolume = false
    settings.save(to: defaults)

    let controller = NameAlertController(defaults: defaults)
    var raised: [String] = []
    controller.raiseVolume = { raised.append($0) }
    controller.setListeningTarget(ListeningTarget(appID: "com.example.calls", appName: "Calls"))

    controller.handleTranscript("Rafael?")
    #expect(raised.isEmpty)
    #expect(controller.activeAlert?.didRaiseVolume == false)

    controller.raiseNow()
    #expect(raised == ["com.example.calls"])
    #expect(controller.activeAlert?.didRaiseVolume == true)

    controller.raiseNow()
    #expect(raised.count == 1)
}
