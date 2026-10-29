import Accelerate
import AVFoundation
import MediaToolbox
import os

/// What happens to a song's audio between its file and the speakers: one audio processing tap per AVPlayerItem, which
/// runs your headphones' correction (HeadphoneCorrection) and the equalizer's filters (Equalizer), then one gain: the equalizer's preamp times the song's levelling gain
/// (Leveller), then vocal clarity (VocalClarity), crossfeed for headphones (Crossfeed) and the limiter (PeakLimiter, in place of the preamp), when on.
/// Attached only while one of them is on; with all off a song has no tap and costs nothing.
@MainActor
final class SoundChain {
    static let shared = SoundChain()

    /// Player: the playing song's tap is attached again (or taken away) after a switch.
    var changed: (() -> Void)?
    /// The taps of the songs loaded now, with their copies' keys.
    private var processors: [(key: String, item: ObjectIdentifier, processor: Weak)] = []
    private struct Weak { weak var processor: SoundProcessor? }

    private init() {
        UserDefaults.standard.set(false, forKey: "bypassEffects")      // a comparison never survives a launch
        Equalizer.shared.changed = { [weak self] in self?.changed?() }
        Leveller.shared.changed = { [weak self] in self?.changed?() }
        Leveller.shared.measured = { [weak self] key in self?.measured(key) }
    }

    /// Whether songs get a tap. Not for the limiter alone: with nothing else on there is no gain to limit, and a song with
    /// a tap changes over to the next with a gap of about 0.1 s (measured 29 Oct: 109 ms against 2 ms), as the player
    /// starts its audio pipeline only when the song starts.
    var active: Bool {
        Self.bassHarmonics > 0 || Self.vocalClarity > 0 || Self.loudnessCompensation || Equalizer.shared.on || Leveller.shared.on || Self.crossfeeding || HeadphoneCorrection.shared.model != nil
            || Player.crossfade > 0                       // its fades are shaped in the taps
    }

    /// Settings › Playback › Bypass effects (29 Oct): an A/B comparison. Everything that colours the sound is off (equalizer,
    /// headphone correction, crossfeed, vocal presence, psychoacoustic bass, loudness compensation); normalization and
    /// the limiter stay on, so the songs keep their level and only the colour changes. Not kept across launches.
    static var bypassing: Bool { UserDefaults.standard.bool(forKey: "bypassEffects") }

    /// Bypass switched: the playing song's tap is made again.
    func bypassChanged() { changed?() }

    /// Target level changed: every tap glides to its song's new gain.
    func levelChanged() {
        guard Leveller.shared.on else { return }
        for entry in processors { entry.processor.processor?.update(level: Leveller.shared.gain(for: entry.key)) }
    }

    /// Settings › Playback › Crossfeed (off by default).
    static var crossfeeding: Bool { UserDefaults.standard.bool(forKey: "crossfeed") }

    /// Settings › Playback › Loudness compensation (28 Oct; off by default): as the volume goes down, ears lose bass and
    /// treble sooner than the middle (ISO 226's equal-loudness contours), so quiet music sounds thin. Two shelves, at
    /// 105 Hz and 8 kHz, rise as the volume falls: a third of the volume's cut for the bass (at most 10 dB), an eighth
    /// for the treble (at most 4 dB). An approximation of the contours' gaps, not a fit to them.
    static var loudnessCompensation: Bool { UserDefaults.standard.bool(forKey: "loudnessCompensation") }

    /// The volume control's place, 0 to 1 (the Mac's slider, the iPhone's system volume); its cut is the cube's.
    private(set) var listeningPlace: Double = 1

    nonisolated static func loudnessShelves(place: Double) -> [CorrectionFilter] {
        let cut = -60 * log10(max(place, 0.01))                        // dB the volume takes off (gain = place³)
        let bass = min(cut / 3, 10), treble = min(cut / 8, 4)
        guard bass >= 0.5 else { return [] }
        return [CorrectionFilter(kind: .lowShelf, frequency: 105, gain: bass, q: 0.7),
                CorrectionFilter(kind: .highShelf, frequency: 8000, gain: treble, q: 0.7)]
    }

    private var shelvesNow: [CorrectionFilter] { Self.loudnessCompensation && !Self.bypassing ? Self.loudnessShelves(place: listeningPlace) : [] }

    /// The volume moved: every tap's shelves follow (only when they change by half a dB or more).
    func volumeChanged(place: Double) {
        let before = shelvesNow
        listeningPlace = min(max(place, 0), 1)
        let after = shelvesNow
        guard abs((before.first?.gain ?? 0) - (after.first?.gain ?? 0)) >= 0.5 || before.isEmpty != after.isEmpty else { return }
        for entry in processors { entry.processor.processor?.update(loudness: after) }
    }

    /// Loudness compensation switched: every tap follows.
    func loudnessChanged() {
        if Self.loudnessCompensation && !active { changed?() }
        let shelves = shelvesNow
        for entry in processors { entry.processor.processor?.update(loudness: shelves) }
        changed?()
    }

    /// Settings › Playback › Psychoacoustic bass: 0 (off) to 1.
    static var bassHarmonics: Double { min(max(UserDefaults.standard.double(forKey: "bassHarmonics"), 0), 1) }

