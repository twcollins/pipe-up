import AppKit
import CoreAudio

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

    // MARK: Diagnostics info

    static func transportName(_ id: AudioDeviceID) -> String {
        var a = addr(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &t) == noErr else { return "Unknown" }
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "Display"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: return "iPhone (Continuity)"
        default: return "Other"
        }
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        var a = addr(kAudioDevicePropertyNominalSampleRate)
        var v: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    /// Names of apps currently recording from any input (macOS 14+), excluding us.
    static func appsUsingMic() -> [String]? {
        guard #available(macOS 14.0, *) else { return nil }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for p in ids {
            var ra = addr(kAudioProcessPropertyIsRunningInput)
            var running: UInt32 = 0
            var rs = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(p, &ra, 0, nil, &rs, &running) == noErr, running != 0 else { continue }
            var pa = addr(kAudioProcessPropertyPID)
            var pid: pid_t = 0
            var ps = UInt32(MemoryLayout<pid_t>.size)
            AudioObjectGetPropertyData(p, &pa, 0, nil, &ps, &pid)
            if pid == me { continue }
            var name = NSRunningApplication(processIdentifier: pid)?.localizedName
            if name == nil {
                var ba = addr(kAudioProcessPropertyBundleID)
                var bid: Unmanaged<CFString>?
                var bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                if AudioObjectGetPropertyData(p, &ba, 0, nil, &bs, &bid) == noErr, let b = bid?.takeRetainedValue() {
                    name = b as String
                }
            }
            names.append(name ?? "pid \(pid)")
        }
        return Array(Set(names)).sorted()
    }

    static func listenSampleRate(_ id: AudioDeviceID, _ handler: @escaping () -> Void) -> Token {
        listen(id, addr(kAudioDevicePropertyNominalSampleRate), handler)
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
