import CoreAudio
import Synchronization
import Testing

@testable import Calando

private final class RenderHarness {
    let gainBits = UnsafeMutablePointer<Atomic<UInt32>>.allocate(capacity: 1)
    let muted = UnsafeMutablePointer<Atomic<Bool>>.allocate(capacity: 1)
    let slewFrames = UnsafeMutablePointer<Atomic<UInt32>>.allocate(capacity: 1)
    let sawSignal = UnsafeMutablePointer<Atomic<Bool>>.allocate(capacity: 1)
    let state = UnsafeMutablePointer<TapRenderState>.allocate(capacity: 1)

    init(
        currentGain: Float,
        targetGain: Float,
        isMuted: Bool = false,
        slew: UInt32 = 512,
        left: Int = 0,
        right: Int = 1
    ) {
        gainBits.initialize(to: Atomic<UInt32>(targetGain.bitPattern))
        muted.initialize(to: Atomic<Bool>(isMuted))
        slewFrames.initialize(to: Atomic<UInt32>(slew))
        sawSignal.initialize(to: Atomic<Bool>(false))
        state.initialize(
            to: TapRenderState(
                targetGainBits: gainBits,
                isMuted: muted,
                slewFrames: slewFrames,
                sawSignal: sawSignal,
                currentGain: currentGain,
                leftOutputChannel: left,
                rightOutputChannel: right
            )
        )
    }

    deinit {
        state.deinitialize(count: 1)
        state.deallocate()
        gainBits.deinitialize(count: 1)
        gainBits.deallocate()
        muted.deinitialize(count: 1)
        muted.deallocate()
        slewFrames.deinitialize(count: 1)
        slewFrames.deallocate()
        sawSignal.deinitialize(count: 1)
        sawSignal.deallocate()
    }

    func render(input: [[Float32]], inputChannelsPerBuffer: Int, outputBuffers: Int, outputChannelsPerBuffer: Int, frames: Int) -> [[Float32]] {
        let inputList = AudioBufferList.allocate(maximumBuffers: input.count)
        let outputList = AudioBufferList.allocate(maximumBuffers: outputBuffers)
        defer {
            for buffer in inputList { buffer.mData?.deallocate() }
            for buffer in outputList { buffer.mData?.deallocate() }
            inputList.unsafeMutablePointer.deallocate()
            outputList.unsafeMutablePointer.deallocate()
        }

        for (index, samples) in input.enumerated() {
            let storage = UnsafeMutablePointer<Float32>.allocate(capacity: samples.count)
            storage.initialize(from: samples, count: samples.count)
            inputList[index] = AudioBuffer(
                mNumberChannels: UInt32(inputChannelsPerBuffer),
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float32>.size),
                mData: storage
            )
        }
        for index in 0..<outputBuffers {
            let count = frames * outputChannelsPerBuffer
            let storage = UnsafeMutablePointer<Float32>.allocate(capacity: count)
            storage.initialize(repeating: 9, count: count)
            outputList[index] = AudioBuffer(
                mNumberChannels: UInt32(outputChannelsPerBuffer),
                mDataByteSize: UInt32(count * MemoryLayout<Float32>.size),
                mData: storage
            )
        }

        var timestamp = AudioTimeStamp()
        let status = calandoRenderProc(
            0,
            &timestamp,
            inputList.unsafePointer,
            &timestamp,
            outputList.unsafeMutablePointer,
            &timestamp,
            state
        )
        #expect(status == noErr)

        return outputList.map { buffer in
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let pointer = buffer.mData!.assumingMemoryBound(to: Float32.self)
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        }
    }
}

@Test func curveHitsTheAnchorPoints() {
    #expect(VolumeCurve.linearGain(forSliderValue: 0) == 0)
    #expect(VolumeCurve.linearGain(forSliderValue: 0.5) == 0.25)
    #expect(VolumeCurve.linearGain(forSliderValue: 1) == 1)
    #expect(VolumeCurve.linearGain(forSliderValue: 1.5) == 1.5)
    #expect(VolumeCurve.linearGain(forSliderValue: 9) == 1.5)
    #expect(VolumeCurve.linearGain(forSliderValue: -1) == 0)
}

@Test func softClipIsTransparentBelowTheKneeAndBoundedAbove() {
    #expect(softClip(0.5) == 0.5)
    #expect(softClip(-0.75) == -0.75)
    #expect(softClip(4) <= 1)
    #expect(softClip(4) > 0.99)
    #expect(softClip(-4) == -softClip(4))
    #expect(softClip(0.9) < 0.9)
    #expect(softClip(0.9) > 0.75)
}

@Test func unityGainPassesInterleavedStereoUntouched() {
    let harness = RenderHarness(currentGain: 1, targetGain: 1)
    let input: [Float32] = [0.1, -0.1, 0.2, -0.2, 0.9, -0.9, 1.0, -1.0]
    let output = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: 4)
    #expect(output == [input])
}

