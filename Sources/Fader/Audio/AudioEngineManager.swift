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

    @ObservationIgnored private var taps: [pid_t: ProcessAudioTap] = [:]
    @ObservationIgnored private var outputDeviceID = AudioObjectID.unknown
    @ObservationIgnored private var observedProcessObjects: Set<AudioObjectID> = []
    @ObservationIgnored private var observedOutputDevices: Set<AudioObjectID> = []
    @ObservationIgnored private var engagedAppIDs: Set<String> = []
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    private let defaults = UserDefaults.standard
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private static let volumesKey = "com.local.fader.appVolumes"
    private static let mutesKey = "com.local.fader.appMutes"

    init() {
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
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.teardownAllTaps(waitUntilDone: true)
            }
        }
        refreshProcesses()
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

    func resetAll() {
        for index in apps.indices {
            apps[index].volume = VolumeCurve.unity
            apps[index].isMuted = false
        }
        defaults.removeObject(forKey: Self.volumesKey)
        defaults.removeObject(forKey: Self.mutesKey)
        engagedAppIDs.removeAll()
        teardownAllTaps()
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
        }

        var groups: [String: ProcessGroup] = [:]
        for objectID in objectIDs {
            let resolvedPID: pid_t? = objectID.getPropertyData(selector: kAudioProcessPropertyPID)
            guard let pid = resolvedPID, pid != ownPID else { continue }
            let runningFlag: UInt32 = objectID.getPropertyData(selector: kAudioProcessPropertyIsRunningOutput) ?? 0
            let bundleID = objectID.getStringProperty(selector: kAudioProcessPropertyBundleID)
            guard
                let owner = ownerApplication(forPID: pid, bundleID: bundleID),
                owner.processIdentifier != ownPID
            else { continue }

            let key = owner.bundleIdentifier ?? owner.localizedName ?? "pid-\(owner.processIdentifier)"
            if var group = groups[key] {
                group.objectIDs.append(objectID)
                group.isRunningOutput = group.isRunningOutput || runningFlag != 0
                groups[key] = group
            } else {
                groups[key] = ProcessGroup(
                    application: owner,
                    objectIDs: [objectID],
                    isRunningOutput: runningFlag != 0
                )
            }
        }

        engagedAppIDs.formIntersection(groups.keys)

        let previous = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let storedVolumes = defaults.dictionary(forKey: Self.volumesKey) as? [String: Double] ?? [:]
        let storedMutes = defaults.dictionary(forKey: Self.mutesKey) as? [String: Bool] ?? [:]

        var refreshed: [AudioApp] = []
        for (key, group) in groups {
            let existing = previous[key]
            let volume = existing?.volume ?? storedVolumes[key].map { Float($0) } ?? VolumeCurve.unity
            let isMuted = existing?.isMuted ?? storedMutes[key] ?? false
            let app = AudioApp(
                id: key,
                name: existing?.name ?? displayName(of: group.application, fallback: key),
                icon: existing?.icon ?? group.application.icon ?? NSWorkspace.shared.icon(for: .application),
                ownerPID: group.application.processIdentifier,
                processObjectIDs: group.objectIDs.sorted(),
                isPlaying: group.isRunningOutput,
                volume: min(max(volume, VolumeCurve.minimum), VolumeCurve.maximum),
                isMuted: isMuted
            )
            if !app.isNeutral {
                engagedAppIDs.insert(key)
            }
            refreshed.append(app)
        }
        refreshed.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if refreshed.map(\.id) != apps.map(\.id) {
            let names = refreshed.map { $0.isPlaying ? "\($0.name) (playing)" : $0.name }.joined(separator: ", ")
            coreAudioLog.notice(
                "Apps with an audio session: [\(names, privacy: .public)] out of \(objectIDs.count) audio processes"
            )
        }
        apps = refreshed

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

    private func ownerApplication(forPID pid: pid_t, bundleID: String?) -> NSRunningApplication? {
        var candidate = pid
        var depth = 0
        while candidate > 1, depth < 16 {
            if let application = regularApplication(forPID: candidate) {
                return application
            }
            guard let parent = ProcessTree.parentPID(of: candidate), parent != candidate else { break }
            candidate = parent
            depth += 1
        }

        if
            let responsible = ProcessTree.responsiblePID(of: pid),
            responsible != pid,
            let application = regularApplication(forPID: responsible)
        {
            return application
        }

        guard let bundleID, !bundleID.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications
            .filter { application in
                guard application.activationPolicy == .regular, let identifier = application.bundleIdentifier else {
                    return false
                }
                return bundleID == identifier || bundleID.hasPrefix(identifier + ".")
            }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }

    private func regularApplication(forPID pid: pid_t) -> NSRunningApplication? {
        guard
            let application = NSRunningApplication(processIdentifier: pid),
            application.activationPolicy == .regular
        else { return nil }
        return application
    }

    private func applySettings(of app: AudioApp) {
        if !app.isNeutral {
            engagedAppIDs.insert(app.id)
        }
        if let tap = taps[app.ownerPID] {
            tap.setVolume(sliderValue: app.volume)
            tap.setMuted(app.isMuted)
        } else if engagedAppIDs.contains(app.id) {
            syncTaps()
        }
    }

    private func syncTaps() {
        let wanted = apps.filter { engagedAppIDs.contains($0.id) }
        let wantedPIDs = Set(wanted.map(\.ownerPID))

        for (pid, tap) in taps where !wantedPIDs.contains(pid) {
            tap.teardown()
            taps[pid] = nil
        }

        guard outputDeviceID != .unknown else {
            teardownAllTaps()
            return
        }

        for app in wanted {
            if
                let existing = taps[app.ownerPID],
                existing.processObjectIDs == app.processObjectIDs,
                existing.outputDeviceID == outputDeviceID
            {
                existing.setVolume(sliderValue: app.volume)
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
                sliderValue: app.volume,
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
    }

    private func teardownAllTaps(waitUntilDone: Bool = false) {
        for tap in taps.values {
            tap.teardown(waitUntilDone: waitUntilDone)
        }
        taps.removeAll()
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
        var stored = defaults.dictionary(forKey: Self.volumesKey) as? [String: Double] ?? [:]
        stored[id] = Double(volume)
        defaults.set(stored, forKey: Self.volumesKey)
    }

    private func persistMute(_ muted: Bool, forAppID id: String) {
        var stored = defaults.dictionary(forKey: Self.mutesKey) as? [String: Bool] ?? [:]
        stored[id] = muted
        defaults.set(stored, forKey: Self.mutesKey)
    }
}
