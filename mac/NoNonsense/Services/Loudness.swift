import Accelerate
import AVFoundation
import Observation

/// Settings › Playback › Loudness normalization (28 Oct): each copy's loudness is measured once from its file, as
/// ITU-R BS.1770-4 measures it (the LUFS that Spotify, YouTube and Apple Music level by), and the song is played turned
/// up or down to the target level (−14 LUFS, the level Spotify and YouTube play at, unless set otherwise). A boost stops 1 dB under the song's loudest sample, so
/// levelling never clips. Off by default; off, nothing is measured and no tap is attached for it.
///
/// A copy is measured when its whole file is in the cache (the next song, fetched while this one plays, is measured
/// before it starts), when it plays from a file not measured yet, and, when switched on, every song already in the cache.
/// One at a time, at low priority. A song not measured yet starts at the library's usual gain and glides to its own in
/// about a second once measured. Readings are kept per copy (each source's file has its own loudness) in a small file
/// beside the app's other data, so they outlive the cache.
@MainActor
@Observable
final class Leveller {
    static let shared = Leveller()

    /// The level songs are played at, in LUFS: Settings › Playback › Target level. −14 (Spotify and YouTube) unless set to
    /// −18 (quiet: headroom for equalizer boosts) or −11 (loud).
    nonisolated static var target: Double {
        let stored = UserDefaults.standard.double(forKey: "levelTarget")
        return [-18.0, -14, -11].contains(stored) ? stored : -14
    }
    /// Room left under a boosted song's loudest sample, in dB: a sample peak can sit a little under the true peak.
    nonisolated static let headroom = 1.0

    private(set) var on: Bool
    /// Settings › Playback › Limiter: the last step of the chain (PeakLimiter) catches peaks, so the equalizer's boosts
    /// keep their volume and a quiet song is brought all the way up. On by default (29 Oct).
    private(set) var limiting: Bool
    /// Copies measured, by their names in the cache (AudioCache.name: the listing key, made a file name).
    @ObservationIgnored private var readings: [String: LoudnessMeter.Reading] = [:]
    @ObservationIgnored private var waiting: [(name: String, file: URL)] = []
    @ObservationIgnored private var measuring = false
    /// SoundChain: a copy was measured (its name), so its tap can glide to its own gain.
    @ObservationIgnored var measured: ((String) -> Void)?
    /// SoundChain: switched on or off.
    @ObservationIgnored var changed: (() -> Void)?

    /// Beside the app's other data; a Debug build (its own bundle id) keeps its own.
    nonisolated static let file: URL = URL.applicationSupportDirectory
        .appending(path: Bundle.main.bundleIdentifier ?? "app.nononsense.music").appending(path: "loudness.json")

    private init() {
        on = UserDefaults.standard.bool(forKey: "levelOn")
        limiting = Self.storedLimiting
        if let data = try? Data(contentsOf: Self.file),
           let saved = try? JSONDecoder().decode([String: LoudnessMeter.Reading].self, from: data) {
            readings = saved
        }
    }

    /// On unless switched off: a boost with no limiter lowers the whole song by its size (the preamp), which hid it.
    nonisolated static var storedLimiting: Bool { UserDefaults.standard.object(forKey: "limiterOn") as? Bool ?? true }

    func setOn(_ value: Bool) {
        guard value != on else { return }
        on = value
        UserDefaults.standard.set(value, forKey: "levelOn")
        changed?()
        if value { Task { await measureCache() } }
    }

    func setLimiting(_ value: Bool) {
        guard value != limiting else { return }
        limiting = value
        UserDefaults.standard.set(value, forKey: "limiterOn")
        changed?()
    }

    /// The gain for a copy, in dB: to the target, a boost no higher than its peak allows (with the limiter, as high as
    /// the target asks). A copy not measured yet gets the median of the measured ones' (0 before any).
    func gain(for key: String) -> Double {
        if let reading = readings[AudioCache.name(for: key)] { return Self.gain(reading, limiting: limiting) }
        let all = readings.values.map { Self.gain($0, limiting: limiting) }.sorted()
        return all.isEmpty ? 0 : all[all.count / 2]
    }

