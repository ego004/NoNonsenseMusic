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
        _image = State(initialValue: url.flatMap { ArtworkCache.shared.cached($0, size: size) })
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
            var next = ArtworkCache.shared.cached(url, size: size)
            if next == nil { next = await ArtworkCache.shared.image(for: url, size: size) }
            // cancelled: the url changed while this one loaded (⏭ twice quickly); the newer task shows its own
            guard let ready = next, !Task.isCancelled else { return }
            // already showing it (it was in the cache when this view was made): setting it again redrew the cover with
            // an animation, for every row and tile scrolled into view
            guard ready !== image else { return }
            withAnimation(.easeInOut(duration: 0.28)) { image = ready }
        }
    }
}

/// The playing song's colour: its cover shrunk to 3×3 pixels, drawn as a mesh gradient whose inner points drift
/// slowly, like Apple Music's animated backgrounds. A new song's mesh crossfades over the old one.
/// `strength` scales it; `base` adds a material underneath (Now Playing). Still when Reduce Motion is on.
/// Still (Moving background off, the default), the mesh is drawn once per song into a small picture and Core Animation
/// crossfades the pictures: as a SwiftUI crossfade the app redrew the whole mesh on every frame for 1.1 s per song.
struct Backdrop: View {
    let track: Track?
    var strength: Double = 1
    var base: AnyShapeStyle? = nil
    /// The main window's: while Now Playing covers it, a new song's colours swap at once. Its 1.1 s crossfade, unseen,
    /// was redrawn by the app every frame and made Now Playing's blur re-blur the whole window each time
    var underNowPlaying = false
    /// Now Playing's own: kept, hidden, while Now Playing is closed, so it moves only while open.
    var inNowPlaying = false
    /// False while it is drawn invisible (the title bar's copy before the page scrolls under it): it holds still (#12:
    /// at opacity 0 it still drew 10 frames a second).
    var visible = true
    @AppStorage("animateBackdrop") private var animate = Look.animateBackdrop
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var windowState      // .inactive when another app is in front
    @Environment(\.colorScheme) private var scheme
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme
    @State private var mesh: (key: String, colors: [Color])?
    @State private var picture: (image: CGImage?, fade: Double) = (nil, 0)   // the still mesh, and its change's fade
    @State private var pictureFade = 0.0                                      // the next new mesh's fade (0: at once)
    @State private var pictureKey: String?                                     // the mesh the picture shows
    @State private var pictureFailed = false                                   // drawn empty: the mesh as before

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
        // and only while it can be seen: Now Playing's while open, the window's while Now Playing does not cover it
        let seen = inNowPlaying ? player.showNowPlaying : !(underNowPlaying && player.showNowPlaying)
        return animate && visible && seen && !reduceMotion && player.isPlaying && windowState != .inactive
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        // the nine colours as drawn: worked out when the body runs (a new song, light or dark, another strength), not
        // in the timeline below, which runs 10 times a second while the mesh moves
        let colours = mesh.map { Self.colours(of: $0.colors, dark: scheme == .dark, strength: strength, readable: inNowPlaying) }
        ZStack {
            if let base { Rectangle().fill(base) }
            if !animate && !pictureFailed {
                StillPicture(image: picture.image, fade: picture.fade)
            } else if let mesh, let colours {
                // 10 frames a second is plenty for a drift that takes ~30 s per cycle (the screen may run at 120):
                // a step moves a colour ~3 pt; each frame costs ~0.5% of a core (measured 7 Oct)
                TimelineView(DriftSchedule(interval: 1.0 / 10, paused: !moving)) { context in
                    MeshGradient(width: 3, height: 3,
                                 points: Self.points(at: moving ? context.date.timeIntervalSinceReferenceDate : 0),
                                 colors: colours.map(\.color))
                }
                .id(mesh.key)                                   // identity = the source: changing it crossfades
                .transition(.opacity)
                .opacity(strength)
            }
        }
        .ignoresSafeArea()
        .task(id: source) {
            let key = source
            // read here, not in the body: opening Now Playing must not redraw this
            let seen = !(underNowPlaying && player.showNowPlaying)
            // still: the picture fades by Core Animation (below); moving: SwiftUI crossfades the mesh, as before
            let still = !animate && !pictureFailed
            func show(_ next: (key: String, colors: [Color])?, fading seconds: Double) {
                pictureFade = seen ? seconds : 0
                if still { mesh = next } else { withAnimation(seen ? .easeInOut(duration: seconds) : nil) { mesh = next } }
            }
            if theme.mode(.background) == .system { show(nil, fading: 0.8); return }
            if theme.mode(.background) == .custom, let base = Color(hex: theme.hex(.background)) {
                show((key, Self.shades(of: base)), fading: 0.8)
                return
            }
            guard let url = track?.image else { show(nil, fading: 0.8); return }
            guard let colors = await ArtworkCache.shared.colorGrid(for: url), !Task.isCancelled else { return }   // a newer song's mesh wins
            show((key, colors), fading: 1.1)
        }
        // new colours, light or dark, or another strength (those change at once): Now Playing's text learns what it is
        // on, and the still picture is drawn again
        .task(id: [mesh?.key ?? "", scheme == .dark ? "dark" : "light", String(strength), animate ? "moving" : "still"]) {
            if inNowPlaying { NowPlayingInk.shared.show(colours ?? [], dark: scheme == .dark, strength: strength) }
            guard !animate else { return }
            let fade = mesh?.key != pictureKey ? pictureFade : 0
            pictureKey = mesh?.key
            guard let mesh, let colours else { picture = (nil, fade); return }
            if let drawn = Self.drawPicture(of: colours, strength: strength, id: "\(mesh.key)|\(scheme == .dark)|\(strength)|\(inNowPlaying)") {
                picture = (drawn, fade)
            } else {
                pictureFailed = true                         // never seen: then the SwiftUI mesh draws it, as before
            }
        }
    }

    /// The nine colours the mesh is drawn in: the source's, mixed toward black (dark) or white (light) as the strength
    /// falls and a third more colourful at full strength. That richness was `.saturation` on the drawn mesh; it is the
    /// same sum on the nine colours here (the mesh only blends them), so what is drawn is known exactly. In Now Playing
    /// (`readable`) each is then kept where its text reads (NowPlayingInk, #20).
    static func colours(of source: [Color], dark: Bool, strength: Double, readable: Bool) -> [RGB] {
        var environment = EnvironmentValues()
        environment.colorScheme = dark ? .dark : .light
        let ground = readable ? NowPlayingInk.Ground(dark: dark) : nil
        return source.map { colour in
            let mixed = colour.mix(with: dark ? .black : .white, by: 0.3 * (1 - strength)).resolve(in: environment)
            let rich = RGB(mixed).saturated(1 + 0.35 * strength)
            return ground?.kept(rich, strength: strength) ?? rich
        }
    }

    /// The still mesh as a picture, kept by `id`: exactly what the SwiftUI mesh draws, drawn once. A mesh is smooth, so
    /// 240 × 150 pixels stretched to the window look the same. nil if it came out empty.
    static func drawPicture(of colours: [RGB], strength: Double, id: String) -> CGImage? {
        if let kept = pictures[id] { return kept }                  // opening Now Playing on this song again: none drawn
        guard let image = picture(of: colours, strength: strength) else { return nil }
        // one pixel from the middle: fully clear means the renderer could not draw the mesh
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            context.draw(image, in: CGRect(x: -120, y: -75, width: 240, height: 150))
        }
        guard pixel[3] != 0 else { return nil }
        if pictures.count >= 12 { pictures.removeAll() }            // a few songs' worth (the window's and Now Playing's)
        pictures[id] = image
        return image
    }

    /// The mesh as a picture `at` a moment of its drift (0: still). The self-test measures the moving one with it too.
    static func picture(of colours: [RGB], strength: Double, at time: Double = 0, size: CGSize = CGSize(width: 240, height: 150)) -> CGImage? {
        let mesh = MeshGradient(width: 3, height: 3, points: points(at: time), colors: colours.map(\.color))
            .opacity(strength)
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: mesh)
        renderer.scale = 1
        return renderer.cgImage
    }

    /// Pictures drawn this session, by mesh, light or dark, strength, and whether Now Playing's (kept readable).
    private static var pictures: [String: CGImage] = [:]

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
    var underNowPlaying = false                                         // the main window's (see Backdrop)
    var inNowPlaying = false                                            // Now Playing's (see Backdrop)
    var visible = true                                                  // (see Backdrop)
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme

    typealias Host = PassthroughHostingView

    func makeNSView(context: Context) -> Host {
        let host = Host(rootView: content)
        host.sizingOptions = []                                         // takes the frame it is given; asks for none
        return host
    }

    func updateNSView(_ host: Host, context: Context) { host.rootView = content }

    private var content: AnyView {
        AnyView(Backdrop(track: track, strength: strength, underNowPlaying: underNowPlaying, inNowPlaying: inNowPlaying, visible: visible)
            .environment(player).environment(theme))
    }
}

