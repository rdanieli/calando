import AudioToolbox
import CoreAudio
import Foundation
import Synchronization
import os

enum VolumeCurve {
    static let minimum: Float = 0.0
    static let unity: Float = 1.0
    static let maximum: Float = 1.5

    static func linearGain(forSliderValue value: Float) -> Float {
        let clamped = min(max(value, minimum), maximum)
        return clamped <= unity ? clamped * clamped : clamped
    }
}

struct TapRenderState {
    let targetGainBits: UnsafeMutablePointer<Atomic<UInt32>>
    let isMuted: UnsafeMutablePointer<Atomic<Bool>>
    let slewFrames: UnsafeMutablePointer<Atomic<UInt32>>
    let sawSignal: UnsafeMutablePointer<Atomic<Bool>>
    var currentGain: Float32
    let leftOutputChannel: Int
    let rightOutputChannel: Int
}

struct ChannelCursor {
    let samples: UnsafeMutablePointer<Float32>?
    let stride: Int
    let frames: Int

    static var empty: ChannelCursor {
        ChannelCursor(samples: nil, stride: 1, frames: 0)
    }
}

@inline(__always)
func softClip(_ sample: Float32) -> Float32 {
    let knee: Float32 = 0.75
    let headroom: Float32 = 0.25
    let magnitude = abs(sample)
    if magnitude <= knee {
        return sample
    }
    let shaped = knee + headroom * tanhf((magnitude - knee) / headroom)
    return sample < 0 ? -shaped : shaped
}

@inline(__always)
private func shapeSample(_ sample: Float32, gain: Float32) -> Float32 {
    let scaled = sample * gain
    return gain > 1.0 ? softClip(scaled) : scaled
}

@inline(__always)
private func approach(_ current: Float32, _ target: Float32, _ maximumStep: Float32) -> Float32 {
    let delta = target - current
    if delta > maximumStep {
        return current + maximumStep
    }
    if delta < -maximumStep {
        return current - maximumStep
    }
    return target
}

@inline(__always)
private func totalChannelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
    var total = 0
    var index = 0
    let count = list.count
    while index < count {
        total += Int(list[index].mNumberChannels)
        index += 1
    }
    return total
}

@inline(__always)
private func locateChannel(_ list: UnsafeMutableAudioBufferListPointer, _ channel: Int) -> ChannelCursor {
    var firstChannelOfBuffer = 0
    var index = 0
    let count = list.count
    while index < count {
        let buffer = list[index]
        let channels = Int(buffer.mNumberChannels)
        if channels > 0, channel < firstChannelOfBuffer + channels {
            guard let data = buffer.mData else { return .empty }
            let samples = data.assumingMemoryBound(to: Float32.self) + (channel - firstChannelOfBuffer)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
            return ChannelCursor(samples: samples, stride: channels, frames: frames)
        }
        firstChannelOfBuffer += channels
        index += 1
    }
    return .empty
}

func faderRenderProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    let output = UnsafeMutableAudioBufferListPointer(outputData)
    var bufferIndex = 0
    let outputBufferCount = output.count
    while bufferIndex < outputBufferCount {
        let buffer = output[bufferIndex]
        if let data = buffer.mData {
            memset(data, 0, Int(buffer.mDataByteSize))
        }
        bufferIndex += 1
    }

    guard let clientData else { return noErr }
    let state = clientData.assumingMemoryBound(to: TapRenderState.self)

    let muted = state.pointee.isMuted.pointee.load(ordering: .relaxed)
    let requestedGain = Float32(bitPattern: state.pointee.targetGainBits.pointee.load(ordering: .relaxed))
    let targetGain: Float32 = muted ? 0.0 : requestedGain
    let startGain = state.pointee.currentGain
    state.pointee.currentGain = targetGain

    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    let inputChannels = totalChannelCount(input)
    let outputChannels = totalChannelCount(output)
    guard inputChannels > 0, outputChannels > 0 else { return noErr }

    let inputLeft = locateChannel(input, 0)
    let inputRight = locateChannel(input, inputChannels > 1 ? 1 : 0)
    let leftIndex = min(state.pointee.leftOutputChannel, outputChannels - 1)
    let rightIndex = min(state.pointee.rightOutputChannel, outputChannels - 1)
    let outputLeft = locateChannel(output, leftIndex)
    let outputRight = locateChannel(output, rightIndex)

    guard
        let inLeft = inputLeft.samples,
        let inRight = inputRight.samples,
        let outLeft = outputLeft.samples,
        let outRight = outputRight.samples
    else { return noErr }

    let frames = min(min(inputLeft.frames, inputRight.frames), min(outputLeft.frames, outputRight.frames))
    guard frames > 0 else { return noErr }

    let slewFrames = max(state.pointee.slewFrames.pointee.load(ordering: .relaxed), 1)
    let maximumStep = 1.0 / Float32(slewFrames)
    let inLeftStride = inputLeft.stride
    let inRightStride = inputRight.stride
    let outLeftStride = outputLeft.stride
    let outRightStride = outputRight.stride
    var gain = startGain
    var energy: Float32 = 0
    var frame = 0

    if leftIndex == rightIndex {
        while frame < frames {
            gain = approach(gain, targetGain, maximumStep)
            let left = inLeft[frame * inLeftStride]
            let right = inRight[frame * inRightStride]
            energy += abs(left) + abs(right)
            outLeft[frame * outLeftStride] = shapeSample((left + right) * 0.5, gain: gain)
            frame += 1
        }
    } else {
        while frame < frames {
            gain = approach(gain, targetGain, maximumStep)
            let left = inLeft[frame * inLeftStride]
            let right = inRight[frame * inRightStride]
            energy += abs(left) + abs(right)
            outLeft[frame * outLeftStride] = shapeSample(left, gain: gain)
            outRight[frame * outRightStride] = shapeSample(right, gain: gain)
            frame += 1
        }
    }

    state.pointee.currentGain = gain
    if energy > 0 {
        state.pointee.sawSignal.pointee.store(true, ordering: .relaxed)
    }

    return noErr
}

enum ProcessAudioTapError: Error, CustomStringConvertible {
    case tapCreationFailed(OSStatus)
    case outputDeviceUIDUnavailable
    case aggregateCreationFailed(OSStatus)
    case unsupportedTapFormat
    case alreadyReleased

    var description: String {
        switch self {
        case .tapCreationFailed(let status):
            return "AudioHardwareCreateProcessTap failed: \(describeStatus(status))"
        case .outputDeviceUIDUnavailable:
            return "Output device UID unavailable"
        case .aggregateCreationFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed: \(describeStatus(status))"
        case .unsupportedTapFormat:
            return "Tap format is not Float32 linear PCM"
        case .alreadyReleased:
            return "Tap was already torn down"
        }
    }
}

private final class TapIOSession: @unchecked Sendable {
    let ownerPID: pid_t
    let renderState: UnsafeMutablePointer<TapRenderState>
    let targetGainBits: UnsafeMutablePointer<Atomic<UInt32>>
    let mutedFlag: UnsafeMutablePointer<Atomic<Bool>>
    let slewFrames: UnsafeMutablePointer<Atomic<UInt32>>
    let sawSignal: UnsafeMutablePointer<Atomic<Bool>>
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    init(
        ownerPID: pid_t,
        renderState: UnsafeMutablePointer<TapRenderState>,
        targetGainBits: UnsafeMutablePointer<Atomic<UInt32>>,
        mutedFlag: UnsafeMutablePointer<Atomic<Bool>>,
        slewFrames: UnsafeMutablePointer<Atomic<UInt32>>,
        sawSignal: UnsafeMutablePointer<Atomic<Bool>>
    ) {
        self.ownerPID = ownerPID
        self.renderState = renderState
        self.targetGainBits = targetGainBits
        self.mutedFlag = mutedFlag
        self.slewFrames = slewFrames
        self.sawSignal = sawSignal
    }