    func isMeasured(_ key: String) -> Bool { readings[AudioCache.name(for: key)] != nil }

    nonisolated static func gain(_ reading: LoudnessMeter.Reading, limiting: Bool = false) -> Double {
        min(max(target - reading.lufs, -20), limiting ? 12 : -reading.peak - headroom, 12)
    }

    /// Measures a copy's file, unless it is measured already: next, before the cache's backlog (it is playing, or about
    /// to). Nothing while off.
    func measure(_ key: String, file: URL) { measure(name: AudioCache.name(for: key), file: file, first: true) }

    private func measure(name: String, file: URL, first: Bool = false) {
        guard on, readings[name] == nil else { return }
        waiting.removeAll { $0.name == name }
        if first { waiting.insert((name, file), at: 0) } else { waiting.append((name, file)) }
        next()
    }

    private func next() {
        guard !measuring, !waiting.isEmpty else { return }
        let (name, file) = waiting.removeFirst()
        guard on, readings[name] == nil else { return next() }
        measuring = true
        Task.detached(priority: .utility) {
            let reading = try? LoudnessMeter.measure(file: file)
            await MainActor.run {
                self.measuring = false
                if let reading { self.keep(reading, for: name) }
                self.next()
            }
        }
    }

    private func keep(_ reading: LoudnessMeter.Reading, for name: String) {
        readings[name] = reading
        let all = readings
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(all).write(to: Self.file, options: .atomic)
        }
        measured?(name)
    }

    /// Switched on: the songs already in the cache, so they are level from their first note.
    private func measureCache() async {
        for (name, file) in await AudioCache.shared.contents() where readings[name] == nil { measure(name: name, file: file) }
    }

    #if DEBUG
    /// Self-tests: a reading set by hand, and all forgotten.
    func setForTests(_ reading: LoudnessMeter.Reading?, for key: String) {
        readings[AudioCache.name(for: key)] = reading
        if reading != nil { measured?(AudioCache.name(for: key)) }
    }
    var waitingForTests: Int { waiting.count + (measuring ? 1 : 0) }
    #endif
}