// MARK: - Text that reads on the backdrop (#20)

/// A colour as three sRGB numbers from 0 to 1, as the window blends them: what the contrast sums work on.
nonisolated struct RGB: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    static let black = RGB(r: 0, g: 0, b: 0)
    static let white = RGB(r: 1, g: 1, b: 1)

    init(r: Double, g: Double, b: Double) {
        self.r = min(1, max(0, r))
        self.g = min(1, max(0, g))
        self.b = min(1, max(0, b))
    }

    /// A SwiftUI colour as resolved in light or dark (one wider than sRGB is brought inside it).
    init(_ resolved: Color.Resolved) { self.init(r: Double(resolved.red), g: Double(resolved.green), b: Double(resolved.blue)) }

    /// WCAG 2's relative luminance: 0 for black, 1 for white.
    var luminance: Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG 2's contrast ratio: 1 (the same colour) to 21 (black on white).
    func contrast(with other: RGB) -> Double {
        let (x, y) = (luminance, other.luminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `t` of the way to `other`.
    func mixed(with other: RGB, by t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }

    /// This colour drawn at `alpha` over `under`, as the window shows it.
    func over(_ under: RGB, alpha: Double) -> RGB { under.mixed(with: self, by: alpha) }

    /// Further from its grey by `amount` (1: as it is), its luma kept: what `.saturation` does.
    func saturated(_ amount: Double) -> RGB {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return RGB(r: luma + (r - luma) * amount, g: luma + (g - luma) * amount, b: luma + (b - luma) * amount)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

/// Now Playing's text, readable on its backdrop whatever the cover: light or dark mode, any colour strength (Settings ›
/// Appearance › Surfaces › Now Playing), the backdrop still or moving (#20).
///
/// The text took the system's colours, which follow only light or dark; the backdrop took the cover's. A bright cover
/// in dark mode put light text on a light background, a dark cover in light mode the opposite: the title at 1.04:1 on
/// a white cover in dark mode, 1.03:1 on a black one in light, at the default strength (NN_SELFTEST_READABLE, 16 Oct).
/// Choosing dark or light text per song would have turned Now Playing's glass, menus and controls the other way with
/// it, and still failed on a cover half bright and half dark, where neither reads everywhere. So the text keeps its colours and the backdrop is kept where they read: each of the mesh's nine
/// colours, before it is drawn, is mixed toward black (dark mode) or white (light) just far enough that every kind of
/// text reaches WCAG's AA contrast on it, as it shows (at the colour strength, over the window's colour). A colour that
/// reads already is left as it is: the cover's hue stays, only deeper or paler. The accent's text (the artists, a noted
/// lyric) is then mixed toward the text's colour until it reads on all nine. A few sums on nine colours, once per song,
/// light or dark and strength (Backdrop.colours); nothing per frame.
///
/// The levels: the system's label colour, then 70% and 50% of it where the system's are 55% and 25% (50% and 26% in
/// light mode, whose secondary text reaches 3.9:1 at best, on white), and unlit lyrics at 60% of the label where they
/// were 38% (2.7:1 on a black cover in dark mode).
@Observable
final class NowPlayingInk {
    static let shared = NowPlayingInk()

    /// Now Playing's secondary and tertiary text (RootView's NowPlayingRoot sets them for all of it).
    static let secondary = level(0.7)
    static let tertiary = level(0.5)

    /// The text's colour, white in dark mode and black in light (the label colour's own), at `alpha`, following light or
    /// dark as the system's colours do. `labelColor.withAlphaComponent` kept the mode it was made in: in dark mode it
    /// drew black text on a black cover (the self-test's pictures, 16 Oct).
    private nonisolated static func level(_ alpha: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            (appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
        }
    }
    /// WCAG 2, AA: 4.5:1 for text; 3:1 for large text (the lyrics, 24 pt extra bold) and symbols.
    static let text = 4.5
    static let large = 3.0
    /// The mesh blends its nine colours smoothly (cubically), which can overshoot them a little between the points: the
    /// nine aim this much higher, and the self-test measures every pixel against the plain targets.
    static let headroom = 1.1

    /// A kind of text: its colour, how opaque it is, and the contrast it needs.
    struct Role {
        let name: String
        let colour: RGB
        let alpha: Double
        let target: Double

        func contrast(on backdrop: RGB) -> Double { colour.over(backdrop, alpha: alpha).contrast(with: backdrop) }
    }

    /// The window's colour and every kind of text, as light or dark mode draws them.
    struct Ground {
        let dark: Bool
        let window: RGB
        let label: RGB                       // the text's colour, opaque: white in dark mode, black in light
        let roles: [Role]

        init(dark: Bool) {
            self.dark = dark
            window = Self.resolved(.windowBackgroundColor, dark: dark).colour
            let (label, alpha) = Self.resolved(.labelColor, dark: dark)
            self.label = label
            roles = [
                Role(name: "text", colour: label, alpha: alpha, target: NowPlayingInk.text),
                Role(name: "secondary text", colour: label, alpha: Self.resolved(NowPlayingInk.secondary, dark: dark).alpha,
                     target: NowPlayingInk.text),
                Role(name: "tertiary symbols", colour: label, alpha: Self.resolved(NowPlayingInk.tertiary, dark: dark).alpha,
                     target: NowPlayingInk.large),
                Role(name: "unlit lyrics", colour: label, alpha: alpha * Double(LyricLinesView.unlit), target: NowPlayingInk.large),
            ]
        }

        /// A system colour (it differs in light and dark) as light or dark mode draws it.
        static func resolved(_ colour: NSColor, dark: Bool) -> (colour: RGB, alpha: Double) {
            var out = NSColor.black
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { out = colour.usingColorSpace(.sRGB) ?? .black }
            return (RGB(r: out.redComponent, g: out.greenComponent, b: out.blueComponent), out.alphaComponent)
        }

        /// Every kind of text reads on `backdrop`, `headroom` times over.
        func reads(on backdrop: RGB, headroom: Double = 1) -> Bool {
            roles.allSatisfy { $0.contrast(on: backdrop) >= $0.target * headroom }
        }

        /// `colour`, drawn at `strength` over the window, mixed toward black (dark) or white (light) just far enough
        /// that every kind of text reads on it; as it is when it reads already.
        func kept(_ colour: RGB, strength: Double) -> RGB {
            let away = dark ? RGB.black : RGB.white
            let t = Self.least { reads(on: colour.mixed(with: away, by: $0).over(window, alpha: strength), headroom: NowPlayingInk.headroom) }
            return colour.mixed(with: away, by: t)
        }

        /// `accent` mixed toward the text's colour just far enough that it reads on each of `behind` (the window's
        /// colour when none): as text, and as faint as an unlit noted lyric.
        func readable(_ accent: RGB, on behind: [RGB]) -> RGB {
            let behind = behind.isEmpty ? [window] : behind
            let t = Self.least { amount in
                let colour = accent.mixed(with: label, by: amount)
                return behind.allSatisfy { backdrop in
                    colour.contrast(with: backdrop) >= NowPlayingInk.text * NowPlayingInk.headroom
                        && colour.over(backdrop, alpha: Double(LyricLinesView.unlit)).contrast(with: backdrop)
                            >= NowPlayingInk.large * NowPlayingInk.headroom
                }
            }
            return accent.mixed(with: label, by: t)
        }

        /// The least `t` from 0 to 1 at which `reads` holds (it holds from there on): 0 if it holds at once, else found
        /// by halving to 1/16,000.
        private static func least(_ reads: (Double) -> Bool) -> Double {
            if reads(0) { return 0 }
            var low = 0.0, high = 1.0
            for _ in 0..<14 {
                let middle = (low + high) / 2
                if reads(middle) { high = middle } else { low = middle }
            }
            return high
        }
    }

    /// The backdrop behind the text now, its nine colours as they show (none: the window's colour alone), and whether
    /// in dark mode. Now Playing's backdrop tells it (Backdrop).
    private(set) var behind: [RGB] = []
    private(set) var dark = false

    func show(_ colours: [RGB], dark: Bool, strength: Double) {
        let window = Ground(dark: dark).window
        let shown = colours.map { $0.over(window, alpha: strength) }
        if shown != behind { behind = shown }               // only what changed: everything tinted by it draws again
        if dark != self.dark { self.dark = dark }
    }

    /// The accent (nil: the Mac's own) as Now Playing's text draws it: readable on the backdrop showing now.
    func readable(_ accent: Color?, dark: Bool) -> Color {
        var environment = EnvironmentValues()
        environment.colorScheme = dark ? .dark : .light
        let colour = RGB((accent ?? .accentColor).resolve(in: environment))
        let made = Ground(dark: dark).readable(colour, on: dark == self.dark ? behind : [])
        return made == colour ? (accent ?? .accentColor) : made.color
    }
}

/// A picture that fills its frame (stretched) and crossfades to the next one with Core Animation: the render server
/// plays the fade, the app draws nothing per frame. The still background's mesh.
private struct StillPicture: NSViewRepresentable {
    let image: CGImage?
    let fade: Double                                                    // seconds; 0: at once

    func makeNSView(context: Context) -> StillPictureView { StillPictureView() }
    func updateNSView(_ view: StillPictureView, context: Context) { view.show(image, fade: fade) }
}

final class StillPictureView: NSView {
    private let picture = CALayer()
    private var shown: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        picture.contentsGravity = .resize
        layer?.addSublayer(picture)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }          // a background: clicks go through

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.frame = bounds
        CATransaction.commit()
    }

    func show(_ image: CGImage?, fade: Double) {
        guard image !== shown else { return }
        shown = image
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if fade > 0 {
            let crossfade = CATransition()
            crossfade.type = .fade
            crossfade.duration = fade
            crossfade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            picture.add(crossfade, forKey: "crossfade")
        }
        picture.contents = image
        CATransaction.commit()
    }
}

/// The cover that changes with each song: the player bar's and Now Playing's. A new cover crossfades in and, with
/// `pop`, grows into place with a soft spring; both are Core Animation, set up once per song. As SwiftUI transitions
/// the app redrew them on every frame of the change (a new song in Now Playing: ~13% of a core for a moment, 7 Oct).
/// Lists keep `ArtworkView`: their covers do not change while you look at them.
struct LiveArtwork: NSViewRepresentable {
    let url: URL?
    let size: CGFloat
    var radius: CGFloat = 8
    /// Changes with each song (its id): a new song pops even when its cover is the same (the same album).
    var song = ""
    /// Now Playing: a new song's cover grows from 94% with a soft spring (SwiftUI's transition did this before).
    var pop = false
    /// Now Playing: whether the song plays (or loads): full size with a deep shadow, else 86% with a closer one,
    /// springing between the two (`rest`). nil: always full size, no shadow (the bar's).
    var playing: Bool? = nil
    /// Asked when a new cover is ready: false swaps it at once (the bar's, while Now Playing covers it: an unseen fade
    /// still made Now Playing's blur re-blur the whole window on every frame of it).
    var fades: () -> Bool = { true }

    func makeNSView(context: Context) -> LiveArtworkView { LiveArtworkView() }

    func updateNSView(_ view: LiveArtworkView, context: Context) {
        view.radius = radius
        view.show(url, size: size, song: song, pop: pop, fades: fades)
        if let playing { view.rest(playing: playing) }
    }
}

final class LiveArtworkView: NSView {
    private let stage = CALayer()                      // Now Playing: 86% while paused, and the shadow (`rest`)
    private let base = CALayer()                       // scaled by the pop
    private let cover = CALayer()                      // the picture: rounded, clipped, a hairline edge
    private let note = CALayer()                       // the music note, before a cover loads or for a song without one
    private var url: URL?
    private var song: String?
    private var shown: CGImage?
    private var loading: Task<Void, Never>?
    private var noteSide: CGFloat = 0
    private var playing: Bool?                         // nil: no rest set (the bar's cover)
    var radius: CGFloat = 8 { didSet { if radius != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cover.masksToBounds = true
        cover.cornerCurve = .continuous
        cover.contentsGravity = .resizeAspectFill
        cover.borderWidth = 0.5
        note.contentsGravity = .center
        stage.cornerCurve = .continuous
        stage.shadowColor = NSColor.black.cgColor
        base.addSublayer(cover)
        cover.addSublayer(note)
        stage.addSublayer(base)
        layer?.addSublayer(stage)
        colours()
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loading?.cancel() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }          // inside buttons: the button takes the click

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.bounds = bounds
        stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        stage.cornerRadius = radius
        base.bounds = bounds
        base.position = CGPoint(x: bounds.midX, y: bounds.midY)
        cover.frame = base.bounds
        cover.cornerRadius = radius
        note.frame = base.bounds
        if let playing { stage.shadowPath = shadowPath(playing) }
        CATransaction.commit()
        if !note.isHidden, abs(bounds.width - noteSide) > 1 { drawNote() }   // the note's size follows the cover's
    }

    /// Now Playing: the cover's size and shadow for a playing song (full size; a deep, wide shadow) or a paused one
    /// (86%; a closer, fainter one), sprung to from wherever they are: one Core Animation spring for the size and one
    /// eased change for the shadow, played by the render server (15 Oct, as in the Windows app). The first one is set
    /// at once: Now Playing opens with the cover already at rest.
    func rest(playing: Bool) {
        guard playing != self.playing else { return }
        let first = self.playing == nil
        self.playing = playing
        if first { colours() }                                          // the window's colour under the cover
        let scale: CGFloat = playing ? 1 : 0.86
        let shadow = (opacity: Float(playing ? 0.45 : 0.3), radius: CGFloat(playing ? 16 : 9),
                      offset: CGSize(width: 0, height: playing ? -18 : -8))       // y up: a shadow below the cover
        let path = shadowPath(playing)
        let now = stage.presentation() ?? stage
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !first {
            let spring = CASpringAnimation(perceptualDuration: 0.52, bounce: 0.3)
            spring.keyPath = "transform.scale"
            spring.fromValue = now.value(forKeyPath: "transform.scale")
            spring.toValue = scale
            spring.duration = spring.settlingDuration
            stage.add(spring, forKey: "rest")
            let changes: [(String, Any?, Any?)] = [("shadowOpacity", now.shadowOpacity, shadow.opacity),
                                                  ("shadowRadius", now.shadowRadius, shadow.radius),
                                                  ("shadowOffset", NSValue(size: now.shadowOffset), NSValue(size: shadow.offset)),
                                                  ("shadowPath", now.shadowPath, path)]
            for (keyPath, from, to) in changes {
                let change = CABasicAnimation(keyPath: keyPath)
                change.fromValue = from
                change.toValue = to
                change.duration = 0.52
                change.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)   // ease out (cubic)
                stage.add(change, forKey: keyPath)
            }
        }
        stage.transform = CATransform3DMakeScale(scale, scale, 1)
        stage.shadowOpacity = shadow.opacity
        stage.shadowRadius = shadow.radius
        stage.shadowOffset = shadow.offset
        stage.shadowPath = path
        CATransaction.commit()
    }

    /// The shadow's shape: the cover's, drawn in by 2 pt playing and 6 pt paused, so its edge shows below the cover only.
    private func shadowPath(_ playing: Bool) -> CGPath {
        let inset: CGFloat = playing ? 2 : 6
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let corner = min(max(0, radius - inset), rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect.width > 0 ? rect : .zero, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }

    #if DEBUG
    /// The cover's resting size and shadow (the values it ends at), and whether any of it is still moving: for self-tests.
    var restState: (scale: CGFloat, shadowRadius: CGFloat, moving: Bool) {
        (stage.transform.m11, stage.shadowRadius, [stage, base, cover].contains { !($0.animationKeys() ?? []).isEmpty })
    }
    #endif

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colours()
        drawNote()
    }

    func show(_ url: URL?, size: CGFloat, song: String, pop: Bool, fades: @escaping () -> Bool) {
        guard url != self.url || song != self.song else { return }
        let changed = self.song != nil                                  // not the first cover this view shows
        self.url = url
        self.song = song
        loading?.cancel()
        guard let url else { set(nil, fade: false, pop: false); return }
        // a new song pops at once, even before its cover is here; the cover fades in when it is
        if pop && changed { grow() }
        if let ready = ArtworkCache.shared.cached(url, size: size) {
            set(ready, fade: changed && fades(), pop: false)
            return
        }
        loading = Task { [weak self] in
            let image = await ArtworkCache.shared.image(for: url, size: size)
            guard let self, !Task.isCancelled, let image else { return }
            self.set(image, fade: self.shown != nil && fades(), pop: false)
        }
    }

    private func set(_ image: NSImage?, fade: Bool, pop: Bool) {
        let picture = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard picture !== shown else { return }
        shown = picture
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if fade {
            let crossfade = CATransition()
            crossfade.type = .fade
            crossfade.duration = 0.28
            crossfade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cover.add(crossfade, forKey: "crossfade")
        }
        cover.contents = picture
        note.isHidden = picture != nil
        CATransaction.commit()
        if picture == nil, abs(bounds.width - noteSide) > 1 { drawNote() }
        if pop { grow() }
    }

    /// From 94% to full size with a soft spring: SwiftUI's spring(response: 0.5, dampingFraction: 0.85), as before.
    private func grow() {
        let spring = CASpringAnimation(perceptualDuration: 0.5, bounce: 0.15)
        spring.keyPath = "transform.scale"
        spring.fromValue = 0.94
        spring.toValue = 1.0
        spring.duration = spring.settlingDuration
        base.add(spring, forKey: "pop")
    }

    private func colours() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cover.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.07)).cgColor   // before a cover loads
        cover.borderColor = resolved(NSColor.labelColor.withAlphaComponent(0.08)).cgColor
        // Now Playing: the window's colour under the cover, so its shadow never shows through the see-through
        // placeholder (it did: a dark blur inside the square, CI picture, 15 Oct)
        stage.backgroundColor = playing == nil ? nil : resolved(.windowBackgroundColor).cgColor
        CATransaction.commit()
    }

    private func drawNote() {
        noteSide = bounds.width
        guard noteSide > 0 else { return }
        let config = NSImage.SymbolConfiguration(pointSize: noteSide * 0.32, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [resolved(.tertiaryLabelColor)]))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        note.contents = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        note.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    /// A dynamic colour (it differs in light and dark) as it looks in this view now.
    private func resolved(_ colour: NSColor) -> NSColor {
        var out = colour
        effectiveAppearance.performAsCurrentDrawingAppearance { out = NSColor(cgColor: colour.cgColor) ?? colour }
        return out
    }
}

