import SwiftUI

/// Album cover with continuous ("squircle") corners and a hairline edge, like Apple Music.
struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var radius: CGFloat = 8
    @State private var image: NSImage?

    init(url: URL?, size: CGFloat, radius: CGFloat = 8) {
        self.url = url
        self.size = size
        self.radius = radius
        // a cover already in the cache shows at once: no empty square fading in every time a screen reappears
        _image = State(initialValue: url.flatMap { ArtworkCache.shared.cached($0) })
    }

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
    @AppStorage("animateBackdrop") private var animate = Look.animateBackdrop
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var windowState      // .inactive when another app is in front
    @Environment(\.colorScheme) private var scheme
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme
    @State private var mesh: (key: String, colors: [Color])?

    /// What the mesh is made from (Settings › Colours › Background): nothing, the playing cover, or your colour.
    private var source: String {
        switch theme.mode(.background) {
        case .system: "none"
        case .custom: "custom:\(theme.hex(.background))"
        case .song: track?.image?.absoluteString ?? "none"
        }
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
                // 10 a second: a step moves a colour ~3 pt; each frame costs ~0.5% of a core (measured 7 Oct)
                TimelineView(DriftSchedule(interval: 1.0 / 10, paused: !moving)) { context in
                    MeshGradient(width: 3, height: 3,
                                 points: Self.points(at: moving ? context.date.timeIntervalSinceReferenceDate : 0),
                                 colors: mesh.colors.map { $0.mix(with: scheme == .dark ? .black : .white, by: 0.3 * (1 - strength)) })
                }
                .saturation(1 + 0.35 * strength)                // vivid: unmixed and a little richer, not only more opaque
                .id(mesh.key)                                   // identity = the source: changing it crossfades
                .transition(.opacity)
                .opacity(strength)
            }
        }
        .ignoresSafeArea()
        .task(id: source) {
            let key = source
            if theme.mode(.background) == .system { withAnimation(.easeInOut(duration: 0.8)) { mesh = nil }; return }
            if theme.mode(.background) == .custom, let base = Color(hex: theme.hex(.background)) {
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

/// The backdrop in its own small SwiftUI host. Inside the window's own view tree, every frame of the moving mesh
/// made SwiftUI rebuild the whole window (every list row, every lyric line) and lay out the player bar again:
/// Now Playing with Lyrics took 30% of a core (profiled 7 Oct). In its own host, a frame redraws only the mesh.
struct IsolatedBackdrop: NSViewRepresentable {
    let track: Track?
    var strength: Double
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme

    final class Host: NSHostingView<AnyView> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }     // a background: clicks go to what is on top
    }

    func makeNSView(context: Context) -> Host {
        let host = Host(rootView: content)
        host.sizingOptions = []                                         // takes the frame it is given; asks for none
        return host
    }

    func updateNSView(_ host: Host, context: Context) { host.rootView = content }

    private var content: AnyView {
        AnyView(Backdrop(track: track, strength: strength).environment(player).environment(theme))
    }
}

/// A frame every `interval` seconds from a plain timer, or none while paused. `.animation(minimumInterval:)` kept
/// a display link running at the screen's full rate even when it drew 10 frames a second (testing 7 Oct).
struct DriftSchedule: TimelineSchedule {
    let interval: TimeInterval
    let paused: Bool

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next: Date? = start
        let paused = paused || mode == .lowFrequency            // also still when the system asks for fewer updates
        return AnyIterator {
            defer { next = paused ? nil : next?.addingTimeInterval(interval) }
            return next
        }
    }
}

struct LikeButton: View {
    let track: Track
    var font: Font = .body
    @Environment(LibraryStore.self) private var library
    @Environment(ThemeStore.self) private var theme

    /// Settings › Colours › Heart; System is the system pink.
    private var heart: Color { theme.color(.heart) ?? Color(nsColor: .systemPink) }

    var body: some View {
        let liked = library.isLiked(track)
        Button {
            Task { await library.toggleLike(track) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(font)
                .foregroundStyle(liked ? AnyShapeStyle(heart) : AnyShapeStyle(.secondary))
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
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(1, max(0, (dragged ?? position) / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(theme.color(.progress).map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary.opacity(0.7)))   // System: grey
                    .frame(width: geo.size.width * fraction)
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
/// `.withinWindow` blurs the app's own content under the view instead (the player bar over a list).
struct WindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var amount: Double = 1                     // 0 = no blur (the desktop shows sharp), 1 = fully frosted
    var blending: NSVisualEffectView.BlendingMode = .behindWindow   // sample what is behind the window, not what is inside it

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active                   // stay see-through when the window is not in front
        view.alphaValue = amount
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.alphaValue = amount
    }
}

/// One surface's background (Settings › Appearance › Surfaces): a blur, and over it the window's own colour.
/// Both at 0 draw nothing at all, so a surface left at 0 / 0 looks exactly as it did before the setting existed.
struct SurfaceLayer: View {
    var blur: Double                           // 0 = clear, 1 = fully frosted
    var solid: Double                          // 0 = see-through, 1 = the window's colour, opaque
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    var body: some View {
        ZStack {
            if blur > 0.001 { WindowBlur(amount: blur, blending: blending) }
            if solid > 0.001 { Color(nsColor: .windowBackgroundColor).opacity(solid) }
        }
    }
}

extension View {
    /// Debug builds: records where this view is, in window points, under `name` (SelfTest.frames). Self-tests
    /// measure layout with it: pictures cannot draw lists or glass, and SwiftUI shows an in-app accessibility
    /// walk nothing (6 Oct). Release builds: nothing.
    func selfTestFrame(_ name: String) -> some View {
        #if DEBUG
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SelfTest.frames[name] = $0 }
        #else
        self
        #endif
    }
}

/// Makes its window non-opaque with a clear background, so a thinned blur shows the desktop, not a grey window.
struct ClearWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }
}

/// Mute button and slider. The speaker's waves follow the level (an SF Symbols "variable value").
struct VolumeControl: View {
    var width: CGFloat = 84
    var slider = true                          // false: the speaker alone (a narrow player bar)
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme
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

            if slider {
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.small)
                .tint(theme.color(.volume))                    // Settings › Colours › Volume
                .frame(width: width)
                .sensoryFeedback(.levelChange, trigger: Int((player.volume * 10).rounded())) { _, _ in haptics }   // a tick every 10%
                .help("Volume (⌘↑ / ⌘↓)")
                .accessibilityLabel("Volume")
            }
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

// MARK: - Text size (Settings › Appearance › Text size)

/// How much bigger or smaller the app's text is than the Mac's: 0.85…1.4. macOS ignores SwiftUI's dynamicTypeSize
/// (measured 6 Oct: text came out the same width at every size), so the app sizes its own text with `textStyle`.
struct TextScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var textScale: CGFloat {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension Font.TextStyle {
    /// The Mac's own point size for each style, measured on macOS 26 (6 Oct): at scale 1 the app looks as before.
    var macPointSize: CGFloat {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }
}

private struct ScaledText: ViewModifier {
    @Environment(\.textScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: size * scale, weight: weight)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// A text style at the size Settings chose (`.font(.callout)` would stay at the Mac's size).
    func textStyle(_ style: Font.TextStyle, weight: Font.Weight? = nil, monospacedDigit: Bool = false) -> some View {
        modifier(ScaledText(size: style.macPointSize, weight: weight ?? (style == .headline ? .bold : .regular), monospacedDigit: monospacedDigit))
    }

    /// A custom size that also follows the setting (the big titles).
    func textStyle(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledText(size: size, weight: weight, monospacedDigit: false))
    }
}
