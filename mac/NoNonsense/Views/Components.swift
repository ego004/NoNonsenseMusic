import SwiftUI

/// Album cover with continuous ("squircle") corners and a hairline edge, like Apple Music.
struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var radius: CGFloat = 8
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .id(ObjectIdentifier(image))                // a new cover crossfades over the old one
                    .transition(.opacity)
            } else {
                Rectangle().fill(.primary.opacity(0.07))        // only before any cover has loaded: dark-friendly, no grey flash
                Image(systemName: "music.note").font(.system(size: size * 0.32)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        .task(id: url) {
            guard let url else { image = nil; return }
            // keep showing the current cover while the next one loads; swap only when it is ready
            var next = ArtworkCache.shared.cached(url)
            if next == nil { next = await ArtworkCache.shared.image(for: url) }
            if let next { withAnimation(.easeInOut(duration: 0.28)) { image = next } }
        }
    }
}

/// The playing song's colour: its cover shrunk to 3×3 pixels, drawn as a mesh gradient whose inner points drift
/// slowly, like Apple Music's animated backgrounds. A new song's mesh crossfades over the old one.
/// `strength` scales it; `base` adds a material underneath (Now Playing). Still when Reduce Motion is on.
struct Backdrop: View {
    let track: Track?
    var strength: Double = 1
    var base: AnyShapeStyle? = nil
    @AppStorage("animateBackdrop") private var animate = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var windowState      // .inactive when another app is in front
    @Environment(\.colorScheme) private var scheme
    @Environment(Player.self) private var player
    @AppStorage(Theme.modeKey) private var colorMode = "song"
    @AppStorage(Theme.backgroundKey) private var customBackground = Theme.defaultBackground
    @State private var mesh: (key: String, colors: [Color])?

    /// What the mesh is made from: your background colour, or the playing cover. Changing it crossfades.
    private var source: String {
        colorMode == "custom" ? "custom:\(customBackground)" : (track?.image?.absoluteString ?? "")
    }

    /// Battery: the mesh moves only while music plays, the app is in front, Low Power Mode is off,
    /// Reduce Motion is off and the setting is on. Otherwise it is a still image (no frames drawn).
    private var moving: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["NN_FORCE_MOTION"] != nil { return animate }   // CPU measurements only
        #endif
        return animate && !reduceMotion && player.isPlaying && windowState != .inactive
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        ZStack {
            if let base { Rectangle().fill(base) }
            if let mesh {
                // 30 frames a second is plenty for a drift that takes ~30 s per cycle (the screen may run at 120)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !moving)) { context in
                    MeshGradient(width: 3, height: 3,
                                 points: Self.points(at: moving ? context.date.timeIntervalSinceReferenceDate : 0),
                                 colors: mesh.colors.map { $0.mix(with: scheme == .dark ? .black : .white, by: 0.3) })
                }
                .id(mesh.key)                                   // identity = the cover: changing it crossfades
                .transition(.opacity)
                .opacity(strength)
            }
        }
        .ignoresSafeArea()
        .task(id: source) {
            let key = source
            if colorMode == "custom", let base = Color(hex: customBackground) {
                withAnimation(.easeInOut(duration: 0.8)) { mesh = (key, Self.shades(of: base)) }
                return
            }
            guard let url = track?.image else { withAnimation(.easeInOut(duration: 0.8)) { mesh = nil }; return }
            guard let colors = await ArtworkCache.shared.colorGrid(for: url) else { return }
            withAnimation(.easeInOut(duration: 1.1)) { mesh = (key, colors) }
        }
    }

    /// Nine shades of one colour, darker at the edges and lighter near the middle, so a single colour still has depth.
    static func shades(of base: Color) -> [Color] {
        let mix: [(Color, Double)] = [(.black, 0.30), (.black, 0.12), (.black, 0.28),
                                      (.black, 0.05), (.white, 0.12), (.black, 0.08),
                                      (.black, 0.32), (.black, 0.15), (.black, 0.30)]
        return mix.map { base.mix(with: $0.0, by: $0.1) }
    }

    /// The nine points. Corners stay put; the edge middles slide along their edge and the centre circles,
    /// each on its own slow cycle (about 30 s), so the colours breathe without ever looking busy.
    static func points(at t: Double) -> [SIMD2<Float>] {
        func wave(_ speed: Double, _ phase: Double, _ amount: Double) -> Float { Float(sin(t * speed + phase) * amount) }
        return [
            SIMD2(0, 0), SIMD2(0.5 + wave(0.21, 0.0, 0.14), 0), SIMD2(1, 0),
            SIMD2(0, 0.5 + wave(0.17, 1.3, 0.14)),
            SIMD2(0.5 + wave(0.19, 2.1, 0.16), 0.5 + wave(0.23, 0.7, 0.16)),
            SIMD2(1, 0.5 + wave(0.15, 3.7, 0.14)),
            SIMD2(0, 1), SIMD2(0.5 + wave(0.18, 4.4, 0.14), 1), SIMD2(1, 1),
        ]
    }
}