    func startIO(on aggregateDeviceID: AudioObjectID) {
        let clock = ContinuousClock()
        let began = clock.now
        var newProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcID(aggregateDeviceID, faderRenderProc, renderState, &newProcID)
        guard status == noErr, let newProcID else {
            coreAudioLog.error("AudioDeviceCreateIOProcID failed for pid \(self.ownerPID): \(describeStatus(status), privacy: .public)")
            return
        }
        ioProcID = newProcID
        let procReady = clock.now

        status = AudioDeviceStart(aggregateDeviceID, newProcID)
        guard status == noErr else {
            coreAudioLog.error("AudioDeviceStart failed for pid \(self.ownerPID): \(describeStatus(status), privacy: .public)")
            return
        }
        isRunning = true
        coreAudioLog.notice(
            "Tap IO for pid \(self.ownerPID) running: IOProc \(String(describing: procReady - began), privacy: .public), AudioDeviceStart \(String(describing: clock.now - procReady), privacy: .public)"
        )
    }

    func shutDown(aggregateDeviceID: AudioObjectID, tapID: AudioObjectID) {
        if let ioProcID {
            if isRunning {
                report(AudioDeviceStop(aggregateDeviceID, ioProcID), "AudioDeviceStop")
                isRunning = false
            }
            report(AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID), "AudioDeviceDestroyIOProcID")
            self.ioProcID = nil
        }
        if aggregateDeviceID != .unknown {
            report(AudioHardwareDestroyAggregateDevice(aggregateDeviceID), "AudioHardwareDestroyAggregateDevice")
        }
        if tapID != .unknown {
            report(AudioHardwareDestroyProcessTap(tapID), "AudioHardwareDestroyProcessTap")
        }
        renderState.deinitialize(count: 1)
        renderState.deallocate()
        targetGainBits.deinitialize(count: 1)
        targetGainBits.deallocate()
        mutedFlag.deinitialize(count: 1)
        mutedFlag.deallocate()
        slewFrames.deinitialize(count: 1)
        slewFrames.deallocate()
        sawSignal.deinitialize(count: 1)
        sawSignal.deallocate()
    }

    private func report(_ status: OSStatus, _ operation: String) {
        guard status != noErr else { return }
        coreAudioLog.error("\(operation, privacy: .public) failed for pid \(self.ownerPID): \(describeStatus(status), privacy: .public)")
    }
}

@MainActor
final class ProcessAudioTap {
    let ownerPID: pid_t
    let processObjectIDs: [AudioObjectID]
    let outputDeviceID: AudioObjectID
    let createdAt = ContinuousClock.now

    private var tapID = AudioObjectID.unknown
    private var aggregateDeviceID = AudioObjectID.unknown
    private var isReleased = false
    private let tapUUID = UUID()
    private let sampleRate: Double

    private let targetGainBits: UnsafeMutablePointer<Atomic<UInt32>>
    private let mutedFlag: UnsafeMutablePointer<Atomic<Bool>>
    private let slewFrames: UnsafeMutablePointer<Atomic<UInt32>>
    private let sawSignal: UnsafeMutablePointer<Atomic<Bool>>
    private let session: TapIOSession
    private let ioQueue: DispatchQueue

    static let quickSlewSeconds = 0.012

    init(
        ownerPID: pid_t,
        processObjectIDs: [AudioObjectID],
        outputDeviceID: AudioObjectID,
        linearGain: Float,
        isMuted: Bool
    ) {
        self.ownerPID = ownerPID
        self.processObjectIDs = processObjectIDs
        self.outputDeviceID = outputDeviceID
        ioQueue = DispatchQueue(label: "com.local.fader.tap.\(ownerPID)", qos: .userInitiated)

        let nominalRate: Float64? = outputDeviceID.getPropertyData(selector: kAudioDevicePropertyNominalSampleRate)
        let resolvedRate = nominalRate ?? 0
        sampleRate = resolvedRate > 0 ? resolvedRate : 48_000

        targetGainBits = .allocate(capacity: 1)
        targetGainBits.initialize(to: Atomic<UInt32>(linearGain.bitPattern))
        mutedFlag = .allocate(capacity: 1)
        mutedFlag.initialize(to: Atomic<Bool>(isMuted))
        slewFrames = .allocate(capacity: 1)
        slewFrames.initialize(to: Atomic<UInt32>(UInt32(max(sampleRate * Self.quickSlewSeconds, 1))))
        sawSignal = .allocate(capacity: 1)
        sawSignal.initialize(to: Atomic<Bool>(false))

        let stereoChannels: [UInt32] = outputDeviceID.getPropertyArray(
            selector: kAudioDevicePropertyPreferredChannelsForStereo,
            scope: kAudioObjectPropertyScopeOutput
        ) ?? []
        let left = stereoChannels.count > 0 ? max(Int(stereoChannels[0]) - 1, 0) : 0
        let right = stereoChannels.count > 1 ? max(Int(stereoChannels[1]) - 1, 0) : 1

        let renderState = UnsafeMutablePointer<TapRenderState>.allocate(capacity: 1)
        renderState.initialize(
            to: TapRenderState(
                targetGainBits: targetGainBits,
                isMuted: mutedFlag,
                slewFrames: slewFrames,
                sawSignal: sawSignal,
                currentGain: isMuted ? 0.0 : linearGain,
                leftOutputChannel: left,
                rightOutputChannel: right
            )
        )
        session = TapIOSession(
            ownerPID: ownerPID,
            renderState: renderState,
            targetGainBits: targetGainBits,
            mutedFlag: mutedFlag,
            slewFrames: slewFrames,
            sawSignal: sawSignal
        )
    }

