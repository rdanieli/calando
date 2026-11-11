import Testing

@testable import Calando

@Test func legacySettingsAreCarriedOverUnderTheNewKeys() {
    let legacy: [String: Any] = [
        "com.local.fader.appVolumes": ["com.spotify.client": 0.4],
        "com.local.fader.appRoles": ["com.spotify.client": "ducked"],
        "com.local.fader.duckLevel": 0.2,
        "com.local.fader.captureVerified": true,
    ]
    let imported = SettingsMigration.valuesToImport(legacy: legacy, current: [:])
    #expect(imported.count == 3)
    #expect((imported["io.github.rdanieli.calando.appVolumes"] as? [String: Double]) == ["com.spotify.client": 0.4])
    #expect((imported["io.github.rdanieli.calando.appRoles"] as? [String: String]) == ["com.spotify.client": "ducked"])
    #expect((imported["io.github.rdanieli.calando.duckLevel"] as? Double) == 0.2)
    #expect(imported["io.github.rdanieli.calando.captureVerified"] == nil)
}

@Test func settingsAlreadyChosenInTheNewAppAreNeverOverwritten() {
    let legacy: [String: Any] = ["com.local.fader.duckLevel": 0.2, "com.local.fader.appMutes": ["a": true]]
    let current: [String: Any] = ["io.github.rdanieli.calando.duckLevel": 0.5]
    let imported = SettingsMigration.valuesToImport(legacy: legacy, current: current)
    #expect(imported["io.github.rdanieli.calando.duckLevel"] == nil)
    #expect((imported["io.github.rdanieli.calando.appMutes"] as? [String: Bool]) == ["a": true])
}

@Test func nothingIsImportedWhenThereAreNoLegacySettings() {
    #expect(SettingsMigration.valuesToImport(legacy: [:], current: [:]).isEmpty)
}