struct LikeButton: View {
    let track: Track
    var font: Font = .body
    @Environment(LibraryStore.self) private var library
    @AppStorage(Theme.modeKey) private var colorMode = "song"
    @AppStorage(Theme.heartKey) private var customHeart = Theme.defaultHeart

    /// From the song: the cover's accent (the tint). Custom: your heart colour.
    private var heart: AnyShapeStyle {
        if colorMode == "custom", let color = Color(hex: customHeart) { AnyShapeStyle(color) } else { AnyShapeStyle(.tint) }
    }

    var body: some View {
        let liked = library.isLiked(track)
        Button {
            Task { await library.toggleLike(track) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(font)
                .foregroundStyle(liked ? heart : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: liked)
        }
        .buttonStyle(.plain)
        .help(liked ? "Remove from Liked" : "Like")
    }
}

/// A thin progress line that thickens on hover and can be dragged to seek.
struct ProgressBar: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void
    var thickness: CGFloat = 3
    @State private var hovering = false
    @State private var dragged: Double?
    @AppStorage("haptics") private var haptics = true

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(1, max(0, (dragged ?? position) / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(.tint).frame(width: geo.size.width * fraction)
            }
            .frame(height: hovering || dragged != nil ? thickness * 2 : thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragged = max(0, min(1, value.location.x / geo.size.width)) * duration }
                .onEnded { _ in if let d = dragged { onSeek(d) }; dragged = nil })
        }
        .frame(height: 14)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        // while scrubbing: a tick each time the drag crosses a whole minute
        .sensoryFeedback(.alignment, trigger: dragged.map { Int($0 / 60) }) { _, _ in haptics && dragged != nil }
    }
}

/// The see-through window background: the desktop behind the window shows through, blurred. AppKit's
/// behind-window blur, the mechanism Finder's sidebar uses. macOS makes it opaque when Reduce Transparency is on.
struct WindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow      // sample what is behind the window, not what is inside it
        view.state = .active                   // stay see-through when the window is not in front
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

/// Mute button and slider. The speaker's waves follow the level (an SF Symbols "variable value").
struct VolumeControl: View {
    var width: CGFloat = 84
    @Environment(Player.self) private var player
    @AppStorage("haptics") private var haptics = true

    var body: some View {
        HStack(spacing: 6) {
            Button { player.toggleMute() } label: {
                Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill",
                      variableValue: Double(player.volume))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(player.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")

            Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.small)
                .frame(width: width)
                .sensoryFeedback(.levelChange, trigger: Int((player.volume * 10).rounded())) { _, _ in haptics }   // a tick every 10%
                .help("Volume (⌘↑ / ⌘↓)")
                .accessibilityLabel("Volume")
        }
    }
}

extension Color {
    /// "#RRGGBB" (the # is optional) to a colour; nil when it is not six hex digits.
    init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// The colour as "#RRGGBB" (sRGB).
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}