/// The app's plain buttons: easy to hit, and (Settings › Appearance › Button feedback) quietly responsive.
/// The whole label and 6 pt around it take the click; with `.plain`, only the drawn pixels did, so an icon had to be
/// hit on its strokes (the close chevron, the Lyrics button; 7 Oct). Feedback: a soft highlight under the pointer and a
/// small press. `highlight: false` for covers, which get the bigger target without the highlight.
struct QuietButtonStyle: ButtonStyle {
    var highlight = true
    func makeBody(configuration: Configuration) -> some View { QuietButton(configuration: configuration, highlight: highlight) }
}

private struct QuietButton: View {
    let configuration: ButtonStyleConfiguration
    let highlight: Bool
    @AppStorage("buttonFeedback") private var feedback = Look.buttonFeedback
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .padding(6)
            .background {
                if feedback && highlight && hovering && enabled {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.08))
                }
            }
            .contentShape(.rect)                                 // every point of it clicks, not only the strokes
            .padding(-6)                                         // the layout stays as it was
            .scaleEffect(feedback && configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            // instant, not animated: any animation redraws the whole window on every frame (~5 ms each), and a
            // 0.12 s fade per hover made a pointer sweep across the bar cost 30-45% of a core (profiled 7 Oct)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
    static func quiet(highlight: Bool) -> QuietButtonStyle { QuietButtonStyle(highlight: highlight) }
}

