import Foundation

enum NameAlertPolicy {
    static let quietVolume: Float = 0.5
    static let cooldown: Duration = .seconds(15)

    static func shouldListen(
        isArmed: Bool,
        role: AppRole,
        isPlaying: Bool,
        volume: Float,
        isMuted: Bool,
        isMasterMuted: Bool
    ) -> Bool {
        guard isArmed, role == .priority, isPlaying else { return false }
        return isMuted || isMasterMuted || volume < quietVolume
    }

    static func canAlert(now: ContinuousClock.Instant, lastAlert: ContinuousClock.Instant?) -> Bool {
        guard let lastAlert else { return true }
        return now - lastAlert >= cooldown
    }
}
