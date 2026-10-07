#if targetEnvironment(macCatalyst)
import AVFoundation
import CoreAudio
import Foundation

/// Catalyst-only CoreAudio shim for picking the Mac's audio input.
///
/// Why not `AVAudioSession.availableInputs`: on Mac Catalyst that
/// enumeration only returns capture devices AVFoundation can route
/// to natively — in practice built-in mic plus whatever Bluetooth
/// profile is active — and skips most USB mics, aggregates, and
/// virtual devices the user can see in **System Settings → Sound**.
/// CoreAudio shows everything, which is what the picker UI expects.
///
/// Why we swap the **system default input** instead of binding
/// Relay's engine to a specific device: `AVAudioEngine` with voice
/// processing enabled replaces `inputNode.audioUnit` with an
/// AUVoiceProcessor that builds an internal aggregate (mic + system
/// output as the AEC reference). Setting
/// `kAudioOutputUnitProperty_CurrentDevice` on that unit forces our
/// device into both halves of the aggregate, which fails for any
/// input-only device (initialize err=-10875). Swapping the system
/// default avoids that path entirely at the cost of other apps
/// following along — matches the Mac convention anyway.
enum MacAudioDevices {
    struct Device: Hashable, Identifiable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    /// All input-capable audio devices visible to CoreAudio.
    static func inputs() -> [Device] {
        let ids = _allDeviceIDs()
        return ids.compactMap { id in
            guard _hasInputStreams(id) else { return nil }
            guard let name = _stringProperty(id, kAudioObjectPropertyName) else { return nil }
            let uid = _stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "\(id)"
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// The CoreAudio device id currently acting as the system default input.
    static func systemDefaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &id,
        )
        return status == noErr ? id : nil
    }

    // MARK: - User-selected input (via system default swap)

    /// Set the system default input device. Other apps will follow.
    /// Returns true on success.
    @discardableResult
    static func setSystemDefaultInput(_ device: Device) -> Bool {
        var id = device.id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id,
        )
        if status != noErr {
            print("[MacAudio] setSystemDefaultInput failed: \(status)")
        }
        return status == noErr
    }

    // MARK: - CoreAudio helpers

    private static func _allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size,
        )
        guard status == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &ids,
        )
        return status == noErr ? ids : []
    }

    /// A device has an input stream iff its input-scoped stream
    /// configuration describes one or more channels on at least one
    /// buffer. Output-only devices (speakers, HDMI) return zero.
    private static func _hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment,
        )
        defer { buffer.deallocate() }
        status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer)
        guard status == noErr else { return false }
        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        let bufferCount = Int(list.pointee.mNumberBuffers)
        guard bufferCount > 0 else { return false }
        let buffers = UnsafeBufferPointer(
            start: &list.pointee.mBuffers, count: bufferCount,
        )
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func _stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let s = cfString else { return nil }
        return s as String
    }
}
#endif
