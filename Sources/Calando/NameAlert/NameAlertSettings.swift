import Foundation

struct NameAlertSettings: Codable, Equatable {
    var isEnabled = false
    var names: [String] = []
    var approvedVariants: [String] = []
    var suggestions: [VariantSuggestion] = []
    var localeIdentifier: String?
    var raisesVolume = true

    static let storageKey = "io.github.rdanieli.calando.nameAlert"

    var triggers: [[String]] {
        NameMatcher.triggers(names: names, variants: approvedVariants)
    }

    static func load(from defaults: UserDefaults) -> NameAlertSettings {
        guard
            let data = defaults.data(forKey: storageKey),
            let settings = try? JSONDecoder().decode(NameAlertSettings.self, from: data)
        else { return NameAlertSettings() }
        return settings
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
