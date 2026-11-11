import Foundation

enum AppRole: String, CaseIterable {
    case normal
    case priority
    case ducked
}

struct PlaybackState {
    let role: AppRole
    let isPlaying: Bool
}

enum DuckingPolicy {
    static let defaultDuckLevel: Float = 0.3
    static let duckLevelChoices: [Float] = [0.1, 0.2, 0.3, 0.5]

    static func isDuckingActive(_ states: [PlaybackState]) -> Bool {
        states.contains { $0.role == .priority && $0.isPlaying }
    }

    static func effectiveGain(volume: Float, role: AppRole, isDuckingActive: Bool, duckLevel: Float) -> Float {
        let base = VolumeCurve.linearGain(forSliderValue: volume)
        guard role == .ducked, isDuckingActive else { return base }
        let clampedLevel = min(max(duckLevel, 0), 1)
        return base * VolumeCurve.linearGain(forSliderValue: clampedLevel)
    }

    static func shouldTap(
        isNeutral: Bool,
        isEngaged: Bool,
        role: AppRole,
        isPlaying: Bool,
        isAnyPriorityPlaying: Bool,
        isPopoverOpen: Bool,
        isCaptureVerified: Bool
    ) -> Bool {
        if !isNeutral || isEngaged {
            return true
        }
        if role == .ducked, isPlaying || isAnyPriorityPlaying {
            return true
        }
        return isPopoverOpen && isCaptureVerified && isPlaying
    }
}
