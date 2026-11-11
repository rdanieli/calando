import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import Observation
import os

struct AudioApp: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let ownerPID: pid_t
    var processObjectIDs: [AudioObjectID]
    var isPlaying: Bool
    var volume: Float
    var isMuted: Bool
    var role: AppRole

    var isNeutral: Bool {
        volume == VolumeCurve.unity && !isMuted
    }
}

@MainActor
@Observable
final class AudioEngineManager {
    private(set) var apps: [AudioApp] = []
    private(set) var outputDeviceName = "No output device"
    private(set) var outputDeviceSymbol = "speaker.slash"
    private(set) var masterVolume: Float = 0
    private(set) var isMasterMuted = false
    private(set) var isMasterVolumeAvailable = false
    private(set) var isMasterMuteAvailable = false
    private(set) var isDucking = false
    private(set) var duckLevel: Float = DuckingPolicy.defaultDuckLevel
    private(set) var showsCaptureWarning = false

    @ObservationIgnored private var taps: [pid_t: ProcessAudioTap] = [:]
    @ObservationIgnored private var outputDeviceID = AudioObjectID.unknown
    @ObservationIgnored private var observedProcessObjects: Set<AudioObjectID> = []
    @ObservationIgnored private var observedOutputDevices: Set<AudioObjectID> = []
    @ObservationIgnored private var engagedAppIDs: Set<String> = []
    @ObservationIgnored private var seenPlayingAppIDs: Set<String> = []
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var isPrewarmActive = false
    @ObservationIgnored private var isCaptureVerified = false
    @ObservationIgnored private var duckReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var prewarmReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var captureMonitorTask: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let isPreview: Bool

    private static let volumesKey = "com.local.fader.appVolumes"
    private static let mutesKey = "com.local.fader.appMutes"
    private static let rolesKey = "com.local.fader.appRoles"
    private static let duckLevelKey = "com.local.fader.duckLevel"
    private static let captureVerifiedKey = "com.local.fader.captureVerified"

    private static let duckAttackSeconds = 0.25
    private static let duckReleaseSeconds = 0.6
    private static let duckHold: Duration = .milliseconds(1500)
    private static let prewarmGrace: Duration = .seconds(15)
    private static let captureWarningDelay: Duration = .seconds(4)

    init() {
        isPreview = false
        if let storedLevel = defaults.object(forKey: Self.duckLevelKey) as? Double {
            duckLevel = min(max(Float(storedLevel), 0), 1)
        }
        isCaptureVerified = defaults.bool(forKey: Self.captureVerifiedKey)

        refreshOutputDevice()
        addListener(
            to: .system,
            selector: kAudioHardwarePropertyProcessObjectList
        ) { manager in
            manager.refreshProcesses()
        }
        addListener(
            to: .system,
            selector: kAudioHardwarePropertyDefaultOutputDevice
        ) { manager in
            manager.handleDefaultOutputDeviceChange()
        }
        observeApplicationLifecycle()
        refreshProcesses()
    }

    init(
        previewApps: [AudioApp],
        outputDeviceName: String,
        outputDeviceSymbol: String,
        masterVolume: Float,
        isDucking: Bool
    ) {
        isPreview = true
        apps = previewApps
        self.outputDeviceName = outputDeviceName
        self.outputDeviceSymbol = outputDeviceSymbol
        self.masterVolume = masterVolume
        self.isDucking = isDucking
        isMasterVolumeAvailable = true
        isMasterMuteAvailable = true
    }