    /// Its slider moved: every tap follows at once.
    func bassHarmonicsChanged() {
        guard !Self.bypassing else { return }
        for entry in processors { entry.processor.processor?.update(bass: Self.bassHarmonics) }
    }

    /// Settings › Playback › Vocal presence: the mid's boost, 0 (off) to 6 dB.
    static var vocalClarity: Double { min(max(UserDefaults.standard.double(forKey: "vocalClarity"), 0), 6) }

    /// Its slider moved: every tap follows at once, without being made again.
    func vocalClarityChanged() {
        guard !Self.bypassing else { return }
        for entry in processors { entry.processor.processor?.update(vocal: Self.vocalClarity) }
    }

    /// Crossfeed or the headphone correction changed: the playing song's tap is made again.
    func settingChanged() { changed?() }

    /// The tap for `item`, the copy `key`, when either is on (none when both are off): attached once its audio track is
    /// known. A copy playing from a file not measured yet is measured now. `fadeIn`: it starts silent and fades in over
    /// that many seconds (a crossfade).
    func apply(to item: AVPlayerItem, key: String, fadeIn: Double? = nil) {
        guard active else { item.audioMix = nil; return }
        let leveller = Leveller.shared
        if leveller.on, let url = (item.asset as? AVURLAsset)?.url, url.isFileURL { leveller.measure(key, file: url) }
        let processor = makeProcessor(key: key, bypassing: Self.bypassing)
        if let fadeIn { processor.fade(in: true, over: fadeIn) }
        processors.removeAll { $0.processor.processor == nil }
        processors.append((key, ObjectIdentifier(item), Weak(processor: processor)))
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first, active,
                  let tap = processor.makeTap() else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    /// The processor for a copy, from the settings as they are. `bypassing`: only the level and the limiter (see `bypassing`).
    func makeProcessor(key: String, bypassing: Bool) -> SoundProcessor {
        let eq = Equalizer.shared, leveller = Leveller.shared
        let processor = SoundProcessor(gains: eq.on && !bypassing ? eq.gains : Self.flat, level: leveller.on ? leveller.gain(for: key) : 0,
                                       limiting: leveller.limiting, crossfeeding: Self.crossfeeding && !bypassing,
                                       correction: bypassing ? [] : HeadphoneCorrection.shared.filters,
                                       vocal: bypassing ? 0 : Self.vocalClarity)
        processor.update(bass: bypassing ? 0 : Self.bassHarmonics)
        if Self.loudnessCompensation && !bypassing { processor.update(loudness: shelvesNow) }
        return processor
    }

    #if DEBUG
    /// Self-tests: each tap's key and times (see SoundProcessor.timingsForTests).
    var timingsForTests: [(key: String, prepared: Double, first: Double, last: Double)] {
        processors.compactMap { entry in entry.processor.processor.map { (entry.key, $0.timingsForTests.prepared, $0.timingsForTests.first, $0.timingsForTests.last) } }
    }
    #endif

    private static let flat = Array(repeating: 0.0, count: Equalizer.bands.count)

    /// A crossfade: the song going out fades to silence over `seconds`.
    func fade(_ item: AVPlayerItem, outOver seconds: Double) {
        let id = ObjectIdentifier(item)
        for entry in processors where entry.item == id { entry.processor.processor?.fade(in: false, over: seconds) }
    }

    /// Equalizer: a band or preset changed; every tap follows.
    func equalizerChanged(_ gains: [Double]) {
        guard Equalizer.shared.on, !Self.bypassing else { return }     // off, its taps (levelling's) stay flat
        for entry in processors { entry.processor.processor?.update(gains: gains) }
    }

    /// Leveller: a copy was measured (its name in the cache); its taps glide to its own gain.
    private func measured(_ name: String) {
        guard Leveller.shared.on else { return }
        for entry in processors where AudioCache.name(for: entry.key) == name {
            entry.processor.processor?.update(level: Leveller.shared.gain(for: entry.key))
        }
    }

    #if DEBUG
    /// Self-tests: the taps alive now.
    var liveProcessors: [SoundProcessor] { processors.compactMap(\.processor.processor) }
    #endif
}

/// The filters and gain of one item's tap. `update` (the main thread) builds a new cascade and swaps it in under the
/// lock; `process` (the audio thread) holds the lock for one buffer, so a cascade is never freed while in use.
nonisolated final class SoundProcessor: @unchecked Sendable {
    /// Each band's width: two-thirds of an octave (Q = √2^N / (2^N − 1), N = 2/3).
    static let q = sqrt(pow(2, 2.0 / 3)) / (pow(2, 2.0 / 3) - 1)
    /// How fast the gain moves to a new value: each 0.15 s closes all but 1/e of the gap, so any change settles in about
    /// 0.7 s and a song measured after it started glides to its level instead of jumping. (A fixed step per second,
    /// tried first, took 0.5 s to turn a song down 6 dB but 3 s to turn one up 23 dB.)
    static let glideSeconds = 0.15

    private let lock = OSAllocatedUnfairLock()
    private var gains: [Double]
    private var level: Float                       // the levelling gain, linear
    private let limiting: Bool                     // the limiter instead of the equalizer's preamp
    private var limiter: PeakLimiter?
    private let crossfeeding: Bool
    private var crossfeed: Crossfeed?
    private var bassAmount: Float = 0              // bass harmonics, 0 to 1 (BassHarmonics)
    private var bass: BassHarmonics?               // made when the format is known
    private var vocalGain: Double                  // vocal clarity's boost, dB; 0: none
    private var vocal: VocalClarity?
    private let correction: [CorrectionFilter]     // headphone correction, before the equalizer's bands
    private var loudness: [CorrectionFilter] = []  // loudness compensation's shelves (SoundChain.loudnessShelves)
    /// A crossfade's fade: in (from silence) or out (to silence), its length, and how far along it is, in frames.
    private var fading: (incoming: Bool, seconds: Double, done: Int)?
    private var silenced = false                   // a fade out is over: silence from here
    private var applied: Float?                    // the gain applied to the last buffer; nil before the first
    private var sampleRate = 44_100.0
    private var channels = 0
    private var usable = false                     // Float32, one buffer per channel: what AVFoundation's taps give
    private var cascade: Cascade?

    /// `level`: the levelling gain in dB. `limiting`: a limiter last, and no preamp (a boost keeps its volume).
    init(gains: [Double], level: Double = 0, limiting: Bool = false, crossfeeding: Bool = false,
         correction: [CorrectionFilter] = [], vocal: Double = 0) {
        self.gains = gains
        self.vocalGain = vocal
        self.correction = correction
        self.level = Float(pow(10, level / 20))
        self.limiting = limiting
        self.crossfeeding = crossfeeding
    }

    /// The filters of one sample rate: the biquad setup, each channel's delay line, and the preamp.
    final class Cascade {
        let setup: vDSP_biquad_Setup
        let sections: Int
        let delays: [UnsafeMutablePointer<Float>]
        var preamp: Float
        init?(coefficients: [Double], sections: Int, channels: Int, preamp: Float) {
            guard sections > 0, let setup = vDSP_biquad_CreateSetup(coefficients, vDSP_Length(sections)) else { return nil }
            self.setup = setup
            self.sections = sections
            self.preamp = preamp
            delays = (0..<channels).map { _ in
                let line = UnsafeMutablePointer<Float>.allocate(capacity: 2 * sections + 2)
                line.initialize(repeating: 0, count: 2 * sections + 2)
                return line
            }
        }
        deinit {
            vDSP_biquad_DestroySetup(setup)
            delays.forEach { $0.deallocate() }
        }
    }

    /// Peaking filters (Robert Bristow-Johnson's Audio EQ Cookbook), normalised by a0, as vDSP takes them: b0, b1, b2,
    /// a1, a2 per band, for each band not at 0 dB and below the Nyquist frequency.
    static func coefficients(gains: [Double], sampleRate: Double) -> [Double] {
        var out: [Double] = []
        for (centre, gain) in zip(Equalizer.bands, gains) where abs(gain) >= 0.05 && centre < sampleRate / 2 * 0.95 {
            let a = pow(10, gain / 40), w = 2 * .pi * centre / sampleRate, alpha = sin(w) / (2 * q), c = cos(w)
            let a0 = 1 + alpha / a
            out += [(1 + alpha * a) / a0, -2 * c / a0, (1 - alpha * a) / a0, -2 * c / a0, (1 - alpha / a) / a0]
        }
        return out
    }

    /// The cascade's loudest point, in dB (0 for a curve with no boost), read at 240 frequencies from 20 Hz to 20 kHz:
    /// bands next to each other add up, so the peak can be above the highest band's own gain.
    static func peak(coefficients: [Double], sampleRate: Double) -> Double {
        var loudest = 0.0
        for i in 0..<240 {
            let f = 20 * pow(1000, Double(i) / 239), w = 2 * .pi * min(f, sampleRate / 2) / sampleRate
            var magnitude = 1.0
            for s in stride(from: 0, to: coefficients.count, by: 5) {
                let (b0, b1, b2, a1, a2) = (coefficients[s], coefficients[s + 1], coefficients[s + 2], coefficients[s + 3], coefficients[s + 4])
                func size(_ k0: Double, _ k1: Double, _ k2: Double) -> Double {
                    let re = k0 + k1 * cos(w) + k2 * cos(2 * w), im = -(k1 * sin(w) + k2 * sin(2 * w))
                    return (re * re + im * im).squareRoot()
                }
                magnitude *= size(b0, b1, b2) / size(1, a1, a2)
            }
            loudest = max(loudest, 20 * log10(magnitude))
        }
        return loudest
    }

    func update(gains: [Double]) {
        let (rate, count) = lock.withLockUnchecked { () -> (Double, Int) in
            self.gains = gains
            return (sampleRate, channels)
        }
        let (boost, shelves) = lock.withLockUnchecked { (vocalGain, loudness) }
        install(Self.build(gains: gains, correction: correction, loudness: shelves, sampleRate: rate, channels: count,
                           limiting: limiting, vocal: boost))
    }

    /// Psychoacoustic bass' amount, 0 (off) to 1.
    func update(bass amount: Double) { lock.withLockUnchecked { bassAmount = Float(amount) } }

    /// Loudness compensation's shelves for the volume now ([] when off or at full volume).
    func update(loudness shelves: [CorrectionFilter]) {
        let (rate, count, current, boost) = lock.withLockUnchecked { () -> (Double, Int, [Double], Double) in
            loudness = shelves
            return (sampleRate, channels, gains, vocalGain)
        }
        install(Self.build(gains: current, correction: correction, loudness: shelves, sampleRate: rate, channels: count,
                           limiting: limiting, vocal: boost))
    }

    /// Vocal presence's boost, in dB (0: off), as its slider moves: the filter and the preamp made again.
    func update(vocal gain: Double) {
        let (rate, count, current, shelves) = lock.withLockUnchecked { () -> (Double, Int, [Double], [CorrectionFilter]) in
            vocalGain = gain
            return (sampleRate, channels, gains, loudness)
        }
        install(Self.build(gains: current, correction: correction, loudness: shelves, sampleRate: rate, channels: count,
                           limiting: limiting, vocal: gain),
                vocal: count == 2 && gain > 0 ? VocalClarity(gain: gain, sampleRate: rate) : nil, vocalChanges: true)
    }

    /// A crossfade's fade from here: equal power (a sine in, a cosine out), so the two songs together are as loud as one.
    func fade(in incoming: Bool, over seconds: Double) {
        lock.withLockUnchecked { fading = (incoming, max(seconds, 0.01), 0) }
    }

    /// The fade's gain after `done` frames of it.
    private func fadeGain(_ done: Int) -> Float {
        guard let fading else { return silenced ? 0 : 1 }
        let share = min(1, Double(done) / (fading.seconds * sampleRate))
        let angle: Double = share * Double.pi / 2
        return Float(fading.incoming ? sin(angle) : cos(angle))
    }

    /// The levelling gain, in dB: the audio glides to it.
    func update(level: Double) {
        let linear = Float(pow(10, level / 20))
        lock.withLockUnchecked { self.level = linear }
    }

    /// The tap's prepare: the format is known now.
    #if DEBUG
    /// Self-tests: when this tap was prepared, and when it processed its first and its latest buffer (absolute time).
    nonisolated(unsafe) var timingsForTests: (prepared: Double, first: Double, last: Double) = (0, 0, 0)
    #endif

    fileprivate func prepare(format: AudioStreamBasicDescription) {
        #if DEBUG
        if timingsForTests.prepared == 0 { timingsForTests.prepared = CFAbsoluteTimeGetCurrent() }
        #endif
        let harmonics = BassHarmonics(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame))
        let float = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let separate = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 || format.mChannelsPerFrame == 1
        let current = lock.withLockUnchecked { () -> [Double] in
            sampleRate = format.mSampleRate
            channels = Int(format.mChannelsPerFrame)
            usable = float && separate
            bass = harmonics
            return gains
        }
        let count = Int(format.mChannelsPerFrame)
        let (boost, shelves) = lock.withLockUnchecked { (vocalGain, loudness) }
        install(Self.build(gains: current, correction: correction, loudness: shelves, sampleRate: format.mSampleRate,
                           channels: count, limiting: limiting, vocal: boost),
                limiter: limiting && count > 0 ? PeakLimiter(sampleRate: format.mSampleRate, channels: count) : nil,
                crossfeed: crossfeeding && count == 2 ? Crossfeed(sampleRate: format.mSampleRate) : nil,
                vocal: count == 2 && boost > 0 ? VocalClarity(gain: boost, sampleRate: format.mSampleRate) : nil, vocalChanges: true)
    }