/// An `NSHostingView` that clicks pass through: for drawings that sit inside or behind controls.
final class PassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The mark on the playing song (▶ on the others), in lists, shelves and copies. The animated SF Symbol took 22.7% of
/// a core against 2.6% still, in its own host or not (measured 7 Oct). So three equaliser bars move instead (Settings ›
/// Appearance › Moving bars, on by default): a Core Animation animation, played by macOS's render server, not redrawn
/// by the app frame by frame. Off: a still speaker.
struct PlayingSpeaker: View {
    let playing: Bool
    var font: Font? = nil
    var style: AnyShapeStyle = AnyShapeStyle(.white)
    var color: Color? = nil                      // the bars' colour (shape styles cannot reach a layer); nil: white
    @AppStorage("animatedSpeaker") private var animated = Look.animatedSpeaker
    @Environment(Player.self) private var player

    var body: some View {
        // still while Now Playing covers the lists: its blur re-blurs the whole window whenever anything under it moves
        if playing && animated && !player.showNowPlaying {
            EqualizerBars(color: NSColor(color ?? .white)).frame(width: 12, height: 11)
        } else {
            Image(systemName: playing ? "speaker.wave.2.fill" : "play.fill").font(font).foregroundStyle(style)
        }
    }
}

/// Three bars that rise and fall forever, as layer animations: set up once, then played by the render server.
struct EqualizerBars: NSViewRepresentable {
    let color: NSColor

