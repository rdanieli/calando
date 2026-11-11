import Foundation

enum SettingsMigration {
    static let legacyDomain = "com.local.fader"
    static let currentPrefix = "io.github.rdanieli.calando."
    static let migratedKey = "io.github.rdanieli.calando.importedLegacySettings"
    static let settingNames = ["appVolumes", "appMutes", "appRoles", "duckLevel"]

    static func valuesToImport(legacy: [String: Any], current: [String: Any]) -> [String: Any] {
        var imported: [String: Any] = [:]
        for name in settingNames {
            let currentKey = currentPrefix + name
            guard current[currentKey] == nil, let value = legacy["\(legacyDomain).\(name)"] else { continue }
            imported[currentKey] = value
        }
        return imported
    }

    static func run(defaults: UserDefaults) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        let legacy = defaults.persistentDomain(forName: legacyDomain) ?? [:]
        let current = defaults.dictionaryRepresentation()
        for (key, value) in valuesToImport(legacy: legacy, current: current) {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: migratedKey)
    }
}
