import Foundation
import Observation

/// Settings › Playback › Equalizer (#37): 14 bands, off by default. On, every song's audio passes through the sound
/// chain's tap (SoundChain): one peaking filter per band that is not at 0 dB, in Accelerate's biquad cascade, then a
/// preamp that lowers the whole curve by its own peak, so a boost never clips. Off, it adds nothing to the chain. Stored
/// as the Windows and Android apps will store it: on or off, and 14 gains in dB.
@MainActor
@Observable
final class Equalizer {
    static let shared = Equalizer()

    /// The bands' centres, in Hz: two-thirds of an octave apart, from the lowest bass to the top of what most people hear.
    nonisolated static let bands: [Double] = [31, 50, 80, 125, 200, 315, 500, 800, 1250, 2000, 3150, 5000, 8000, 12500]
    nonisolated static let range = -12.0 ... 12.0

    enum Preset: String, CaseIterable, Identifiable {
        case flat, bassBoost, deepBass, vocal, treble, custom
        var id: String { rawValue }
        var name: String {
            switch self { case .flat: "Flat"; case .bassBoost: "Bass Boost"; case .deepBass: "Deep Bass"; case .vocal: "Vocal"; case .treble: "Treble"; case .custom: "Custom" }
        }
        /// The gains, band by band; Custom has none of its own (it is whatever you set).
        var gains: [Double]? {
            switch self {
            case .flat: Array(repeating: 0, count: 14)
            case .bassBoost: [6, 6, 5, 4, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0]
            // Thumping, rumbling bass (the lift peaks near 60 to 80 Hz) with a small dip around 300 Hz for separation and
            // a touch of lift at 1 to 3 kHz for vocals. A 12-band parametric curve ("Deep Bass Clarity Recommended")
            // fitted to these 14 bands by least squares against the filters' real responses: within 0.8 dB above it
            // anywhere from 30 Hz to 12 kHz, 0.8 dB RMS. With the limiter on (its default) a boost keeps its volume.
            case .deepBass: [4, 7.5, 8.5, 6, 1.5, -1.5, -0.5, 0.5, 0.5, 0.5, 0.5, -0.5, -1, -1]
            case .vocal: [-2, -2, -1, 0, -1, 0, 1, 2, 3, 3.5, 3, 1.5, 0, 0]
            case .treble: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0.5, 1.5, 3, 4.5, 5.5]
            case .custom: nil
            }
        }
    }

    private(set) var on: Bool
    private(set) var gains: [Double]
    private(set) var preset: Preset

    /// SoundChain: on or off, the playing song's tap is attached or taken away.
    @ObservationIgnored var changed: (() -> Void)?

    private init() {
        (on, gains, preset) = Self.stored()
    }

    private static func stored() -> (Bool, [Double], Preset) {
        let defaults = UserDefaults.standard
        let saved = (defaults.array(forKey: "eqGains") as? [Double]) ?? []
        let gains = saved.count == bands.count ? saved.map { min(max($0, range.lowerBound), range.upperBound) }
                                               : Array(repeating: 0, count: bands.count)
        return (defaults.bool(forKey: "eqOn"), gains, Preset(rawValue: defaults.string(forKey: "eqPreset") ?? "") ?? .flat)
    }

    /// SoundProfiles: another output's settings were put in place; the taps follow (SoundChain.settingChanged).
    func reload() {
        (on, gains, preset) = Self.stored()
    }

    func setOn(_ value: Bool) {
        guard value != on else { return }
        on = value
        UserDefaults.standard.set(value, forKey: "eqOn")
        changed?()
    }

    func choose(_ chosen: Preset) {
        preset = chosen
        UserDefaults.standard.set(chosen.rawValue, forKey: "eqPreset")
        if let values = chosen.gains { store(values) }
    }

    /// One band moved: the curve is yours now (Custom).
    func set(band: Int, to gain: Double) {
        guard Self.bands.indices.contains(band) else { return }
        var values = gains
        values[band] = (min(max(gain, Self.range.lowerBound), Self.range.upperBound) * 2).rounded() / 2   // 0.5 dB steps
        guard values != gains else { return }
        if preset != .custom { preset = .custom; UserDefaults.standard.set(Preset.custom.rawValue, forKey: "eqPreset") }
        store(values)
    }

    private func store(_ values: [Double]) {
        gains = values
        UserDefaults.standard.set(values, forKey: "eqGains")
        SoundChain.shared.equalizerChanged(values)
    }
}
