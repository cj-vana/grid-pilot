import Foundation
import CoreAudio
import AudioToolbox

/// Splits a 0...1 value into `zones` equal buckets. Callers keep the last
/// index and only act when it changes.
func zoneIndex(value: Float, zones: Int) -> Int {
    guard zones > 0 else { return 0 }
    let clamped = min(max(value, 0), 1)
    return min(Int(clamped * Float(zones)), zones - 1)
}

enum Audio {
    static func setOutputVolume(_ value: Float) {
        guard let device = defaultDevice(input: false) else { return }
        setVolume(device: device, scope: kAudioDevicePropertyScopeOutput, value: value)
    }

    static func setInputVolume(_ value: Float) {
        guard let device = defaultDevice(input: true) else { return }
        setVolume(device: device, scope: kAudioDevicePropertyScopeInput, value: value)
    }

    /// Current output volume, for save/restore around call-mode silencing.
    static func getOutputVolume() -> Float {
        guard let device = defaultDevice(input: false) else { return 0.5 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 0.5
        var size = UInt32(MemoryLayout<Float>.size)
        if AudioObjectHasProperty(device, &address),
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
            return volume
        }
        return 0.5
    }

    static func outputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = deviceName(id) else { return nil }
            return (id, name)
        }.sorted { $0.name < $1.name }
    }

    static func setDefaultOutput(_ id: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        )
        if status != noErr {
            Log.error("setDefaultOutput failed: \(status)")
        }
    }

    private static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func setVolume(device: AudioDeviceID, scope: AudioObjectPropertyScope, value: Float) {
        var volume = min(max(value, 0), 1)
        // Main element first; fall back to per-channel for devices that only
        // expose channel 1/2 volumes (common on USB interfaces).
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: element
            )
            guard AudioObjectHasProperty(device, &address) else { continue }
            let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &volume)
            if status != noErr {
                Log.error("setVolume element \(element) failed: \(status)")
            }
            if element == kAudioObjectPropertyElementMain { return }
        }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        return status == noErr ? name?.takeRetainedValue() as String? : nil
    }
}