/// Integrated loudness, ITU-R BS.1770-4: each channel through the K-weighting filter (a high shelf for the head, a high
/// pass under 40 Hz), mean square power in 400 ms blocks overlapping by 75%, then the mean of the blocks above two gates
/// (−70 LUFS, then 10 LU under the mean of those). A mono file counts as both channels, as it plays on two speakers.
nonisolated enum LoudnessMeter {
    struct Reading: Codable, Equatable, Sendable {
        let lufs: Double        // integrated loudness
        let peak: Double        // the loudest sample, dBFS
    }

    /// A whole file, decoded 64k frames at a time. nil for one with no audio above the gate (silence).
    static func measure(file url: URL) throws -> Reading? {
        let audio = try AVAudioFile(forReading: url)
        let format = audio.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return nil }
        let meter = Accumulator(sampleRate: format.sampleRate, channels: Int(format.channelCount))
        while audio.framePosition < audio.length {
            try audio.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            meter.add((0..<Int(format.channelCount)).map { UnsafePointer(data[$0]) }, frames: Int(buffer.frameLength))
        }
        return meter.result()
    }

    /// The K-weighting filter's two stages at `rate`, normalised as vDSP takes them (b0, b1, b2, a1, a2 each), derived as
    /// libebur128 derives them: at 48 kHz they are BS.1770's own table (to 1e-8), and any other rate is measured alike.
    /// (The Audio EQ Cookbook's shelf, tried first, read 0.21 LU low on EBU Tech 3341's tones, 28 Oct.)
    static func kWeighting(sampleRate rate: Double) -> [Double] {
        // the high shelf: +4 dB above ~1.7 kHz, for the head
        var k: Double = tan(Double.pi * 1681.974450955533 / rate)
        var q: Double = 0.7071752369554196
        let vh: Double = pow(10, 3.999843853973347 / 20)
        let vb: Double = pow(vh, 0.4996667741545416)
        let kk: Double = k * k, kq: Double = k / q
        var a0: Double = 1 + kq + kk
        let s0: Double = (vh + vb * kq + kk) / a0
        let s1: Double = 2 * (kk - vh) / a0
        let s2: Double = (vh - vb * kq + kk) / a0
        let s3: Double = 2 * (kk - 1) / a0
        let s4: Double = (1 - kq + kk) / a0
        // the high pass: −3 dB at ~38 Hz
        k = tan(Double.pi * 38.13547087602444 / rate)
        q = 0.5003270373238773
        let pk: Double = k * k, pq: Double = k / q
        a0 = 1 + pq + pk
        let p3: Double = 2 * (pk - 1) / a0
        let p4: Double = (1 - pq + pk) / a0
        return [s0, s1, s2, s3, s4, 1, -2, 1, p3, p4]
    }

    /// Fed a buffer at a time; keeps each 100 ms step's weighted power (a block is four steps).
    final class Accumulator {
        private let setup: vDSP_biquad_Setup
        private let delays: [UnsafeMutablePointer<Float>]
        private let weight: Double
        private let step: Int
        private var filled = 0, stepPower = 0.0
        private var steps: [Double] = []
        private var peak: Float = 0
        private var scratch: [Float] = []

        init(sampleRate: Double, channels: Int) {
            setup = vDSP_biquad_CreateSetup(LoudnessMeter.kWeighting(sampleRate: sampleRate), 2)!
            delays = (0..<max(channels, 1)).map { _ in
                let line = UnsafeMutablePointer<Float>.allocate(capacity: 6)
                line.initialize(repeating: 0, count: 6)
                return line
            }
            weight = channels == 1 ? 2 : 1
            step = max(1, Int((sampleRate / 10).rounded()))
        }

        deinit {
            vDSP_biquad_DestroySetup(setup)
            delays.forEach { $0.deallocate() }
        }

        func add(_ channels: [UnsafePointer<Float>], frames: Int) {
            guard frames > 0, channels.count == delays.count else { return }
            if scratch.count < frames { scratch = [Float](repeating: 0, count: frames) }
            // each channel filtered whole (its state carries on), its squares summed per step
            var power = [Double](repeating: 0, count: (filled + frames + step - 1) / step)
            for (samples, delay) in zip(channels, delays) {
                var loudest: Float = 0
                vDSP_maxmgv(samples, 1, &loudest, vDSP_Length(frames))
                peak = max(peak, loudest)
                scratch.withUnsafeMutableBufferPointer { out in
                    vDSP_biquad(setup, delay, samples, 1, out.baseAddress!, 1, vDSP_Length(frames))
                    var start = 0, slot = 0, room = step - filled
                    while start < frames {
                        let count = min(room, frames - start)
                        var sum: Float = 0
                        vDSP_svesq(out.baseAddress! + start, 1, &sum, vDSP_Length(count))
                        power[slot] += Double(sum)
                        start += count; slot += 1; room = step
                    }
                }
            }
            // whole steps go to the list; the last, partial one carries on
            var at = filled, slot = 0
            var remaining = frames
            while remaining > 0 {
                let count = min(step - at, remaining)
                let weighted: Double = power[slot] * weight      // its own line: Xcode 26.6 timed out type-checking it inline
                stepPower += weighted
                at += count; remaining -= count
                if at == step { steps.append(stepPower / Double(step)); stepPower = 0; at = 0 }
                slot += 1
            }
            filled = at
        }

        func result() -> LoudnessMeter.Reading? {
            guard steps.count >= 4 else { return nil }
            // 400 ms blocks every 100 ms: the mean of four steps
            // a loop, not a closure summing four terms: Xcode 26.6 timed out type-checking that
            var blocks: [Double] = []
            for i in 0...(steps.count - 4) {
                var sum: Double = steps[i]
                sum += steps[i + 1]
                sum += steps[i + 2]
                sum += steps[i + 3]
                blocks.append(sum / 4)
            }
            func loudness(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
            let audible = blocks.filter { $0 > 0 && loudness($0) > -70 }
            guard !audible.isEmpty else { return nil }
            let gate = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
            let kept = audible.filter { loudness($0) > gate }
            return Reading(lufs: loudness(kept.reduce(0, +) / Double(kept.count)), peak: 20 * log10(max(Double(peak), 1e-9)))
        }
    }
}
