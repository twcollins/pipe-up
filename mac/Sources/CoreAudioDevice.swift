import CoreAudio
import Foundation

/// Thin helpers around the CoreAudio HAL for the default input device.
enum CoreAudioDevice {
    private static func addr(_ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return err == noErr && id != 0 ? id : nil
    }

    static func name(of id: AudioDeviceID) -> String {
        var a = addr(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name)
        guard err == noErr, let n = name?.takeRetainedValue() else { return "Unknown device" }
        return n as String
    }

    /// Elements that carry an input volume control (main, or per-channel).
    private static func volumeElements(_ id: AudioDeviceID) -> [AudioObjectPropertyElement] {
        var main = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &main) { return [kAudioObjectPropertyElementMain] }
        return (1...8).compactMap { ch -> AudioObjectPropertyElement? in
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, AudioObjectPropertyElement(ch))
            return AudioObjectHasProperty(id, &a) ? AudioObjectPropertyElement(ch) : nil
        }
    }

    /// macOS "Input volume" (0...1), or nil if the device has no volume control.
    static func inputVolume(_ id: AudioDeviceID) -> Float? {
        let els = volumeElements(id)
        guard !els.isEmpty else { return nil }
        var total: Float = 0
        for el in els {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) != noErr { return nil }
            total += v
        }
        return total / Float(els.count)
    }

    @discardableResult
    static func setInputVolume(_ id: AudioDeviceID, _ value: Float) -> Bool {
        var ok = false
        for el in volumeElements(id) {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue else { continue }
            var v = Float32(min(max(value, 0), 1))
            if AudioObjectSetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr { ok = true }
        }
        return ok
    }

    static func isInputMuted(_ id: AudioDeviceID) -> Bool {
        var a = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        guard AudioObjectHasProperty(id, &a) else { return false }
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr && v != 0
    }

    // MARK: Listeners

    typealias Token = (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)

    static func listenDefaultInput(_ handler: @escaping () -> Void) -> Token {
        listen(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDefaultInputDevice), handler)
    }

    /// Listens for volume + mute changes on a device. Returns tokens to remove later.
    static func listenVolume(_ id: AudioDeviceID, _ handler: @escaping () -> Void) -> [Token] {
        var tokens: [Token] = []
        var els = volumeElements(id)
        if els.isEmpty { els = [kAudioObjectPropertyElementMain] }
        for el in els {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeInput, el)
            if AudioObjectHasProperty(id, &a) { tokens.append(listen(id, a, handler)) }
        }
        var m = addr(kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput)
        if AudioObjectHasProperty(id, &m) { tokens.append(listen(id, m, handler)) }
        return tokens
    }

    private static func listen(_ obj: AudioObjectID, _ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) -> Token {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(obj, &a, DispatchQueue.main, block)
        return (obj, address, block)
    }

    static func remove(_ token: Token) {
        var a = token.1
        AudioObjectRemovePropertyListenerBlock(token.0, &a, DispatchQueue.main, token.2)
    }
}