    final class Bars: NSView {
        private let bars = (0..<3).map { _ in CALayer() }
        var color: NSColor = .white { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            for (i, bar) in bars.enumerated() {
                bar.cornerRadius = 1
                bar.anchorPoint = CGPoint(x: 0.5, y: 0)                   // grow from the bottom
                layer?.addSublayer(bar)
                let rise = CABasicAnimation(keyPath: "transform.scale.y")
                rise.fromValue = 0.3
                rise.toValue = 1.0
                rise.duration = [0.42, 0.58, 0.36][i]
                rise.autoreverses = true
                rise.repeatCount = .infinity
                rise.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // no frame-rate cap: one (30 fps, 7 Oct) was the likely reason scrolling stopped feeling smooth (macOS can
                // pace the whole window by a running animation's preferred rate). macOS plays it either way: no app cost
                bar.add(rise, forKey: "rise")
            }
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let w = bounds.width / 5
            for (i, bar) in bars.enumerated() {
                bar.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
                bar.position = CGPoint(x: w / 2 + CGFloat(i) * w * 2, y: 0)
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // inside buttons: clicks go to the button
    }

    func makeNSView(context: Context) -> Bars { Bars() }
    func updateNSView(_ view: Bars, context: Context) { view.color = color }
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

/// The explicit mark beside a title, as music apps show it.
struct ExplicitBadge: View {
    var body: some View {
        Image(systemName: "e.square.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Explicit")
            .help("Explicit")
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
        .buttonStyle(.quiet)
        .help(liked ? "Remove from Liked" : "Like")
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
/// The window's own surface: the desktop blurred behind it, under ONE wash (the window colour, plus whatever `wash`
/// adds) at ONE opacity, from Settings › Appearance. Stacked layers made the window nearly opaque before (5 Oct). The
/// main window adds the playing song's artwork; the sign-in screen adds nothing (8 Oct: it painted a solid colour, so
/// the window was opaque there and its glass sat on flat grey).
struct WindowSurface<Wash: View>: View {
    @AppStorage("windowBlur") private var windowBlur = Look.windowBlur          // 0 = clear, 1 = frosted
    @AppStorage("windowOpacity") private var windowOpacity = Look.windowOpacity // 0 = see-through, 1 = solid
    @ViewBuilder var wash: () -> Wash

    var body: some View {
        // full screen: solid. A full-screen Space has no desktop behind the window, so see-through showed black (8 Oct)
        let fullScreen = WindowMode.shared.fullScreen
        ZStack {
            ClearWindow()                                   // the window itself see-through, so the blur can be thinned
            if !fullScreen { WindowBlur(amount: windowBlur) }
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                wash()
            }
            .opacity(fullScreen ? 1 : max(windowOpacity, Look.minWindowOpacity))   // a value saved before the floor existed may be lower
        }
        .ignoresSafeArea()
    }
}

/// Whether the main window is in full screen, for what must differ there (WindowSurface, the toolbar's background).
/// Set by ClearWindow from its window's own notifications: it changes twice per full screen, so reading it costs nothing.
@Observable
final class WindowMode {
    static let shared = WindowMode()
    var fullScreen = false
}

extension WindowSurface where Wash == EmptyView {
    init() { wash = { EmptyView() } }
}

/// Apple's large-title pattern (Music, Mail): the big title belongs to the content, and the toolbar's small title
/// appears only once the big one has scrolled up under the toolbar. Both at once overlapped under the see-through
/// toolbar (8 Oct). Put it on the scroll view itself (List or ScrollView). The transform runs per scroll step but only
/// computes a Bool; SwiftUI calls the action, and redraws the toolbar, only when it flips.
struct ScrollTitle: ViewModifier {
    let title: String
    var after: CGFloat = 36                    // points scrolled before the big title is under the toolbar
    @State private var shown = false
    @Environment(\.pageCovered) private var covered

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > after } action: { _, now in
                shown = now
                publish()
            }
            .onAppear(perform: publish)
            .onChange(of: covered) { publish() }            // back from a page: this screen's title again
            .onChange(of: title) { publish() }
    }

    /// The window's title bar follows the visible screen only (TitleBarTitle reads this).
    private func publish() {
        guard !covered else { return }
        let state = TitleBarState.shared, text = shown ? title : ""
        if state.scrolled != shown { state.scrolled = shown }
        if state.title != text { state.title = text }
    }
}

extension View {
    func scrollTitle(_ title: String, after: CGFloat = 36) -> some View { modifier(ScrollTitle(title: title, after: after)) }

