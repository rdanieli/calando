import CoreAudio
import Foundation
import os

let coreAudioLog = Logger(subsystem: "com.local.fader", category: "CoreAudio")

func fourCharacterCode(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    let isPrintable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    guard isPrintable, let text = String(bytes: bytes, encoding: .ascii) else {
        return String(value)
    }
    return "'\(text)'"
}

func describeStatus(_ status: OSStatus) -> String {
    "\(status) \(fourCharacterCode(UInt32(bitPattern: status)))"
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    func hasProperty(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        return AudioObjectHasProperty(self, &address)
    }

    func isPropertySettable(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(self, &address) else { return false }
        var settable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(self, &address, &settable)
        guard status == noErr else {
            logFailure("IsPropertySettable", selector: selector, status: status)
            return false
        }
        return settable.boolValue
    }

    func getPropertyData<T>(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        let byteCount = MemoryLayout<T>.size
        var size = UInt32(byteCount)
        let storage = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { storage.deallocate() }
        UnsafeMutableRawPointer(storage).initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, storage)
        guard status == noErr else {
            logFailure("GetPropertyData", selector: selector, status: status)
            return nil
        }
        guard Int(size) == byteCount else {
            coreAudioLog.error(
                "GetPropertyData \(fourCharacterCode(selector), privacy: .public) no objeto \(self) devolveu \(size) bytes, esperado \(byteCount)"
            )
            return nil
        }
        return storage.move()
    }

    func getPropertyArray<T>(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> [T]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard status == noErr else {
            logFailure("GetPropertyDataSize", selector: selector, status: status)
            return nil
        }
        let stride = MemoryLayout<T>.stride
        let capacity = Int(size) / stride
        guard capacity > 0 else { return [] }
        let storage = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        defer { storage.deallocate() }
        status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, storage)
        guard status == noErr else {
            logFailure("GetPropertyData", selector: selector, status: status)
            return nil
        }
        let count = Swift.min(capacity, Int(size) / stride)
        return Array(UnsafeBufferPointer(start: storage, count: count))
    }

    @discardableResult
    func setPropertyData<T>(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        value: T
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: value) { pointer in
            AudioObjectSetPropertyData(self, &address, 0, nil, size, pointer)
        }
        guard status == noErr else {
            logFailure("SetPropertyData", selector: selector, status: status)
            return false
        }
        return true
    }

    func getStringProperty(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> String? {
        let value: CFString?? = getPropertyData(selector: selector, scope: scope, element: element)
        guard let string = value ?? nil else { return nil }
        return string as String
    }

    private func logFailure(_ operation: String, selector: AudioObjectPropertySelector, status: OSStatus) {
        coreAudioLog.error(
            "\(operation, privacy: .public) \(fourCharacterCode(selector), privacy: .public) falhou no objeto \(self): \(describeStatus(status), privacy: .public)"
        )
    }
}
