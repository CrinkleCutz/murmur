import CoreAudio
import Foundation

/// Other sound goes down while you dictate and comes back when you let go — what VoiceOS and Handy do, with nothing to
/// set: in headphones (AirPods, a headphone jack) it drops to a fifth, so you still hear it; on speakers it goes silent,
/// since the microphone would otherwise hear a video's voices and write them into your text.
///
/// The Mac's own output volume, through Core Audio — no permission, no private media controls (Apple has restricted
/// those since macOS 15.4, and a play/pause key press starts music when none was playing). Left alone when nothing is
/// playing, when the sound is already off, and when the device has no volume Murmur can set; afterwards the volume always
/// goes back to where it was. If Murmur quits mid-dictation, the next launch puts the volume back.
/// Settings ▸ Dictation ▸ "Turn other sound down" (`duckOtherAudio`).
final class AudioDuck {
    static let shared = AudioDuck()
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "duckOtherAudio") as? Bool ?? true }

    /// What headphones are lowered to, as a share of the volume they were at.
    static let headphoneShare: Float32 = 0.2

    private struct Saved: Codable, Equatable {
        var device: AudioDeviceID
        /// Element → the volume it had, and the volume Murmur set.
        var original: [UInt32: Float32]
        var set: [UInt32: Float32]
    }

    private let queue = DispatchQueue(label: "local.murmur.audio-duck", qos: .userInitiated)
    private var saved: Saved?
    private static let restoreKey = "duckRestore"

    // MARK: - Ducking

    func begin() {
        guard Self.isEnabled else { return }
        queue.async { self.duck() }
    }

    func end() {
        queue.async { self.restore() }
    }

    /// At launch: a dictation that never ended (Murmur quit while recording) left the volume down.
    func restoreAfterCrash() {
        queue.async {
            guard let data = UserDefaults.standard.data(forKey: Self.restoreKey),
                  let left = try? JSONDecoder().decode(Saved.self, from: data) else { return }
            self.saved = left
            self.restore()
        }
    }

    private func duck() {
        guard saved == nil, let device = Self.defaultOutputDevice() else { return }
        guard Self.isRunningSomewhere(device) else {
            dictationLog.info("duck: nothing is playing")
            return
        }
        if Self.isMuted(device) { return }
        let elements = Self.volumeElements(device)
        guard !elements.isEmpty else {
            dictationLog.info("duck: this output has no volume Murmur can set")
            return
        }
        var original: [UInt32: Float32] = [:]
        for element in elements { original[element] = Self.volume(device, element) ?? 0 }
        guard original.values.contains(where: { $0 > 0.01 }) else { return }
        let headphones = Self.isHeadphones(device)
        let share: Float32 = headphones ? Self.headphoneShare : 0
        let target = original.mapValues { $0 * share }
        let entry = Saved(device: device, original: original, set: target)
        saved = entry
        if let data = try? JSONEncoder().encode(entry) { UserDefaults.standard.set(data, forKey: Self.restoreKey) }
        ramp(device, from: original, to: target, steps: 5, over: 0.12)
        dictationLog.notice("duck: lowered other sound (\(headphones ? "headphones" : "speakers", privacy: .public))")
    }

    private func restore() {
        guard let entry = saved else { return }
        saved = nil
        UserDefaults.standard.removeObject(forKey: Self.restoreKey)
        // Always back to what it was. Telling "the user moved the volume" from "the device moved it" proved
        // unreliable (2026-10-14: AirPods switching into call mode moved Boom 3D's volume, Murmur took that for the
        // user, and the sound stayed down) — and sound that never comes back is far worse than overriding a volume
        // key pressed mid-dictation.
        for element in entry.original.keys {
            if let now = Self.volume(entry.device, element), abs(now - (entry.set[element] ?? now)) > 0.02 {
                dictationLog.notice("duck: the volume moved during the dictation; putting it back anyway")
                break
            }
        }
        var current: [UInt32: Float32] = [:]
        for element in entry.original.keys { current[element] = Self.volume(entry.device, element) ?? entry.set[element] ?? 0 }
        ramp(entry.device, from: current, to: entry.original, steps: 8, over: 0.25)
    }

    private func ramp(_ device: AudioDeviceID, from: [UInt32: Float32], to: [UInt32: Float32], steps: Int,
                      over seconds: Double) {
        for step in 1...steps {
            let t = Float32(step) / Float32(steps)
            for (element, start) in from {
                let end = to[element] ?? start
                Self.setVolume(device, element, start + (end - start) * t)
            }
            if step < steps { Thread.sleep(forTimeInterval: seconds / Double(steps)) }
        }
    }

    // MARK: - Core Audio

    private static func address(_ selector: AudioObjectPropertySelector, _ element: UInt32 = kAudioObjectPropertyElementMain,
                                scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var where_ = address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func uint32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> UInt32? {
        var where_ = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &where_),
              AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal) != 0
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool {
        uint32(device, kAudioDevicePropertyMute) == 1
    }

    /// Headphones: Bluetooth, or the headphone jack on the Mac's own output.
    static func isHeadphones(_ device: AudioDeviceID) -> Bool {
        let transport = uint32(device, kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal) ?? 0
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { return true }
        if transport == kAudioDeviceTransportTypeBuiltIn, let source = uint32(device, kAudioDevicePropertyDataSource) {
            return source == 0x6864_706E  // 'hdpn'
        }
        return false
    }

    /// The elements whose volume can be set: the main one, else each channel.
    private static func volumeElements(_ device: AudioDeviceID) -> [UInt32] {
        func settable(_ element: UInt32) -> Bool {
            var where_ = address(kAudioDevicePropertyVolumeScalar, element)
            var writable: DarwinBoolean = false
            return AudioObjectHasProperty(device, &where_)
                && AudioObjectIsPropertySettable(device, &where_, &writable) == noErr && writable.boolValue
        }
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return (1...8).map(UInt32.init).filter(settable)
    }

    private static func volume(_ device: AudioDeviceID, _ element: UInt32) -> Float32? {
        var where_ = address(kAudioDevicePropertyVolumeScalar, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setVolume(_ device: AudioDeviceID, _ element: UInt32, _ value: Float32) {
        var where_ = address(kAudioDevicePropertyVolumeScalar, element)
        var level = max(0, min(1, value))
        AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<Float32>.size), &level)
    }

    /// For the command line: what ducking would do on this Mac right now, without doing it.
    static func describe() -> String {
        guard let device = defaultOutputDevice() else { return "no output device" }
        let elements = volumeElements(device)
        let volumes = elements.map { "\($0): \(volume(device, $0).map { String(format: "%.2f", $0) } ?? "-")" }
        return "output device \(device): playing \(isRunningSomewhere(device)), muted \(isMuted(device)), "
            + "headphones \(isHeadphones(device)), settable volume elements \(volumes.isEmpty ? "none" : volumes.joined(separator: ", "))"
    }
}
