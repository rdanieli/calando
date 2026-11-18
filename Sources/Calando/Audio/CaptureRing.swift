import Foundation
import Synchronization

struct CapturedAudio: Sendable {
    let samples: [Float32]
    let sampleRate: Double
}

struct CaptureSink {
    let storage: UnsafeMutablePointer<Float32>
    let mask: Int
    let writeIndex: UnsafeMutablePointer<Atomic<Int>>
    let isEnabled: UnsafeMutablePointer<Atomic<Bool>>

    @inline(__always)
    func writeMono(
        left: UnsafeMutablePointer<Float32>,
        leftStride: Int,
        right: UnsafeMutablePointer<Float32>,
        rightStride: Int,
        frames: Int
    ) {
        guard isEnabled.pointee.load(ordering: .relaxed) else { return }
        let start = writeIndex.pointee.load(ordering: .relaxed)
        var frame = 0
        while frame < frames {
            storage[(start &+ frame) & mask] = (left[frame * leftStride] + right[frame * rightStride]) * 0.5
            frame += 1
        }
        writeIndex.pointee.store(start &+ frames, ordering: .releasing)
    }
}

final class CaptureRing: @unchecked Sendable {
    static let defaultCapacity = 1 << 17

    let sink: CaptureSink
    private let capacity: Int
    private var readIndex = 0

    init(capacity: Int = CaptureRing.defaultCapacity) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0)
        self.capacity = capacity
        let storage = UnsafeMutablePointer<Float32>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        let writeIndex = UnsafeMutablePointer<Atomic<Int>>.allocate(capacity: 1)
        writeIndex.initialize(to: Atomic<Int>(0))
        let isEnabled = UnsafeMutablePointer<Atomic<Bool>>.allocate(capacity: 1)
        isEnabled.initialize(to: Atomic<Bool>(false))
        sink = CaptureSink(storage: storage, mask: capacity - 1, writeIndex: writeIndex, isEnabled: isEnabled)
    }

    var isEnabled: Bool {
        sink.isEnabled.pointee.load(ordering: .relaxed)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            readIndex = sink.writeIndex.pointee.load(ordering: .acquiring)
        }
        sink.isEnabled.pointee.store(enabled, ordering: .relaxed)
    }

    func drain() -> [Float32] {
        let written = sink.writeIndex.pointee.load(ordering: .acquiring)
        var cursor = readIndex
        if written - cursor > capacity {
            cursor = written - capacity
        }
        let count = written - cursor
        guard count > 0 else { return [] }
        var samples = [Float32](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            samples[offset] = sink.storage[(cursor &+ offset) & sink.mask]
            offset += 1
        }
        readIndex = written
        return samples
    }

    func release() {
        sink.storage.deinitialize(count: capacity)
        sink.storage.deallocate()
        sink.writeIndex.deinitialize(count: 1)
        sink.writeIndex.deallocate()
        sink.isEnabled.deinitialize(count: 1)
        sink.isEnabled.deallocate()
    }
}
