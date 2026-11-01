import Foundation
import CoreAudio
import CoreFoundation

struct AudioDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let outputChannels: Int
    let alive: Bool
    var isBoseUSB: Bool { name == "Bose Flex SoundLink" && transport == kAudioDeviceTransportTypeUSB && outputChannels == 2 && alive }
}

enum AudioDevices {
    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var value = fallback, size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? value : fallback
    }
    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        var value: CFString?; var n = UInt32(MemoryLayout<CFString?>.size)
        let s = withUnsafeMutableBytes(of: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &n, $0.baseAddress!) }
        return s == noErr ? value as String? : nil
    }
    static func outputs() -> [AudioDevice] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == 0 else { return [] }
        let stride = MemoryLayout<AudioDeviceID>.size
        guard size >= stride, size % UInt32(stride) == 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / stride)
        let readStatus = ids.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, bytes.baseAddress!)
        }
        guard readStatus == 0, size % UInt32(stride) == 0, Int(size) <= ids.count * stride else { return [] }
        ids.removeSubrange(Int(size) / stride..<ids.count)
        return ids.compactMap(device)
    }
    static func current() -> AudioDevice? {
        let id = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, fallback: AudioDeviceID(0))
        return id == 0 ? nil : device(id)
    }
    private static func device(_ id: AudioDeviceID) -> AudioDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: 0)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &byteCount) == noErr,
              byteCount >= MemoryLayout<AudioBufferList>.size,
              byteCount <= 64 * 1024 else { return nil }
        let words = (Int(byteCount) + MemoryLayout<AudioBufferList>.stride - 1) / MemoryLayout<AudioBufferList>.stride
        let channels: Int = withUnsafeTemporaryAllocation(of: AudioBufferList.self, capacity: words) { storage in
            guard let base = storage.baseAddress else { return 0 }
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &byteCount, UnsafeMutableRawPointer(base)) == noErr else { return 0 }
            return UnsafeMutableAudioBufferListPointer(base).reduce(0) { $0 + Int($1.mNumberChannels) }
        }
        guard channels > 0 else { return nil }
        return AudioDevice(id: id, uid: uid, name: name,
                           transport: scalar(id, kAudioDevicePropertyTransportType, fallback: UInt32(0)),
                           outputChannels: channels,
                           alive: scalar(id, kAudioDevicePropertyDeviceIsAlive, fallback: UInt32(0)) != 0)
    }
    static func setDefault(_ device: AudioDevice) throws {
        guard device.alive else { throw BridgeError("출력 장치가 연결되어 있지 않습니다.") }
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0), id = device.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout.size(ofValue: id)), &id)
        guard status == 0, current()?.uid == device.uid else { throw BridgeError("Mac 출력 전환에 실패했습니다 (\(status)).") }
    }
    static func volume(_ d: AudioDevice) -> Float? {
        let value: Float = scalar(d.id, kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, fallback: Float.nan)
        return value.isFinite ? value : nil
    }
    static func setVolume(_ value: Float, on d: AudioDevice) throws {
        guard d.isBoseUSB, value.isFinite, (0...1).contains(value) else { throw BridgeError("Bose USB 음량 대상이 올바르지 않습니다.") }
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: 0), v = value
        let status = AudioObjectSetPropertyData(d.id, &a, 0, nil, 4, &v)
        guard status == 0 else { throw BridgeError("Bose 음량 설정에 실패했습니다 (\(status)).") }
    }
}

final class AudioObserver {
    private struct Registration { var object: AudioObjectID; var address: AudioObjectPropertyAddress; var block: AudioObjectPropertyListenerBlock }
    private var entries: [Registration] = []
    @discardableResult
    func add(_ object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, action: @escaping () -> Void) -> Bool {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        guard AudioObjectAddPropertyListenerBlock(object, &a, DispatchQueue.main, block) == noErr else { return false }
        entries.append(Registration(object: object, address: a, block: block))
        return true
    }
    func clear() { for var r in entries { AudioObjectRemovePropertyListenerBlock(r.object, &r.address, DispatchQueue.main, r.block) }; entries.removeAll() }
    deinit { clear() }
}