    /// The headphone correction's filters, then the bands', in one cascade; the preamp lowers the whole curve by its peak.
    /// `vocal`: vocal clarity's boost, which the preamp makes room for too (the mid up by g, the side as it was: no
    /// sample can grow by more than g).
    /// `loudness`: loudness compensation's shelves, last and outside the preamp: the volume after the tap always takes
    /// off more than they add (SoundChain.loudnessShelves), so they cannot make the output louder than full volume would.
    private static func build(gains: [Double], correction: [CorrectionFilter] = [], loudness: [CorrectionFilter] = [],
                              sampleRate: Double, channels: Int, limiting: Bool, vocal: Double = 0) -> Cascade? {
        guard channels > 0 else { return nil }
        let coefficients = correction.flatMap { $0.coefficients(sampleRate: sampleRate) } + coefficients(gains: gains, sampleRate: sampleRate)
        let room: Double = peak(coefficients: coefficients, sampleRate: sampleRate) + max(0, vocal)
        let preamp = limiting ? 1 : Float(pow(10, -room / 20))
        let all = coefficients + loudness.flatMap { $0.coefficients(sampleRate: sampleRate) }
        return Cascade(coefficients: all, sections: all.count / 5, channels: channels, preamp: preamp)
    }

    /// Swapped in under the lock; the old ones are let go here, never on the audio thread.
    /// `vocalChanges`: vocal clarity's filter is replaced by `vocal`, nil included (it was turned off).
    private func install(_ new: Cascade?, limiter newLimiter: PeakLimiter? = nil, crossfeed newCrossfeed: Crossfeed? = nil,
                         vocal newVocal: VocalClarity? = nil, vocalChanges: Bool = false) {
        let old = lock.withLockUnchecked { () -> (Cascade?, PeakLimiter?, Crossfeed?, VocalClarity?) in
            let old = (cascade, limiter, crossfeed, vocal)
            cascade = new
            if newLimiter != nil { limiter = newLimiter }
            if newCrossfeed != nil { crossfeed = newCrossfeed }
            if vocalChanges { vocal = newVocal }
            return old
        }
        _ = old
    }