    func setVolume(_ value: Float, forAppID id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(value, VolumeCurve.minimum), VolumeCurve.maximum)
        guard apps[index].volume != clamped else { return }
        apps[index].volume = clamped
        persistVolume(clamped, forAppID: id)
        applySettings(of: apps[index])
    }

    func setMuted(_ muted: Bool, forAppID id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        guard apps[index].isMuted != muted else { return }
        apps[index].isMuted = muted
        persistMute(muted, forAppID: id)
        applySettings(of: apps[index])
    }

    func setRole(_ role: AppRole, forAppID id: String) {
        guard let index = apps.firstIndex(where: { $0.id == id }) else { return }
        guard apps[index].role != role else { return }
        apps[index].role = role
        persistRole(role, forAppID: id)
        guard !isPreview else { return }
        updateDucking()
        applyAllGains(slewSeconds: Self.duckAttackSeconds)
        syncTaps()
    }

    func setDuckLevel(_ level: Float) {
        let clamped = min(max(level, 0), 1)
        guard duckLevel != clamped else { return }
        duckLevel = clamped
        guard !isPreview else { return }
        defaults.set(Double(clamped), forKey: Self.duckLevelKey)
        applyAllGains(slewSeconds: Self.duckAttackSeconds)
    }

    func resetAll() {
        for index in apps.indices {
            apps[index].volume = VolumeCurve.unity
            apps[index].isMuted = false
        }
        guard !isPreview else { return }
        defaults.removeObject(forKey: Self.volumesKey)
        defaults.removeObject(forKey: Self.mutesKey)
        engagedAppIDs.removeAll()
        for app in apps {
            taps[app.ownerPID]?.setMuted(false)
        }
        applyAllGains(slewSeconds: ProcessAudioTap.quickSlewSeconds)
        syncTaps()
    }

    func setMasterVolume(_ value: Float) {
        guard isMasterVolumeAvailable, outputDeviceID != .unknown else { return }
        let clamped = Float32(min(max(value, 0), 1))
        let succeeded = outputDeviceID.setPropertyData(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput,
            value: clamped
        )
        if succeeded {
            masterVolume = clamped
        }
    }

    func setMasterMuted(_ muted: Bool) {
        guard isMasterMuteAvailable, outputDeviceID != .unknown else { return }
        let succeeded = outputDeviceID.setPropertyData(
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput,
            value: UInt32(muted ? 1 : 0)
        )
        if succeeded {
            isMasterMuted = muted
        }
    }

    func openCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.teardownAllTaps(waitUntilDone: true)
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.beginPrewarm()
                }
            }
        )
        notificationObservers.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.schedulePrewarmEnd()
                }
            }
        )
    }

    private func beginPrewarm() {
        prewarmReleaseTask?.cancel()
        prewarmReleaseTask = nil
        guard !isPrewarmActive else { return }
        isPrewarmActive = true
        syncTaps()
    }

    private func schedulePrewarmEnd() {
        prewarmReleaseTask?.cancel()
        prewarmReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.prewarmGrace)
            guard !Task.isCancelled, let self else { return }
            self.prewarmReleaseTask = nil
            self.isPrewarmActive = false
            self.engagedAppIDs = Set(self.apps.filter { !$0.isNeutral }.map(\.id))
            self.syncTaps()
        }
    }

    private func addListener(
        to objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        handler: @escaping @MainActor (AudioEngineManager) -> Void
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
        if status != noErr {
            coreAudioLog.error(
                "AddPropertyListenerBlock \(fourCharacterCode(selector), privacy: .public) failed on object \(objectID): \(describeStatus(status), privacy: .public)"
            )
        }
    }

    private func refreshProcesses() {
        let objectIDs: [AudioObjectID] = AudioObjectID.system.getPropertyArray(
            selector: kAudioHardwarePropertyProcessObjectList
        ) ?? []
        observeProcessObjects(objectIDs)

        struct ProcessGroup {
            let application: NSRunningApplication
            var objectIDs: [AudioObjectID]
            var isRunningOutput: Bool
            var hasDirectProcess: Bool
        }

        var groups: [String: ProcessGroup] = [:]
        for objectID in objectIDs {
            let resolvedPID: pid_t? = objectID.getPropertyData(selector: kAudioProcessPropertyPID)
            guard let pid = resolvedPID, pid != ownPID else { continue }
            let runningFlag: UInt32 = objectID.getPropertyData(selector: kAudioProcessPropertyIsRunningOutput) ?? 0
            let bundleID = objectID.getStringProperty(selector: kAudioProcessPropertyBundleID)
            guard
                let owner = ownerApplication(forPID: pid, bundleID: bundleID),
                owner.application.processIdentifier != ownPID
            else { continue }

            let application = owner.application
            let key = application.bundleIdentifier ?? application.localizedName ?? "pid-\(application.processIdentifier)"
            if var group = groups[key] {
                group.objectIDs.append(objectID)
                group.isRunningOutput = group.isRunningOutput || runningFlag != 0
                group.hasDirectProcess = group.hasDirectProcess || owner.isDirect
                groups[key] = group
            } else {
                groups[key] = ProcessGroup(
                    application: application,
                    objectIDs: [objectID],
                    isRunningOutput: runningFlag != 0,
                    hasDirectProcess: owner.isDirect
                )
            }
        }

        seenPlayingAppIDs.formIntersection(groups.keys)
        for (key, group) in groups where group.isRunningOutput {
            seenPlayingAppIDs.insert(key)
        }
        let visibleGroups = groups.filter { key, group in
            group.hasDirectProcess || seenPlayingAppIDs.contains(key)
        }
        engagedAppIDs.formIntersection(visibleGroups.keys)

        let previous = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let storedVolumes = defaults.dictionary(forKey: Self.volumesKey) as? [String: Double] ?? [:]
        let storedMutes = defaults.dictionary(forKey: Self.mutesKey) as? [String: Bool] ?? [:]
        let storedRoles = defaults.dictionary(forKey: Self.rolesKey) as? [String: String] ?? [:]

        var refreshed: [AudioApp] = []
        for (key, group) in visibleGroups {
            let existing = previous[key]
            let volume = existing?.volume ?? storedVolumes[key].map { Float($0) } ?? VolumeCurve.unity
            let isMuted = existing?.isMuted ?? storedMutes[key] ?? false
            let role = existing?.role ?? storedRoles[key].flatMap(AppRole.init(rawValue:)) ?? .normal
            let app = AudioApp(
                id: key,
                name: existing?.name ?? displayName(of: group.application, fallback: key),
                icon: existing?.icon ?? group.application.icon ?? NSWorkspace.shared.icon(for: .application),
                ownerPID: group.application.processIdentifier,
                processObjectIDs: group.objectIDs.sorted(),
                isPlaying: group.isRunningOutput,
                volume: min(max(volume, VolumeCurve.minimum), VolumeCurve.maximum),
                isMuted: isMuted,
                role: role
            )
            if !app.isNeutral {
                engagedAppIDs.insert(key)
            }
            refreshed.append(app)
        }
        refreshed.sort { first, second in
            if first.isPlaying != second.isPlaying {
                return first.isPlaying
            }
            return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }
        if Set(refreshed.map(\.id)) != Set(apps.map(\.id)) {
            let names = refreshed.map { $0.isPlaying ? "\($0.name) (playing)" : $0.name }.joined(separator: ", ")
            coreAudioLog.notice(
                "Apps with an audio session: [\(names, privacy: .public)] out of \(objectIDs.count) audio processes"
            )
        }
        apps = refreshed

        updateDucking()
        syncTaps()
    }

    private func displayName(of application: NSRunningApplication, fallback: String) -> String {
        let raw = application.localizedName ?? fallback
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter { $0.properties.generalCategory != .format }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func observeProcessObjects(_ objectIDs: [AudioObjectID]) {
        let current = Set(objectIDs)
        observedProcessObjects.formIntersection(current)
        for objectID in current where !observedProcessObjects.contains(objectID) {
            observedProcessObjects.insert(objectID)
            addListener(to: objectID, selector: kAudioProcessPropertyIsRunning) { manager in
                manager.refreshProcesses()
            }
            addListener(
                to: objectID,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput
            ) { manager in
                manager.refreshProcesses()
            }
        }
    }

    private func ownerApplication(
        forPID pid: pid_t,
        bundleID: String?
    ) -> (application: NSRunningApplication, isDirect: Bool)? {
        var candidate = pid
        var depth = 0
        while candidate > 1, depth < 16 {
            if let application = regularApplication(forPID: candidate) {
                return (application, true)
            }
            guard let parent = ProcessTree.parentPID(of: candidate), parent != candidate else { break }
            candidate = parent
            depth += 1
        }

        if let bundleID, !bundleID.isEmpty {
            let match = NSWorkspace.shared.runningApplications
                .filter { application in
                    guard application.activationPolicy == .regular, let identifier = application.bundleIdentifier else {
                        return false
                    }
                    return bundleID == identifier || bundleID.hasPrefix(identifier + ".")
                }
                .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
            if let match {
                return (match, true)
            }
        }

        if
            let responsible = ProcessTree.responsiblePID(of: pid),
            responsible != pid,
            let application = regularApplication(forPID: responsible)
        {
            return (application, false)
        }
        return nil
    }

    private func regularApplication(forPID pid: pid_t) -> NSRunningApplication? {
        guard
            let application = NSRunningApplication(processIdentifier: pid),
            application.activationPolicy == .regular
        else { return nil }
        return application
    }

    private func updateDucking() {
        let states = apps.map { PlaybackState(role: $0.role, isPlaying: $0.isPlaying) }
        if DuckingPolicy.isDuckingActive(states) {
            duckReleaseTask?.cancel()
            duckReleaseTask = nil
            guard !isDucking else { return }
            isDucking = true
            applyAllGains(slewSeconds: Self.duckAttackSeconds)
            coreAudioLog.notice("Ducking engaged at \(Int((self.duckLevel * 100).rounded()))%")
        } else if isDucking, duckReleaseTask == nil {
            duckReleaseTask = Task { [weak self] in
                try? await Task.sleep(for: Self.duckHold)
                guard !Task.isCancelled, let self else { return }
                self.duckReleaseTask = nil
                self.isDucking = false
                self.applyAllGains(slewSeconds: Self.duckReleaseSeconds)
                self.syncTaps()
                coreAudioLog.notice("Ducking released")
            }
        }
    }

    private func effectiveGain(of app: AudioApp) -> Float {
        DuckingPolicy.effectiveGain(
            volume: app.volume,
            role: app.role,
            isDuckingActive: isDucking,
            duckLevel: duckLevel
        )
    }

    private func shouldTap(_ app: AudioApp) -> Bool {
        DuckingPolicy.shouldTap(
            isNeutral: app.isNeutral,
            isEngaged: engagedAppIDs.contains(app.id),
            role: app.role,
            isPlaying: app.isPlaying,
            isAnyPriorityPlaying: isDucking,
            isPopoverOpen: isPrewarmActive,
            isCaptureVerified: isCaptureVerified
        )
    }

    private func applyAllGains(slewSeconds: Double) {
        for app in apps {
            taps[app.ownerPID]?.setGain(effectiveGain(of: app), slewSeconds: slewSeconds)
        }
    }

    private func applySettings(of app: AudioApp) {
        guard !isPreview else { return }
        if !app.isNeutral {
            engagedAppIDs.insert(app.id)
        }
        if let tap = taps[app.ownerPID] {
            tap.setGain(effectiveGain(of: app), slewSeconds: ProcessAudioTap.quickSlewSeconds)
            tap.setMuted(app.isMuted)
        } else if shouldTap(app) {
            syncTaps()
        }
    }

    private func syncTaps() {
        guard !isPreview else { return }
        let wanted = apps.filter(shouldTap)
        let wantedPIDs = Set(wanted.map(\.ownerPID))

        for (pid, tap) in taps where !wantedPIDs.contains(pid) {
            tap.teardown()
            taps[pid] = nil
        }

        guard outputDeviceID != .unknown else {
            teardownAllTaps()
            updateCaptureMonitor()
            return
        }

        for app in wanted {
            if
                let existing = taps[app.ownerPID],
                existing.processObjectIDs == app.processObjectIDs,
                existing.outputDeviceID == outputDeviceID
            {
                existing.setMuted(app.isMuted)
                continue
            }

            if let stale = taps.removeValue(forKey: app.ownerPID) {
                stale.teardown()
            }

            let tap = ProcessAudioTap(
                ownerPID: app.ownerPID,
                processObjectIDs: app.processObjectIDs,
                outputDeviceID: outputDeviceID,
                linearGain: effectiveGain(of: app),
                isMuted: app.isMuted
            )
            let clock = ContinuousClock()
            let started = clock.now
            do {
                try tap.start()
                taps[app.ownerPID] = tap
                let elapsed = clock.now - started
                coreAudioLog.notice(
                    "Tap created for \(app.name, privacy: .public) (pid \(app.ownerPID)) with \(app.processObjectIDs.count) processes in \(String(describing: elapsed), privacy: .public)"
                )
            } catch {
                coreAudioLog.error(
                    "Could not start the tap for \(app.name, privacy: .public) (pid \(app.ownerPID)): \(String(describing: error), privacy: .public)"
                )
            }
        }

        updateCaptureMonitor()
    }

    private func teardownAllTaps(waitUntilDone: Bool = false) {
        for tap in taps.values {
            tap.teardown(waitUntilDone: waitUntilDone)
        }
        taps.removeAll()
    }

    private func updateCaptureMonitor() {
        if taps.isEmpty {
            showsCaptureWarning = false
        }
        guard !isCaptureVerified, !taps.isEmpty else {
            captureMonitorTask?.cancel()
            captureMonitorTask = nil
            return
        }
        guard captureMonitorTask == nil else { return }
        captureMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.checkCapture()
            }
        }
    }

    private func checkCapture() {
        if taps.values.contains(where: \.hasSeenSignal) {
            isCaptureVerified = true
            defaults.set(true, forKey: Self.captureVerifiedKey)
            showsCaptureWarning = false
            captureMonitorTask?.cancel()
            captureMonitorTask = nil
            coreAudioLog.notice("Audio capture verified: tapped audio is reaching Fader")
            syncTaps()
            return
        }
        let now = ContinuousClock.now
        let playingPIDs = Set(apps.filter(\.isPlaying).map(\.ownerPID))
        showsCaptureWarning = taps.values.contains { tap in
            playingPIDs.contains(tap.ownerPID) && now - tap.createdAt > Self.captureWarningDelay
        }
    }

    private func handleDefaultOutputDeviceChange() {
        let resolved: AudioObjectID? = AudioObjectID.system.getPropertyData(
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        let newDeviceID = resolved ?? .unknown
        guard newDeviceID != outputDeviceID else {
            refreshMasterState()
            return
        }

        let clock = ContinuousClock()
        let started = clock.now
        teardownAllTaps()
        refreshOutputDevice()
        syncTaps()
        let elapsed = clock.now - started
        coreAudioLog.notice(
            "Output switched to \(self.outputDeviceName, privacy: .public), main thread work took \(String(describing: elapsed), privacy: .public) for \(self.taps.count) taps"
        )
    }

    private func refreshOutputDevice() {
        let resolved: AudioObjectID? = AudioObjectID.system.getPropertyData(
            selector: kAudioHardwarePropertyDefaultOutputDevice
        )
        outputDeviceID = resolved ?? .unknown

        guard outputDeviceID != .unknown else {
            outputDeviceName = "No output device"
            outputDeviceSymbol = "speaker.slash"
            isMasterVolumeAvailable = false
            isMasterMuteAvailable = false
            return
        }

        outputDeviceName = outputDeviceID.getStringProperty(selector: kAudioObjectPropertyName) ?? "Audio output"
        outputDeviceSymbol = symbolName(forDevice: outputDeviceID, name: outputDeviceName)
        observeOutputDevice(outputDeviceID)
        refreshMasterState()
    }

    private func observeOutputDevice(_ deviceID: AudioObjectID) {
        let existingDevices: [AudioObjectID] = AudioObjectID.system.getPropertyArray(
            selector: kAudioHardwarePropertyDevices
        ) ?? []
        observedOutputDevices.formIntersection(existingDevices)
        guard !observedOutputDevices.contains(deviceID) else { return }
        observedOutputDevices.insert(deviceID)

        addListener(
            to: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        ) { manager in
            manager.refreshMasterState()
        }
        addListener(
            to: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        ) { manager in
            manager.refreshMasterState()
        }
    }

    private func refreshMasterState() {
        guard outputDeviceID != .unknown else { return }

        isMasterVolumeAvailable = outputDeviceID.isPropertySettable(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioObjectPropertyScopeOutput
        )
        if isMasterVolumeAvailable {
            let volume: Float32? = outputDeviceID.getPropertyData(
                selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                scope: kAudioObjectPropertyScopeOutput
            )
            masterVolume = volume ?? masterVolume
        } else {
            masterVolume = 1
        }

        isMasterMuteAvailable = outputDeviceID.isPropertySettable(
            selector: kAudioDevicePropertyMute,
            scope: kAudioObjectPropertyScopeOutput
        )
        if isMasterMuteAvailable {
            let muted: UInt32? = outputDeviceID.getPropertyData(
                selector: kAudioDevicePropertyMute,
                scope: kAudioObjectPropertyScopeOutput
            )
            isMasterMuted = (muted ?? 0) != 0
        } else {
            isMasterMuted = false
        }
    }

    private func symbolName(forDevice deviceID: AudioObjectID, name: String) -> String {
        let transport: UInt32 = deviceID.getPropertyData(selector: kAudioDevicePropertyTransportType) ?? 0
        let lowered = name.lowercased()
        if lowered.contains("airpods max") {
            return "airpodsmax"
        }
        if lowered.contains("airpods pro") {
            return "airpodspro"
        }
        if lowered.contains("airpods") {
            return "airpods"
        }
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return lowered.contains("fone") || lowered.contains("headphone") ? "headphones" : "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return "hifispeaker.fill"
        default:
            return "speaker.wave.2.fill"
        }
    }

    private func persistVolume(_ volume: Float, forAppID id: String) {
        guard !isPreview else { return }
        var stored = defaults.dictionary(forKey: Self.volumesKey) as? [String: Double] ?? [:]
        stored[id] = Double(volume)
        defaults.set(stored, forKey: Self.volumesKey)
    }

    private func persistMute(_ muted: Bool, forAppID id: String) {
        guard !isPreview else { return }
        var stored = defaults.dictionary(forKey: Self.mutesKey) as? [String: Bool] ?? [:]
        stored[id] = muted
        defaults.set(stored, forKey: Self.mutesKey)
    }

    private func persistRole(_ role: AppRole, forAppID id: String) {
        guard !isPreview else { return }
        var stored = defaults.dictionary(forKey: Self.rolesKey) as? [String: String] ?? [:]
        if role == .normal {
            stored[id] = nil
        } else {
            stored[id] = role.rawValue
        }
        defaults.set(stored, forKey: Self.rolesKey)
    }
}