    /// A title shown in the toolbar at all times (a screen with no big title of its own, such as Search).
    func fixedTitle(_ title: String) -> some View { modifier(FixedTitle(title: title)) }
}

struct FixedTitle: ViewModifier {
    let title: String
    @Environment(\.pageCovered) private var covered

    func body(content: Content) -> some View {
        content
            .onAppear(perform: publish)
            .onChange(of: covered) { publish() }
            .onChange(of: title) { publish() }
    }

    private func publish() {
        guard !covered else { return }
        if TitleBarState.shared.title != title { TitleBarState.shared.title = title }
        if TitleBarState.shared.scrolled { TitleBarState.shared.scrolled = false }
    }
}

/// A sideways shelf's clip: its left and right edges only, so covers scrolled past the content column never show
/// under the sidebar or past the window's edge, while a hovered cover's lift and shadow keep the room above and below.
nonisolated struct SidewaysClip: Shape {
    var overflow: CGFloat = 40

    func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: 0, dy: -overflow)) }
}

extension View {
    /// A sideways shelf inside a page with `margin` points on each side: it runs to the content column's edges, its
    /// first and last covers line up with the page margin, and it clips only at the column's edges (SidewaysClip).
    func shelf(margin: CGFloat) -> some View {
        contentMargins(.horizontal, margin, for: .scrollContent)
            .scrollClipDisabled()
            .clipShape(SidewaysClip())
            .padding(.horizontal, -margin)
    }