    /// The audio thread: each channel's buffer through the cascade, in place, then the gain (the preamp times the
    /// level). The first buffer starts at the gain; a later change glides there (`glideSeconds`). Then crossfeed and the
    /// limiter, when on. A flat curve at 0 dB with neither leaves the audio untouched.
    fileprivate func process(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        #if DEBUG
        let now = CFAbsoluteTimeGetCurrent()
        if timingsForTests.first == 0 { timingsForTests.first = now }
        timingsForTests.last = now
        #endif
        lock.withLockUnchecked {
            #if DEBUG
            measure(buffers, frames: frames, into: &energyIn)
            #endif
            if usable, buffers.count == channels, frames > 0 {
                if let cascade, cascade.delays.count == channels {
                    for (buffer, delay) in zip(buffers, cascade.delays) {
                        guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        vDSP_biquad(cascade.setup, delay, samples, 1, samples, 1, vDSP_Length(frames))
                    }
                }
                let target = (cascade?.preamp ?? 1) * level
                let from = applied ?? target
                let keep = Float(exp(-Double(frames) / (sampleRate * Self.glideSeconds)))
                var to: Float = target + (from - target) * keep
                if abs(to - target) <= target * 0.001 { to = target }
                applied = to
                // the crossfade's fade, on top: its gain at this buffer's start and end
                let done = fading?.done ?? 0
                let fadeFrom = fadeGain(done), fadeTo = fadeGain(done + frames)
                if let current = fading {
                    let finished = Double(done + frames) >= current.seconds * sampleRate
                    fading = finished ? nil : (current.incoming, current.seconds, done + frames)
                    if finished, !current.incoming { silenced = true }
                }
                let start: Float = from * fadeFrom, finish: Float = to * fadeTo
                if start != 1 || finish != 1 {
                    for buffer in buffers {
                        guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        if start == finish {
                            var gain = finish
                            vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frames))
                        } else {
                            var first = start, step = (finish - start) / Float(frames)
                            vDSP_vrampmul(samples, 1, &first, &step, samples, 1, vDSP_Length(frames))
                        }
                    }
                }
                if bassAmount > 0, let bass {
                    for (channel, buffer) in buffers.enumerated() {
                        guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        bass.process(samples, channel: channel, frames: frames, amount: bassAmount)
                    }
                }
                if buffers.count == 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                   let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    vocal?.process(left, right, frames: frames)
                    crossfeed?.process(left, right, frames: frames)
                }
                if let limiter, limiter.channels == buffers.count {
                    withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: buffers.count) { pointers in
                        for (i, buffer) in buffers.enumerated() {
                            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
                            pointers[i] = samples
                        }
                        limiter.process(pointers, frames: frames)
                    }
                }
            }
            #if DEBUG
            measure(buffers, frames: frames, into: &energyOut)
            processedFrames += frames
            #endif
        }
    }

    #if DEBUG
    /// Self-tests: frames through the tap, and the audio's energy (sum of squares) before and after the filters.
    private var energyIn = 0.0, energyOut = 0.0, processedFrames = 0
    private func measure(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int, into total: inout Double) {
        for buffer in buffers {
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            var sum: Float = 0
            vDSP_svesq(samples, 1, &sum, vDSP_Length(frames))
            total += Double(sum)
        }
    }
    /// Frames so far, and the change in loudness since the last reading in dB (nil before any audio), then starts over.
    func takeReading() -> (frames: Int, change: Double?) {
        lock.withLockUnchecked {
            defer { energyIn = 0; energyOut = 0 }
            let change = energyIn > 0 && energyOut > 0 ? 10 * log10(energyOut / energyIn) : nil
            return (processedFrames, change)
        }
    }

    /// The limiter's lowest gain so far, in dB (nil without a limiter).
    var limiterDeepestForTests: Double? { lock.withLockUnchecked { limiter.map { 20 * log10(Double($0.deepest)) } } }

    /// The crossfade's gain now, 0 to 1.
    var fadeForTests: Double { lock.withLockUnchecked { Double(fadeGain(fading?.done ?? 0)) } }

    /// The gain the last buffer ended at, in dB (nil before any audio).
    var appliedForTests: Double? { lock.withLockUnchecked { applied.map { 20 * log10(Double($0)) } } }

    /// Self-tests: `seconds` of a sine at `frequency`, through these filters as the tap would run them, and the change
    /// in loudness in dB over the second half (no audio device involved). `meanwhile` runs at the half.
    func offline(frequency: Double, sampleRate rate: Double = 44_100, seconds: Double = 1, meanwhile: (() -> Void)? = nil) -> Double {
        let format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        prepare(format: format)
        _ = takeReading()
        let frames = Int(rate * seconds)
        var samples = (0..<frames).map { Float(0.25 * sin(2 * .pi * frequency * Double($0) / rate)) }
        samples.withUnsafeMutableBufferPointer { pointer in
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(list.unsafeMutablePointer) }
            for start in stride(from: 0, to: frames, by: 1024) {          // as the tap is called: a buffer at a time
                let count = min(1024, frames - start)
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: pointer.baseAddress! + start)
                if start == frames / 2 / 1024 * 1024 {                    // the second half: the filters have settled
                    _ = takeReading()
                    meanwhile?()
                }
                process(list, frames: count)
            }
        }
        return takeReading().change ?? 0
    }
    #endif

    /// The tap that runs these filters (MTAudioProcessingTap); it holds this processor until it is let go.
    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(self).toOpaque(),
            init: soundTapInit, finalize: soundTapFinalize, prepare: soundTapPrepare, unprepare: nil, process: soundTapProcess)
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects,
                                         &tap) == noErr else {
            Unmanaged.passUnretained(self).release()
            return nil
        }
        return tap
    }
}