@Test func steadyGainScalesPlanarInputIntoInterleavedOutput() {
    let harness = RenderHarness(currentGain: 0.5, targetGain: 0.5)
    let left: [Float32] = [0.2, 0.4, 0.6, 0.8]
    let right: [Float32] = [-0.2, -0.4, -0.6, -0.8]
    let output = harness.render(input: [left, right], inputChannelsPerBuffer: 1, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: 4)
    #expect(output == [[0.1, -0.1, 0.2, -0.2, 0.3, -0.3, 0.4, -0.4]])
}

@Test func interleavedInputFeedsPlanarOutput() {
    let harness = RenderHarness(currentGain: 1, targetGain: 1)
    let input: [Float32] = [0.1, 0.5, 0.2, 0.6, 0.3, 0.7]
    let output = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 2, outputChannelsPerBuffer: 1, frames: 3)
    #expect(output == [[0.1, 0.2, 0.3], [0.5, 0.6, 0.7]])
}

@Test func gainRampsLinearlyAcrossTheBufferAndLandsOnTarget() {
    let harness = RenderHarness(currentGain: 0, targetGain: 1)
    let frames = 512
    let ones = [Float32](repeating: 0.5, count: frames * 2)
    let output = harness.render(input: [ones], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: frames)[0]
    let left = stride(from: 0, to: output.count, by: 2).map { output[$0] }
    #expect(left.first! > 0)
    #expect(left.first! < 0.01)
    #expect(left.last! == 0.5)
    #expect(zip(left, left.dropFirst()).allSatisfy { $0 < $1 })
    let largestStep = zip(left, left.dropFirst()).map { $1 - $0 }.max()!
    #expect(largestStep < 0.002)
    #expect(harness.state.pointee.currentGain == 1)
}

@Test func muteFadesToSilenceInsteadOfCuttingAbruptly() {
    let harness = RenderHarness(currentGain: 1, targetGain: 1, isMuted: true, slew: 256)
    let frames = 256
    let input = [Float32](repeating: 0.8, count: frames * 2)
    let first = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: frames)[0]
    #expect(first[0] > 0.7)
    #expect(first[first.count - 1] == 0)
    let second = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: frames)[0]
    #expect(second.allSatisfy { $0 == 0 })
}

@Test func amplificationNeverExceedsFullScale() {
    let harness = RenderHarness(currentGain: 1.5, targetGain: 1.5)
    let input: [Float32] = [1.0, -1.0, 0.9, -0.9, 0.4, -0.4]
    let output = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: 3)[0]
    #expect(output.allSatisfy { abs($0) < 1 })
    #expect(abs(output[4] - 0.6) < 0.0001)
    #expect(output[0] > 0.95)
}

@Test func monoOutputReceivesTheAverageOfBothChannels() {
    let harness = RenderHarness(currentGain: 1, targetGain: 1)
    let input: [Float32] = [0.2, 0.6, -0.4, 0.0]
    let output = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 1, frames: 2)
    #expect(abs(output[0][0] - 0.4) < 0.0001)
    #expect(abs(output[0][1] + 0.2) < 0.0001)
}

@Test func missingInputProducesSilence() {
    let harness = RenderHarness(currentGain: 1, targetGain: 1)
    let output = harness.render(input: [[]], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: 4)
    #expect(output == [[0, 0, 0, 0, 0, 0, 0, 0]])
}

@Test func slowSlewSpreadsTheFadeAcrossSeveralBuffers() {
    let harness = RenderHarness(currentGain: 1, targetGain: 0.25, slew: 1024)
    let frames = 256
    let input = [Float32](repeating: 1, count: frames * 2)
    let first = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: frames)[0]
    #expect(first[first.count - 1] == 0.75)
    #expect(harness.state.pointee.currentGain == 0.75)
    _ = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: frames)
    let third = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: frames)[0]
    #expect(third[third.count - 1] == 0.25)
    let fourth = harness.render(input: [input], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: frames)[0]
    #expect(fourth.allSatisfy { $0 == 0.25 })
}

@Test func signalFlagIsRaisedOnlyByAudibleInput() {
    let silent = RenderHarness(currentGain: 1, targetGain: 1)
    _ = silent.render(input: [[0, 0, 0, 0]], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: 2)
    #expect(silent.sawSignal.pointee.load(ordering: .relaxed) == false)

    let audible = RenderHarness(currentGain: 0, targetGain: 0, isMuted: true)
    _ = audible.render(input: [[0, 0, 0.3, -0.3]], inputChannelsPerBuffer: 2, outputBuffers: 1, outputChannelsPerBuffer: 2, frames: 2)
    #expect(audible.sawSignal.pointee.load(ordering: .relaxed) == true)
}