    /// A page's column (15 Oct, as in the Windows app): at most `maxPageWidth` wide, centred in a wider window, so
    /// lines and shelves never stretch across a large display.
    func pageColumn() -> some View {
        frame(maxWidth: maxPageWidth).frame(maxWidth: .infinity)
    }
}

/// The widest a page grows: 1440 inside its 32 pt margins.
let maxPageWidth: CGFloat = 1504

/// Whether the visible screen has scrolled content under the title bar. Set by ScrollTitle when it flips, read by
/// TitleBarStrip. One screen is visible at a time, so one value serves the window.
@Observable
final class TitleBarState {
    static let shared = TitleBarState()
    var scrolled = false
    /// The small title in the toolbar: empty until the big one has scrolled under it.
    var title = ""
}

/// The window's own surface over the top of the content, while it scrolls under the title bar, so the small title and
/// the toolbar buttons stay readable: the window's colour and the playing cover's wash, drawn at the window's full size
/// and cut to the band under the title bar, so its pixels are the window's. A blur's material tinted it grey, and a
/// wash drawn at the band's own height squeezed the window's gradient into it (a dark smear along its edge). Its fade
/// in and out is the only animation; nothing redraws while it shows.
struct TitleBarStrip: View {
    let track: Track?
    let strength: Double
    let band: CGFloat                          // the title bar's height: solid to here, then a short fade
    @AppStorage("windowOpacity") private var windowOpacity = Look.windowOpacity

    var body: some View {
        let shown = TitleBarState.shared.scrolled && !WindowMode.shared.fullScreen
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            IsolatedBackdrop(track: track, strength: strength, underNowPlaying: true, visible: shown)
        }
        // a little more solid than the window, so text under the title bar does not show through it
        .opacity(shown ? max(windowOpacity, 0.85) : 0)
        .mask {
            GeometryReader { geo in
                let height = max(geo.size.height, 1)
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: min(1, band / height)),
                                       .init(color: .clear, location: min(1, (band + 18) / height))],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown)
    }
}

struct ClearWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            // full screen: the window opaque, in its own colour. A full-screen Space has no desktop behind the window:
            // every see-through pixel showed black, the toolbar's strip most of all (8 Oct). Switched as full screen
            // begins and back once it has ended, so neither animation shows black either
            // once entered, the window's own state is read again
            let changes: [(Notification.Name, Bool?)] = [(NSWindow.willEnterFullScreenNotification, true),
                                                         (NSWindow.didEnterFullScreenNotification, nil),
                                                         (NSWindow.didExitFullScreenNotification, false)]
            observers = changes.map { name, full in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.show(fullScreen: full ?? window.styleMask.contains(.fullScreen))
                    }
                }
            }
            show(fullScreen: window.styleMask.contains(.fullScreen))
            // No "restore windows" snapshots: AppKit kept compressing (zlib) and encrypting an image of the window to
            // disk, the biggest steady CPU cost while playing (profiled 7 Oct). Its size and place are still kept,
            // by frame autosave (a few numbers in the app's settings).
            window.isRestorable = false
            window.setFrameAutosaveName("NoNonsense main window")
            #if DEBUG
            SelfTest.keepOutOfSight(window)
            #endif
        }

        private func show(fullScreen: Bool) {
            guard let window else { return }
            window.isOpaque = fullScreen
            window.backgroundColor = fullScreen ? .windowBackgroundColor : .clear
            if WindowMode.shared.fullScreen != fullScreen { WindowMode.shared.fullScreen = fullScreen }
        }
    }
}