/// Settings › Playback › Psychoacoustic bass (29 Oct): bass a small speaker or earbuds cannot play, heard anyway. The ear
/// hears the pitch of a low note from its harmonics too, so a low band (under 120 Hz) is pushed through a soft clipper,
/// which makes odd harmonics (3×, 5× its frequency), and only those (110 to 420 Hz) are added back to the song. A 50 Hz
/// note then also sounds at 150 Hz. Each channel on its own; the song itself is not changed below 110 Hz.
nonisolated final class BassHarmonics {
    private static let chunk = 4096
    private let low: vDSP_biquad_Setup, band: vDSP_biquad_Setup
    private let lowDelay: [UnsafeMutablePointer<Float>], bandDelay: [UnsafeMutablePointer<Float>]
    private let scratch: UnsafeMutablePointer<Float>, shaped: UnsafeMutablePointer<Float>

    init?(sampleRate rate: Double, channels: Int) {
        guard channels > 0 else { return nil }
        let lowPass = Self.biquad(high: false, at: 120, rate: rate)
        let highPass = Self.biquad(high: true, at: 110, rate: rate), topPass = Self.biquad(high: false, at: 420, rate: rate)
        guard let low = vDSP_biquad_CreateSetup(lowPass, 1), let band = vDSP_biquad_CreateSetup(highPass + highPass + highPass + topPass, 4) else { return nil }
        self.low = low
        self.band = band
        func lines(_ sections: Int) -> [UnsafeMutablePointer<Float>] {
            (0..<channels).map { _ in
                let line = UnsafeMutablePointer<Float>.allocate(capacity: 2 * sections + 2)
                line.initialize(repeating: 0, count: 2 * sections + 2)
                return line
            }
        }
        lowDelay = lines(1)
        bandDelay = lines(4)
        scratch = .allocate(capacity: Self.chunk)
        shaped = .allocate(capacity: Self.chunk)
    }

    deinit {
        vDSP_biquad_DestroySetup(low)
        vDSP_biquad_DestroySetup(band)
        lowDelay.forEach { $0.deallocate() }
        bandDelay.forEach { $0.deallocate() }
        scratch.deallocate()
        shaped.deallocate()
    }

    /// A second-order Butterworth low or high pass (Audio EQ Cookbook), as vDSP takes it.
    private static func biquad(high: Bool, at frequency: Double, rate: Double) -> [Double] {
        let w: Double = 2 * Double.pi * frequency / rate, c: Double = cos(w), alpha: Double = sin(w) / (2 * 0.7071)
        let a0: Double = 1 + alpha
        let edge: Double = (high ? 1 + c : 1 - c) / 2 / a0
        return [edge, (high ? -2 : 2) * edge, edge, -2 * c / a0, (1 - alpha) / a0]
    }

    /// `amount` 0 to 1 scales the added harmonics (at most about a third of the song's own level at 1).
    func process(_ samples: UnsafeMutablePointer<Float>, channel: Int, frames: Int, amount: Float) {
        var start = 0
        while start < frames {
            let n = min(Self.chunk, frames - start), at = samples + start
            scratch.update(from: at, count: n)
            vDSP_biquad(low, lowDelay[channel], scratch, 1, scratch, 1, vDSP_Length(n))
            var drive: Float = 6, count = Int32(n)
            vDSP_vsmul(scratch, 1, &drive, scratch, 1, vDSP_Length(n))
            vvtanhf(shaped, scratch, &count)
            vDSP_biquad(band, bandDelay[channel], shaped, 1, shaped, 1, vDSP_Length(n))
            var gain: Float = 0.35 * amount, floor: Float = -1, ceiling: Float = 1
            vDSP_vsma(shaped, 1, &gain, at, 1, at, 1, vDSP_Length(n))
            vDSP_vclip(at, 1, &floor, &ceiling, at, 1, vDSP_Length(n))      // never past full scale (the limiter, when on, is gentler)
            start += n
        }
    }
}

