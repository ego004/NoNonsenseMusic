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
        return animate && seen && !reduceMotion && player.isPlaying && windowState != .inactive
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var body: some View {
        ZStack {
            if let base { Rectangle().fill(base) }
            if !animate && !pictureFailed {
                StillPicture(image: picture.image, fade: picture.fade)
            } else if let mesh {
                // 10 frames a second is plenty for a drift that takes ~30 s per cycle (the screen may run at 120):
                // a step moves a colour ~3 pt; each frame costs ~0.5% of a core (measured 7 Oct)
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
        // the still picture: drawn again for new colours, light or dark, or another strength (those change at once)
        .task(id: [mesh?.key ?? "", scheme == .dark ? "dark" : "light", String(strength), animate ? "moving" : "still"]) {
            guard !animate else { return }
            let fade = mesh?.key != pictureKey ? pictureFade : 0
            pictureKey = mesh?.key
            guard let mesh else { picture = (nil, fade); return }
            if let drawn = Self.drawPicture(of: mesh.colors, dark: scheme == .dark, strength: strength, key: mesh.key) {
                picture = (drawn, fade)
            } else {
                pictureFailed = true                         // never seen: then the SwiftUI mesh draws it, as before
            }
        }
    }

    /// The still mesh as a picture: exactly what the SwiftUI mesh draws (the same points, mix, saturation and strength),
    /// drawn once. A mesh is smooth, so 240 × 150 pixels stretched to the window look the same. nil if it came out empty.
    static func drawPicture(of colors: [Color], dark: Bool, strength: Double, key: String) -> CGImage? {
        let id = "\(key)|\(dark)|\(strength)"
        if let kept = pictures[id] { return kept }                  // opening Now Playing on this song again: none drawn
        let mesh = MeshGradient(width: 3, height: 3, points: points(at: 0),
                                colors: colors.map { $0.mix(with: dark ? .black : .white, by: 0.3 * (1 - strength)) })
            .saturation(1 + 0.35 * strength)
            .opacity(strength)
            .frame(width: 240, height: 150)
        let renderer = ImageRenderer(content: mesh)
        renderer.scale = 1
        guard let image = renderer.cgImage else { return nil }
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

    /// Pictures drawn this session, by mesh, light or dark, and strength.
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
        AnyView(Backdrop(track: track, strength: strength, underNowPlaying: underNowPlaying, inNowPlaying: inNowPlaying)
            .environment(player).environment(theme))
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
    /// Asked when a new cover is ready: false swaps it at once (the bar's, while Now Playing covers it: an unseen fade
    /// still made Now Playing's blur re-blur the whole window on every frame of it).
    var fades: () -> Bool = { true }

    func makeNSView(context: Context) -> LiveArtworkView { LiveArtworkView() }

    func updateNSView(_ view: LiveArtworkView, context: Context) {
        view.radius = radius
        view.show(url, size: size, song: song, pop: pop, fades: fades)
    }
}

final class LiveArtworkView: NSView {
    private let base = CALayer()                       // scaled by the pop
    private let cover = CALayer()                      // the picture: rounded, clipped, a hairline edge
    private let note = CALayer()                       // the music note, before a cover loads or for a song without one
    private var url: URL?
    private var song: String?
    private var shown: CGImage?
    private var loading: Task<Void, Never>?
    private var noteSide: CGFloat = 0
    var radius: CGFloat = 8 { didSet { if radius != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        cover.masksToBounds = true
        cover.cornerCurve = .continuous
        cover.contentsGravity = .resizeAspectFill
        cover.borderWidth = 0.5
        note.contentsGravity = .center
        base.addSublayer(cover)
        cover.addSublayer(note)
        layer?.addSublayer(base)
        colours()
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { loading?.cancel() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }          // inside buttons: the button takes the click

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        base.bounds = bounds
        base.position = CGPoint(x: bounds.midX, y: bounds.midY)
        cover.frame = base.bounds
        cover.cornerRadius = radius
        note.frame = base.bounds
        CATransaction.commit()
        if !note.isHidden, abs(bounds.width - noteSide) > 1 { drawNote() }   // the note's size follows the cover's
    }

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
struct ClearWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Finder() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Finder: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            // No "restore windows" snapshots: AppKit kept compressing (zlib) and encrypting an image of the window to
            // disk, the biggest steady CPU cost while playing (profiled 7 Oct). Its size and place are still kept,
            // by frame autosave (a few numbers in the app's settings).
            window.isRestorable = false
            window.setFrameAutosaveName("NoNonsense main window")
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
            .buttonStyle(.quiet)
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["NN_DEBUG_NO_ELASTICITY"] != nil { return }   // experiment: SwiftUI's own
        #endif
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
                    .gesture(drag(item.id, at: i))
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