/// The player bar's mute button and slider. The speaker's waves follow the level (an SF Symbols "variable value").
/// A narrow bar gives up the whole control, not only the slider (PlayerBar).
struct VolumeControl: View {
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
            .buttonStyle(.quiet)
            .foregroundStyle(.secondary)
            .help(player.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")

            Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.small)
                .tint(theme.color(.volume))                    // Settings › Colours › Volume
                .frame(width: 84)
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

/// How far a SwiftUI ScrollView may stretch past its edges (the rubber band), which SwiftUI has no modifier for on
/// macOS: `scrollBounceBehavior(.basedOnSize)` stops it only while the content fits. Put it behind the scroll view's
/// content (`.background(ScrollElasticity(...))`): it finds the AppKit scroll view that draws it. Takes no clicks.
struct ScrollElasticity: NSViewRepresentable {
    var vertical: NSScrollView.Elasticity = .automatic
    var horizontal: NSScrollView.Elasticity = .automatic

    func makeNSView(context: Context) -> ScrollElasticityView { ScrollElasticityView() }

    func updateNSView(_ view: ScrollElasticityView, context: Context) {
        view.vertical = vertical
        view.horizontal = horizontal
        view.apply()
    }
}

final class ScrollElasticityView: NSView {
    var vertical: NSScrollView.Elasticity = .automatic
    var horizontal: NSScrollView.Elasticity = .automatic

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    /// Now, and once more after SwiftUI's own update of the scroll view, which may set it back
    func apply() {
        set()
        Task { @MainActor [weak self] in self?.set() }      // runs after the current update, on the main thread
    }

    private func set() {
        guard let scroll = enclosingScrollView else { return }
        if scroll.verticalScrollElasticity != vertical { scroll.verticalScrollElasticity = vertical }
        if scroll.horizontalScrollElasticity != horizontal { scroll.horizontalScrollElasticity = horizontal }
    }
}

/// A list you reorder by dragging a row: it lifts and follows the pointer, the rows it passes slide aside to make
/// room, and it settles where you let go. A plain stack and one drag gesture per row, not List's drag and drop: inside
/// Now Playing's own host the drop never reached `onMove` (the row went back, 7 Oct; Apple's forums report the same
/// for a list in a popover), and a Mac list only draws an insertion line, never the rows making room.
/// Costs nothing until you drag. While you drag, the lifted row follows the pointer and the others move only when the
/// place it would land changes. Rows have one height (`rowHeight`): the drag counts places in it.
struct ReorderableStack<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let rowHeight: CGFloat
    /// The row at `from` goes to `to`: both are places in `items`, `to` the row's place once moved.
    let move: (_ from: Int, _ to: Int) -> Void
    @ViewBuilder let row: (Item, Int) -> Row
    /// Rows that stay where they are (Up Next's Autoplay heading); the others can still be dropped past them.
    var canDrag: (Item) -> Bool = { _ in true }
    @AppStorage("haptics") private var haptics = true
    @State private var dragged: Item.ID?
    @State private var from = 0
    @State private var travel: CGFloat = 0                 // how far the lifted row has been dragged, in points

    /// Where the lifted row would land if you let go now.
    private var target: Int {
        guard dragged != nil, !items.isEmpty else { return from }
        return min(max(0, from + Int((travel / rowHeight).rounded())), items.count - 1)
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                let lifted = item.id == dragged
                row(item, i)
                    .frame(height: rowHeight)
                    .scaleEffect(lifted ? 1.03 : 1)
                    .shadow(color: .black.opacity(lifted ? 0.2 : 0), radius: lifted ? 10 : 0, y: lifted ? 4 : 0)
                    .offset(y: lifted ? travel : shift(i))
                    // the lifted row follows the pointer at once; the others glide aside
                    .animation(lifted ? nil : Animation.snappy(duration: 0.22), value: shift(i))
                    .zIndex(lifted ? 1 : 0)
                    .gesture(drag(item.id, at: i), including: canDrag(item) ? .all : .subviews)
                    .accessibilityAction(named: "Move Up") { if i > 0 { move(i, i - 1) } }
                    .accessibilityAction(named: "Move Down") { if i < items.count - 1 { move(i, i + 1) } }
            }
        }
        // a light tick for each place the row passes (Force Touch trackpads; Settings › Trackpad › Haptic ticks)
        .sensoryFeedback(.levelChange, trigger: target) { _, _ in haptics && dragged != nil }
    }

    /// How far a row that is not lifted moves aside: one row up or down while the lifted one is past it.
    private func shift(_ i: Int) -> CGFloat {
        guard dragged != nil else { return 0 }
        let to = target
        if from < to, i > from, i <= to { return -rowHeight }
        if from > to, i < from, i >= to { return rowHeight }
        return 0
    }

    private func drag(_ id: Item.ID, at i: Int) -> some Gesture {
        // in the window's coordinates: in the row's own, which moves with the drag, the distance would feed back on itself
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if dragged == nil { dragged = id; from = i }
                travel = value.translation.height
            }
            .onEnded { _ in
                let (start, end) = (from, target)
                // one animation: the lifted row settles into its new place, the others stay where they slid
                withAnimation(.snappy(duration: 0.25)) {
                    if end != start { move(start, end) }
                    dragged = nil
                    travel = 0
                }
            }
    }
}