/// Settings › Playback › Vocal presence (28 Oct): the voice brought forward without the instruments around it. The
/// song is split into mid (what both ears share, where a lead vocal sits) and side (what differs, where most guitars,
/// pads and reverb sit); only the mid is boosted, around 2.5 kHz (Q 0.7: about 1 to 5 kHz, the voice's presence), and
/// the two put back together. The equalizer boosts both ears alike, so it lifts everything in that range. Stereo only.
nonisolated final class VocalClarity {
    static let centre = 2500.0, q = 0.7
    private let b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    /// `gain`: the boost in dB.
    init(gain: Double, sampleRate rate: Double) {
        let k = CorrectionFilter(kind: .peak, frequency: Self.centre, gain: gain, q: Self.q).coefficients(sampleRate: rate)
        (b0, b1, b2, a1, a2) = k.count == 5 ? (k[0], k[1], k[2], k[3], k[4]) : (1, 0, 0, 0, 0)
    }

    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let l = Double(left[i]), r = Double(right[i])
            let mid: Double = (l + r) / 2, side: Double = (l - r) / 2
            var out: Double = b0 * mid + b1 * x1
            out += b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = mid; y2 = y1; y1 = out
            left[i] = Float(out + side)
            right[i] = Float(out - side)
        }
    }
}

