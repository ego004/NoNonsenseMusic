import SwiftUI

/// Settings › Playback › Studio (Mac and iPhone): sub rumble, clarity, air and width (StudioChain), and one button that
/// sets the whole chain for deep, thumping bass with every instrument kept apart and clear vocals.
struct StudioSection: View {
    @AppStorage("studioRumble") private var rumble = 0.0
    @AppStorage("studioClarity") private var clarity = 0.0
    @AppStorage("studioAir") private var air = 0.0
    @AppStorage("studioWidth") private var width = 0.0

    var body: some View {
        Section {
            Button { StudioPreset.applyDeepBass() } label: {
                Label("Deep Bass Studio", systemImage: "waveform.badge.plus")
            }
            slider("Sub rumble", $rumble,
                   "Adds an octave below each kick and bass note (30 to 55 Hz), following the music. Needs headphones or speakers that reach low.")
            slider("Clarity", $clarity,
                   "Dips the 200 to 500 Hz mud only while the bass hits, so the bass can be big and everything else stays clear.")
            slider("Air", $air,
                   "Adds harmonics above 7 kHz from the upper mids: the detail and attack that let each instrument stand apart.")
            slider("Width", $width,
                   "Moves off-centre instruments further apart above 150 Hz and keeps the bass in the middle. A mono song is unchanged.")
        } header: {
            Text("Studio")
        } footer: {
            Text("Deep Bass Studio sets these, the Deep Bass equalizer, bass harmonics, vocal presence, loudness compensation and the limiter, normalization at −14 LUFS, and crossfeed off. Stereo only.")
        }
    }

    @ViewBuilder
    private func slider(_ title: String, _ value: Binding<Double>, _ caption: String) -> some View {
        let name = title + (value.wrappedValue > 0 ? ": \(Int((value.wrappedValue * 100).rounded()))%" : ": off")
        #if os(macOS)
        LabeledContent {
            Slider(value: value, in: 0...1).frame(maxWidth: 180)
        } label: {
            Text(name)
            Text(caption).foregroundStyle(.secondary)
        }
        .onChange(of: value.wrappedValue) { SoundChain.shared.studioChanged() }
        #else
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
            Text(caption).font(.caption).foregroundStyle(.secondary)
            Slider(value: value, in: 0...1)
        }
        .onChange(of: value.wrappedValue) { SoundChain.shared.studioChanged() }
        #endif
    }
}

/// The one-tap setting: the whole chain, for deep thumping bass, a full sound, every instrument clear and apart, and
/// clear vocals. Everything it sets is an ordinary setting, changed afterwards like any other.
@MainActor
enum StudioPreset {
    static func applyDeepBass() {
        let d = UserDefaults.standard
        d.set(0.55, forKey: "studioRumble")
        d.set(0.65, forKey: "studioClarity")
        d.set(0.45, forKey: "studioAir")
        d.set(0.6, forKey: "studioWidth")
        d.set(3.0, forKey: "vocalClarity")              // dB at 2.5 kHz, centre channel
        d.set(0.3, forKey: "bassHarmonics")
        d.set(true, forKey: "loudnessCompensation")
        d.set(false, forKey: "crossfeed")               // it narrows the image Width opens
        d.set(-14.0, forKey: "levelTarget")             // -18 left no loudness for the bass to use
        Leveller.shared.setLimiting(true)
        Leveller.shared.setOn(true)
        Equalizer.shared.setOn(true)
        Equalizer.shared.choose(.deepBass)
        SoundChain.shared.levelChanged()
        SoundChain.shared.loudnessChanged()
        SoundChain.shared.settingChanged()
    }
}