    var hasSeenSignal: Bool {
        guard !isReleased else { return false }
        return sawSignal.pointee.load(ordering: .relaxed)
    }

    func setGain(_ linearGain: Float, slewSeconds: Double) {
        guard !isReleased else { return }
        slewFrames.pointee.store(UInt32(max(sampleRate * slewSeconds, 1)), ordering: .relaxed)
        targetGainBits.pointee.store(linearGain.bitPattern, ordering: .relaxed)
    }

    func setMuted(_ muted: Bool) {
        guard !isReleased else { return }
        mutedFlag.pointee.store(muted, ordering: .relaxed)
    }

    func start() throws {
        guard !isReleased else { throw ProcessAudioTapError.alreadyReleased }
        do {
            try createTap()
            try createAggregateDevice()
            try validateTapFormat()
        } catch {
            teardown()
            throw error
        }
        let session = session
        let aggregateDeviceID = aggregateDeviceID
        ioQueue.async {
            session.startIO(on: aggregateDeviceID)
        }
    }

    func teardown(waitUntilDone: Bool = false) {
        guard !isReleased else { return }
        isReleased = true

        let session = session
        let aggregateDeviceID = aggregateDeviceID
        let tapID = tapID
        self.aggregateDeviceID = .unknown
        self.tapID = .unknown

        if waitUntilDone {
            ioQueue.sync {
                session.shutDown(aggregateDeviceID: aggregateDeviceID, tapID: tapID)
            }
        } else {
            ioQueue.async {
                session.shutDown(aggregateDeviceID: aggregateDeviceID, tapID: tapID)
            }
        }
    }

    private func createTap() throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = tapUUID
        description.muteBehavior = .mutedWhenTapped
        description.name = "FaderTap-\(ownerPID)"
        description.isPrivate = true

        var newTapID = AudioObjectID.unknown
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != .unknown else {
            throw ProcessAudioTapError.tapCreationFailed(status)
        }
        tapID = newTapID
    }

    private func createAggregateDevice() throws {
        guard let outputUID = outputDeviceID.getStringProperty(selector: kAudioDevicePropertyDeviceUID) else {
            throw ProcessAudioTapError.outputDeviceUIDUnavailable
        }
        let tapUID = tapID.getStringProperty(selector: kAudioTapPropertyUID) ?? tapUUID.uuidString

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FaderAgg-\(ownerPID)",
            kAudioAggregateDeviceUIDKey: "com.local.fader.agg.\(ownerPID).\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ] as [String: Any],
            ],
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
            ],
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
        ]

        var newDeviceID = AudioObjectID.unknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newDeviceID)
        guard status == noErr, newDeviceID != .unknown else {
            throw ProcessAudioTapError.aggregateCreationFailed(status)
        }
        aggregateDeviceID = newDeviceID
    }

    private func validateTapFormat() throws {
        let format: AudioStreamBasicDescription? = tapID.getPropertyData(selector: kAudioTapPropertyFormat)
        guard let format else { return }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard format.mFormatID == kAudioFormatLinearPCM, isFloat, format.mBitsPerChannel == 32 else {
            throw ProcessAudioTapError.unsupportedTapFormat
        }
    }
}