/// Headphone crossfeed (Settings › Playback): a little of each channel's bass goes to the other ear, as from
/// speakers in a room, so a song panned hard to one side is less tiring. Bauer's stereophonic-to-binaural filter as
/// libbs2b (MIT) builds it, at its default level (cut at 700 Hz, fed 4.5 dB under the direct sound): each channel through
/// a one-pole low pass to the other side, and a high boost on its own side, then a gain that keeps the bass where it was.
/// Stereo only.
nonisolated final class Crossfeed {
    static let cut = 700.0, feed = 4.5

    private let a0Low: Float, b1Low: Float, a0High: Float, a1High: Float, b1High: Float, gain: Float
    private var low: (Float, Float) = (0, 0), high: (Float, Float) = (0, 0), last: (Float, Float) = (0, 0)

    init(sampleRate rate: Double) {
        // as bs2b_init (libbs2b 3.1.0)
        let lowDB: Double = -Self.feed * 5 / 6 - 3
        let highDB: Double = Self.feed / 6 - 3
        let lowGain: Double = pow(10, lowDB / 20)
        let highGain: Double = 1 - pow(10, highDB / 20)
        let octaves: Double = (lowDB - 20 * log10(highGain)) / 12
        let highCut: Double = Self.cut * pow(2, octaves)
        var x = exp(-2 * Double.pi * Self.cut / rate)
        b1Low = Float(x)
        a0Low = Float(lowGain * (1 - x))
        x = exp(-2 * Double.pi * highCut / rate)
        b1High = Float(x)
        a0High = Float(1 - highGain * (1 - x))
        a1High = Float(-x)
        gain = Float(1 / (1 - highGain + lowGain))
    }

    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let l = left[i], r = right[i]
            low = (a0Low * l + b1Low * low.0, a0Low * r + b1Low * low.1)
            let highLeft: Float = a0High * l + a1High * last.0 + b1High * high.0
            let highRight: Float = a0High * r + a1High * last.1 + b1High * high.1
            high = (highLeft, highRight)
            last = (l, r)
            left[i] = (high.0 + low.1) * gain
            right[i] = (high.1 + low.0) * gain
        }
    }
}

