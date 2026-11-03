import AVFoundation
#if os(macOS)
import CoreAudio
#endif
import Foundation
import Observation

/// Settings › Playback › Per-output profiles (28 Oct; on by default): the equalizer, the headphone correction and
/// crossfeed are kept per output device, so AirPods keep their correction and the Mac's speakers theirs, and switching
/// puts the right ones in place. macOS says when the default output changes (a property listener: nothing is polled).
/// An output met for the first time starts from the settings as they are. The rest (levelling, the limiter, gapless,
/// crossfade, vocal clarity) is about the music, not the speaker, and stays one for all.
@MainActor
@Observable
final class SoundProfiles {
    static let shared = SoundProfiles()

    struct Output: Equatable { let id: String; let name: String }

    /// The settings that belong to an output: their UserDefaults keys, as Equalizer, HeadphoneCorrection and
    /// SoundChain store them.
    nonisolated static let keys = ["eqOn", "eqGains", "eqPreset", "headphoneCorrection", "crossfeed"] + StudioSettings.keys

    private(set) var output: Output?
    private(set) var on: Bool
    /// Self-tests: the system's own output is not followed, so a test's made-up ones are not undone.
    @ObservationIgnored var followsSystem = true

    private init() {
        let defaults = UserDefaults.standard
        on = defaults.object(forKey: "soundPerOutput") as? Bool ?? true
        // the output the settings in place belong to: it may have changed while the app was closed
        if let id = defaults.string(forKey: "soundOutputID") {
            output = Output(id: id, name: defaults.string(forKey: "soundOutputName") ?? "")
        }
        if let now = Self.systemOutput() { switched(to: now) }
        #if os(macOS)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { @Sendable _, _ in
            MainActor.assumeIsolated { SoundProfiles.shared.systemChanged() }
        }
        #else
        // the iPhone: the audio route changed (AirPods connected, a cable out, the speaker)
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SoundProfiles.shared.systemChanged() }
        }
        #endif
    }

    private func systemChanged() {
        guard followsSystem, let now = Self.systemOutput() else { return }
        switched(to: now)
    }

    func setOn(_ value: Bool) {
        guard value != on else { return }
        on = value
        UserDefaults.standard.set(value, forKey: "soundPerOutput")
        if value, let output { save(for: output) }      // from now, this output keeps what is set
    }

    /// The default output is now `new`: what was set is kept for the last one, and the new one's put in place.
    func switched(to new: Output) {
        guard new.id != output?.id else { return }
        let old = output
        output = new
        UserDefaults.standard.set(new.id, forKey: "soundOutputID")
        UserDefaults.standard.set(new.name, forKey: "soundOutputName")
        guard on else { return }
        if let old { save(for: old) }
        if let saved = profiles[new.id] {
            let defaults = UserDefaults.standard
            for key in Self.keys {
                if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            Equalizer.shared.reload()
            HeadphoneCorrection.shared.reload()
            SoundChain.shared.settingChanged()
        } else {
            save(for: new)                               // first time: as things are now
        }
    }

    /// Each output's settings, by its id: the values of `keys` as they were last set on it.
    private var profiles: [String: [String: Any]] {
        (UserDefaults.standard.dictionary(forKey: "soundProfiles") as? [String: [String: Any]]) ?? [:]
    }

    private func save(for output: Output) {
        let defaults = UserDefaults.standard
        var all = profiles
        var values: [String: Any] = [:]
        for key in Self.keys { if let value = defaults.object(forKey: key) { values[key] = value } }
        values["name"] = output.name
        all[output.id] = values
        defaults.set(all, forKey: "soundProfiles")
    }

    #if os(iOS)
    /// The audio route's output: its port's id (an AirPods pair keeps its own) and name.
    nonisolated static func systemOutput() -> Output? {
        guard let port = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return nil }
        return Output(id: port.uid, name: port.portName)
    }
    #else
    /// The default output device's unique id and name, from Core Audio.
    nonisolated static func systemOutput() -> Output? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        func text(_ selector: AudioObjectPropertySelector) -> String? {
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
            return value.takeRetainedValue() as String
        }
        guard let id = text(kAudioDevicePropertyDeviceUID) else { return nil }
        return Output(id: id, name: text(kAudioObjectPropertyName) ?? "This output")
    }
    #endif
}
