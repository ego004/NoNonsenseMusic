import Foundation

/// Settings › Playback › Studio: four processors a mastering engineer reaches for, each 0 to 1, in one stereo stage.
///  - Sub rumble: a sub-harmonic synthesizer (as in the dbx LoAir). The bass band (40 to 110 Hz) is divided by two by a
///    flip-flop that toggles at each rising zero crossing, so every kick and bass note gets a true octave below it,
///    30 to 55 Hz, smoothed to a near sine and scaled by the note's own level: it follows the music, and is silent
///    when there is no bass. Real low end the song did not have, which no equalizer can add.
///  - Clarity: a dynamic cut of the mud (200 to 500 Hz), only while the bass is hitting. Loud bass masks the notes just
///    above it, so the bass can be big without smothering guitars, keys and voices; with no bass, nothing changes.
///  - Air: an exciter. The 2.5 to 6.5 kHz band, shaped so loud notes add more, makes harmonics above 7 kHz: the detail
///    and attack that let each instrument be heard on its own.
///  - Width: mid/side. The side (what differs between the channels) is high-passed at 150 Hz and raised up to 3.5 dB:
///    off-centre instruments move apart, and the bass and kick stay mono in the middle, tighter and harder-hitting. A
///    mono song is not changed.
/// Stereo only. Filters are Audio EQ Cookbook biquads in transposed direct form II.
nonisolated struct StudioSettings: Equatable, Sendable {
    var width = 0.0, rumble = 0.0, clarity = 0.0, air = 0.0
    static let off = StudioSettings()
    static let keys = ["studioWidth", "studioRumble", "studioClarity", "studioAir"]

    var isOn: Bool { width > 0 || rumble > 0 || clarity > 0 || air > 0 }
    /// The side's gain above 150 Hz: 1 to 1.5.
    var sideGain: Double { 1 + 0.5 * min(max(width, 0), 1) }

    /// How far the output can exceed the input, in dB (the equalizer's preamp makes room for it when the limiter is off):
    /// the side's gain with a high-pass's overshoot, and the sub and the air added on top.
    var headroom: Double { isOn ? 20 * log10(sideGain * 1.3) + 3 * rumble + 1 * air : 0 }

    static func stored() -> StudioSettings {
        let d = UserDefaults.standard
        func value(_ key: String) -> Double { min(max(d.double(forKey: key), 0), 1) }
        return StudioSettings(width: value("studioWidth"), rumble: value("studioRumble"),
                              clarity: value("studioClarity"), air: value("studioAir"))
    }
}