/// A look-ahead peak limiter (Settings › Playback › Limiter): no sample leaves above −1 dBFS. The audio is held back
/// 5 ms, so the gain is already down when a peak arrives: each sample's needed gain (the ceiling over its loudest
/// channel), the lowest of those over the next 5 ms, averaged over 5 ms (Rudrich's construction: the average at a
/// peak only covers values at or under that peak's own, so it never lets one through), then a release of 80 ms back
/// up, so the gain does not move within a bass note. Allocated off the audio thread; a sample at a time on it.
nonisolated final class PeakLimiter {
    static let ceiling = Float(pow(10, -1.0 / 20))
    static let lookahead = 0.005, release = 0.08
    /// True peak (ITU-R BS.1770-4's 4× oversampling): the wave between two samples can rise above both, up to 3 dB or
    /// more on loud masters, and clips in the converter. Each gap is read at ¼, ½ and ¾ by a 12-tap windowed-sinc
    /// interpolator, so a peak is known `tail` samples after it happens: the audio is held back that much longer.
    private static let taps = 12, tail = 6
    /// The three phases' taps, one after another (36 floats): a flat table read through a pointer, not an array of arrays
    /// looked up for every sample.
    private static let phaseTable: [Float] = (1...3).flatMap { quarter -> [Float] in
        let offset = Double(quarter) / 4
        func bessel(_ x: Double) -> Double { (0..<30).reduce(0.0) { $0 + pow(pow(x / 2, Double($1)) / tgamma(Double($1) + 1), 2) } }
        let weights: [Double] = (0..<taps).map { j in
            let t: Double = Double(j - 5) - offset
            let sinc: Double = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
            return sinc * bessel(8 * (1 - (t / 6) * (t / 6)).squareRoot()) / bessel(8)
        }
        let total: Double = weights.reduce(0, +)
        return weights.map { Float($0 / total) }
    }

    let channels: Int
    private let latency: Int                       // L: the look-ahead, in samples
    private let window: Int                        // L + 1: the minimum's and the average's span
    private let hold: Int                          // L + tail: samples the audio is held back
    private let table: UnsafeMutablePointer<Float>         // the interpolator's 36 taps (phaseTable)
    private let history: UnsafeMutablePointer<Float>       // each channel's last 12 samples, kept twice so they are in a row
    private var historyAt = 0
    private let delay: UnsafeMutablePointer<Float>         // channels × hold
    private let held: UnsafeMutablePointer<Float>          // the last `window` minimums, for the average
    private let order: UnsafeMutablePointer<Int>           // the sliding minimum: sample numbers…
    private let lows: UnsafeMutablePointer<Float>          // …and their needed gains, rising from the front
    private var front = 0, count = 0
    private var sum: Double
    private var at = 0, delayAt = 0, sample = 0
    private var gain: Float = 1
    private let rise: Float
    #if DEBUG
    private(set) var deepest: Float = 1            // self-tests: the lowest gain so far
    #endif

    init(sampleRate: Double, channels: Int) {
        self.channels = channels
        latency = max(1, Int((sampleRate * Self.lookahead).rounded()))
        window = latency + 1
        hold = latency + Self.tail
        table = .allocate(capacity: 3 * Self.taps)
        table.update(from: Self.phaseTable, count: 3 * Self.taps)
        history = .allocate(capacity: channels * 2 * Self.taps)
        history.initialize(repeating: 0, count: channels * 2 * Self.taps)
        delay = .allocate(capacity: channels * hold)
        delay.initialize(repeating: 0, count: channels * hold)
        held = .allocate(capacity: window)
        held.initialize(repeating: 1, count: window)
        order = .allocate(capacity: window)
        lows = .allocate(capacity: window)
        sum = Double(window)
        rise = Float(1 - exp(-1 / (sampleRate * Self.release)))
    }

    deinit {
        delay.deallocate(); held.deallocate(); order.deallocate(); lows.deallocate(); history.deallocate(); table.deallocate()
    }

    /// `samples`: one pointer per channel (from the stack: nothing is allocated on the audio thread).
    func process(_ samples: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frames: Int) {
        guard samples.count == channels else { return }
        for i in 0..<frames {
            // the loudest the wave gets in the gap that has just become readable: sample k (6 back) and the three points
            // between it and the next, in every channel
            var loudest: Float = 0
            for c in 0..<channels {
                let line = history + c * 2 * Self.taps
                line[historyAt] = samples[c][i]
                line[historyAt + Self.taps] = samples[c][i]
                let recent = line + historyAt + 1                 // the last 12 samples, oldest first
                loudest = max(loudest, abs(recent[5]))
                for phase in 0..<3 {
                    let weights = table + phase * Self.taps
                    var between: Float = 0
                    for j in 0..<Self.taps { between += weights[j] * recent[j] }
                    loudest = max(loudest, abs(between))
                }
            }
            historyAt = (historyAt + 1) % Self.taps
            let need = loudest > Self.ceiling ? Self.ceiling / loudest : 1
            // the sliding minimum of the last `window` needs: a queue kept rising, so its front is the minimum
            while count > 0, lows[(front + count - 1) % window] >= need { count -= 1 }
            order[(front + count) % window] = sample
            lows[(front + count) % window] = need
            count += 1
            while order[front] <= sample - window { front = (front + 1) % window; count -= 1 }
            let low = lows[front]
            sum += Double(low - held[at])
            held[at] = low
            at = (at + 1) % window
            let smooth = Float(sum / Double(window))
            gain = smooth < gain ? smooth : gain + (smooth - gain) * rise
            #if DEBUG
            deepest = min(deepest, gain)
            #endif
            for c in 0..<channels {
                let slot = c * hold + delayAt
                let late = delay[slot]
                delay[slot] = samples[c][i]
                samples[c][i] = late * gain
            }
            delayAt = (delayAt + 1) % hold
            sample += 1
        }
    }
}

// The tap's callbacks, called by MediaToolbox on its own threads: C functions, with the processor as the tap's storage.

private nonisolated func soundTapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer?,
                                      _ storage: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    storage.pointee = clientInfo
}

private nonisolated func soundTapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<SoundProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private nonisolated func soundTapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount,
                                         _ format: UnsafePointer<AudioStreamBasicDescription>) {
    Unmanaged<SoundProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format: format.pointee)
}

private nonisolated func soundTapProcess(_ tap: MTAudioProcessingTap, _ frames: CMItemCount, _ flags: MTAudioProcessingTapFlags,
                                         _ buffers: UnsafeMutablePointer<AudioBufferList>, _ framesOut: UnsafeMutablePointer<CMItemCount>,
                                         _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
    Unmanaged<SoundProcessor>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
        .process(UnsafeMutableAudioBufferListPointer(buffers), frames: Int(framesOut.pointee))
}
