import Testing

@testable import Fader

@Test func duckingIsActiveOnlyWhileAPriorityAppPlays() {
    #expect(DuckingPolicy.isDuckingActive([]) == false)
    #expect(DuckingPolicy.isDuckingActive([PlaybackState(role: .priority, isPlaying: false)]) == false)
    #expect(DuckingPolicy.isDuckingActive([PlaybackState(role: .normal, isPlaying: true)]) == false)
    #expect(DuckingPolicy.isDuckingActive([PlaybackState(role: .ducked, isPlaying: true)]) == false)
    #expect(
        DuckingPolicy.isDuckingActive([
            PlaybackState(role: .ducked, isPlaying: true),
            PlaybackState(role: .priority, isPlaying: true),
        ]) == true
    )
}

@Test func onlyDuckedAppsAreLoweredAndOnlyWhileDuckingIsActive() {
    let level: Float = 0.5
    #expect(DuckingPolicy.effectiveGain(volume: 1, role: .ducked, isDuckingActive: true, duckLevel: level) == 0.25)
    #expect(DuckingPolicy.effectiveGain(volume: 1, role: .ducked, isDuckingActive: false, duckLevel: level) == 1)
    #expect(DuckingPolicy.effectiveGain(volume: 1, role: .normal, isDuckingActive: true, duckLevel: level) == 1)
    #expect(DuckingPolicy.effectiveGain(volume: 1, role: .priority, isDuckingActive: true, duckLevel: level) == 1)
}

@Test func duckingScalesTheVolumeTheUserAlreadyChose() {
    let gain = DuckingPolicy.effectiveGain(volume: 0.5, role: .ducked, isDuckingActive: true, duckLevel: 0.5)
    #expect(gain == 0.0625)
    let amplified = DuckingPolicy.effectiveGain(volume: 1.5, role: .ducked, isDuckingActive: true, duckLevel: 1)
    #expect(amplified == 1.5)
    let outOfRange = DuckingPolicy.effectiveGain(volume: 1, role: .ducked, isDuckingActive: true, duckLevel: 7)
    #expect(outOfRange == 1)
}

@Test func neutralIdleAppsAreLeftUntapped() {
    let tapped = DuckingPolicy.shouldTap(
        isNeutral: true,
        isEngaged: false,
        role: .normal,
        isPlaying: true,
        isAnyPriorityPlaying: true,
        isPopoverOpen: false,
        isCaptureVerified: true
    )
    #expect(tapped == false)
}

@Test func adjustedOrEngagedAppsAreAlwaysTapped() {
    let adjusted = DuckingPolicy.shouldTap(
        isNeutral: false,
        isEngaged: false,
        role: .normal,
        isPlaying: false,
        isAnyPriorityPlaying: false,
        isPopoverOpen: false,
        isCaptureVerified: false
    )
    let engaged = DuckingPolicy.shouldTap(
        isNeutral: true,
        isEngaged: true,
        role: .normal,
        isPlaying: false,
        isAnyPriorityPlaying: false,
        isPopoverOpen: false,
        isCaptureVerified: false
    )
    #expect(adjusted == true)
    #expect(engaged == true)
}

@Test func duckedAppsAreTappedAheadOfTimeSoDuckingIsInstant() {
    func tapped(isPlaying: Bool, priorityPlaying: Bool) -> Bool {
        DuckingPolicy.shouldTap(
            isNeutral: true,
            isEngaged: false,
            role: .ducked,
            isPlaying: isPlaying,
            isAnyPriorityPlaying: priorityPlaying,
            isPopoverOpen: false,
            isCaptureVerified: false
        )
    }
    #expect(tapped(isPlaying: true, priorityPlaying: false) == true)
    #expect(tapped(isPlaying: false, priorityPlaying: true) == true)
    #expect(tapped(isPlaying: false, priorityPlaying: false) == false)
}

@Test func openingThePopoverPrewarmsPlayingAppsOnlyAfterCaptureIsVerified() {
    func tapped(isPlaying: Bool, popoverOpen: Bool, verified: Bool) -> Bool {
        DuckingPolicy.shouldTap(
            isNeutral: true,
            isEngaged: false,
            role: .normal,
            isPlaying: isPlaying,
            isAnyPriorityPlaying: false,
            isPopoverOpen: popoverOpen,
            isCaptureVerified: verified
        )
    }
    #expect(tapped(isPlaying: true, popoverOpen: true, verified: true) == true)
    #expect(tapped(isPlaying: true, popoverOpen: true, verified: false) == false)
    #expect(tapped(isPlaying: false, popoverOpen: true, verified: true) == false)
    #expect(tapped(isPlaying: true, popoverOpen: false, verified: true) == false)
}