nonisolated struct Biquad {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    private init(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) {
        self.b0 = Float(b0 / a0); self.b1 = Float(b1 / a0); self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0); self.a2 = Float(a2 / a0)
    }

    @inline(__always) mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    private static func parts(_ f: Double, _ q: Double, _ rate: Double) -> (c: Double, alpha: Double) {
        let w0 = 2 * Double.pi * min(f, rate * 0.45) / rate
        return (cos(w0), sin(w0) / (2 * q))
    }
    static func lowPass(_ f: Double, q: Double = 0.7071, rate: Double) -> Biquad {
        let (c, al) = parts(f, q, rate)
        return Biquad((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al)
    }
    static func highPass(_ f: Double, q: Double = 0.7071, rate: Double) -> Biquad {
        let (c, al) = parts(f, q, rate)
        return Biquad((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al)
    }
    /// Constant 0 dB peak: the band's own level comes out at the centre.
    static func bandPass(_ f: Double, q: Double, rate: Double) -> Biquad {
        let (c, al) = parts(f, q, rate)
        return Biquad(al, 0, -al, 1 + al, -2 * c, 1 - al)
    }
}

nonisolated final class StudioChain {
    let settings: StudioSettings
    private let rate: Double

    // width
    private var sideHigh: Biquad
    private let sideGain: Float
    // sub rumble
    private var subLow: Biquad, subHigh: Biquad, smooth1: Biquad, smooth2: Biquad
    private var subEnv: Float = 0, flip = false, positive = false
    private let rumbleGain: Float, envUp: Float, envDown: Float
    // clarity
    private var bassSide: Biquad, mudLeft: Biquad, mudRight: Biquad
    private var bassEnv: Float = 0, duck: Float = 1, duckTarget: Float = 1, sinceLog = 0
    private let maxDuckDB: Float, bassUp: Float, bassDown: Float, duckSlew: Float
    // air
    private var airBand: Biquad, airHigh: Biquad
    private let airGain: Float

    init(_ settings: StudioSettings, sampleRate rate: Double) {
        self.settings = settings
        self.rate = rate
        sideHigh = .highPass(150, rate: rate)
        sideGain = Float(settings.sideGain)
        subLow = .lowPass(110, rate: rate); subHigh = .highPass(40, rate: rate)
        smooth1 = .lowPass(60, rate: rate); smooth2 = .lowPass(60, rate: rate)
        rumbleGain = Float(0.7 * settings.rumble)
        func coefficient(_ seconds: Double) -> Float { Float(1 - exp(-1 / (seconds * rate))) }
        envUp = coefficient(0.004); envDown = coefficient(0.06)
        bassSide = .lowPass(120, rate: rate)
        mudLeft = .bandPass(320, q: 0.8, rate: rate); mudRight = .bandPass(320, q: 0.8, rate: rate)
        maxDuckDB = Float(5 * settings.clarity)
        bassUp = coefficient(0.01); bassDown = coefficient(0.15); duckSlew = coefficient(0.004)
        airBand = .bandPass(4000, q: 0.6, rate: rate); airHigh = .highPass(7000, rate: rate)
        airGain = Float(2.5 * settings.air)
    }

    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        let s = settings
        for i in 0..<frames {
            let l = left[i], r = right[i]
            let mid = (l + r) * 0.5, side = (l - r) * 0.5
            var m = mid
            if s.rumble > 0 { m += rumble(mid) }
            if s.air > 0 { m += air(mid) }
            let wide = s.width > 0 ? sideHigh.process(side) * sideGain : side
            var outL = m + wide, outR = m - wide
            if s.clarity > 0 {
                let g = clarity(bass: mid)
                let amount = 1 - g
                outL -= amount * mudLeft.process(outL)
                outR -= amount * mudRight.process(outR)
            }
            left[i] = outL; right[i] = outR
        }
    }

    /// The octave below the bass band, following its level.
    @inline(__always) private func rumble(_ mid: Float) -> Float {
        let x = subHigh.process(subLow.process(mid))
        let a = abs(x)
        subEnv += (a > subEnv ? envUp : envDown) * (a - subEnv)
        let threshold = max(subEnv * 0.2, 1e-4)
        if x > threshold {
            if !positive { positive = true; flip.toggle() }
        } else if x < -threshold {
            positive = false
        }
        let square: Float = flip ? 1 : -1
        return smooth2.process(smooth1.process(square)) * subEnv * rumbleGain
    }

    /// Harmonics of the upper-mid band above 7 kHz, more from louder notes (x·|x| is odd, so its harmonics are the odd ones).
    /// What grows with the square of the level is held under a soft ceiling of 0.06 (-24 dBFS): a loud cymbal adds detail,
    /// not harshness.
    @inline(__always) private func air(_ mid: Float) -> Float {
        let x = airBand.process(mid)
        let harmonics = airHigh.process(x * abs(x) * 4) * airGain
        return 0.06 * tanhf(harmonics / 0.06)
    }

    /// The gain left on the mud band (1: none taken): down by up to `maxDuckDB` when the bass is louder than -30 dBFS.
    @inline(__always) private func clarity(bass mid: Float) -> Float {
        let a = abs(bassSide.process(mid))
        bassEnv += (a > bassEnv ? bassUp : bassDown) * (a - bassEnv)
        sinceLog += 1
        if sinceLog >= 32 {
            sinceLog = 0
            let db = 20 * log10(bassEnv + 1e-9)
            let over = min(max((db + 30) / 18, 0), 1)                 // 0 at -30 dBFS, 1 at -12 dBFS and louder
            duckTarget = powf(10, -maxDuckDB * over / 20)
        }
        duck += duckSlew * (duckTarget - duck)
        return duck
    }
}
