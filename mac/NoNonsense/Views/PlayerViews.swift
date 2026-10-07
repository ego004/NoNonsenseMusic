import SwiftUI

/// The floating Liquid Glass capsule at the bottom of the window. Hidden until something plays.
struct PlayerBar: View {
    var glass: Namespace.ID
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme

    @AppStorage("nowPlayingPanel") private var panelRaw = NowPlayingPanel.upNext.rawValue
    @AppStorage("barStyle") private var barStyle = BarStyle.glass        // Settings › Appearance › Surfaces › Player bar
    @AppStorage("barBlur") private var barBlur = Look.barBlur
    @AppStorage("barSolid") private var barSolid = Look.barSolid

    /// A rounded rectangle, not a capsule: the middle is two rows tall now, and a capsule's round ends crowded the cover.
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    /// Opens Now Playing with this panel beside the song (`.none`: the song alone, the centre of attention).
    private func open(_ panel: NowPlayingPanel, symbol: String, help: String) -> some View {
        Button {
            panelRaw = panel.rawValue
            player.showNowPlaying = true
        } label: {
            Image(systemName: symbol).font(.title3)
        }
        .buttonStyle(.quiet)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Settings › Colours › Player bar: the glass itself, tinted; System leaves it clear.
    private var barGlass: Glass {
        // not .interactive(): the bar is not a button, and the glass reacting to the pointer redrew it on every move.
        // Its buttons keep their own feedback (QuietButtonStyle)
        if let tint = theme.color(.playerBar) { .regular.tint(tint.opacity(0.35)) } else { .regular }
    }

    var body: some View {
        if let track = player.current {
            PlayerBarLayout {
                // the song
                HStack(spacing: 12) {
                    Button { player.showNowPlaying = true } label: {
                        LiveArtwork(url: track.image, size: 48, radius: 10, fades: { [player] in !player.showNowPlaying })
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.quiet(highlight: false))
                    .help("Open Now Playing (⇧⌘F)")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(track.title).textStyle(.callout, weight: .semibold).lineLimit(1)
                            if track.isExplicit { ExplicitBadge() }
                        }
                        Text(track.artistLine).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .selfTestFrame("bar.song")

                // ⏮ ▶ ⏭, and under them the progress line with the time on each side. It used to be a stripe
                // along the bar's curved bottom edge, which looked stuck on (6 Oct).
                VStack(spacing: 2) {
                    TransportControls(size: .title3, playSize: .title)
                        .fixedSize()
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SelfTest.controlsFrame = $0 }
                        #endif
                    // the line and the times, drawn by Core Animation: this body no longer reads the position at all
                    PlaybackTimeline(underNowPlaying: true)
                        .selfTestFrame("bar.progress")
                }
                .selfTestFrame("bar.centre")

                // the buttons; in a narrow window the volume slider goes first (the speaker still mutes)
                ViewThatFits(in: .horizontal) {
                    buttons(track, volumeSlider: true)
                    buttons(track, volumeSlider: false)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .selfTestFrame("bar.buttons")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background { fill }
            .glassEffect(barStyle == .glass ? barGlass : .identity, in: shape)
            .glassEffectID("bar", in: glass)
            .glassEffectTransition(.materialize)
            .frame(maxWidth: 900)
            .selfTestFrame("bar")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { player.barFrame = $0 }
            .simultaneousGesture(MagnifyGesture().onEnded { if $0.magnification > 1.15 { player.showNowPlaying = true } })
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
    }

    private func buttons(_ track: Track, volumeSlider: Bool) -> some View {
        HStack(spacing: 14) {
            VolumeControl(width: 76, slider: volumeSlider)
            LikeButton(track: track, font: .title3)
            open(.lyrics, symbol: "quote.bubble", help: "Lyrics")
            open(.upNext, symbol: "list.bullet", help: "Up Next")
            open(.none, symbol: "arrow.up.left.and.arrow.down.right", help: "Now Playing (⇧⌘F)")
        }
        .fixedSize()
    }

    /// Settings › Appearance › Surfaces › Player bar. Liquid Glass: an optional fill over the glass (0 = the glass
    /// alone). Frosted: a blur of what is under the bar, the fill, and the Colours tint, with a hairline edge.
    @ViewBuilder private var fill: some View {
        switch barStyle {
        case .glass:
            if barSolid > 0.001 { shape.fill(Color(nsColor: .windowBackgroundColor).opacity(barSolid)) }
        case .frosted:
            ZStack {
                SurfaceLayer(blur: barBlur, solid: Look.readable(solid: barSolid, blur: barBlur), blending: .withinWindow)
                if let tint = theme.color(.playerBar) { tint.opacity(0.25) }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
        }
    }
}

/// The bar's three parts: the song on the left, the controls in the exact centre, the buttons on the right.
/// The centre gets what the sides leave (within `centre`); both sides always get the same width, so the centre
/// is the bar's centre whatever the song's title is. The buttons are measured at their full size, so in a
/// narrow window the centre shrinks to its minimum before the buttons give up the volume slider.
struct PlayerBarLayout: Layout {
    var spacing: CGFloat = 16
    var centre: ClosedRange<CGFloat> = 280...480

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 860, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let buttons = subviews[2].sizeThatFits(.unspecified).width
        let middle = min(centre.upperBound, max(centre.lowerBound, bounds.width - 2 * (buttons + spacing)))
        let side = max(0, (bounds.width - middle) / 2 - spacing)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: side, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: middle, height: bounds.height))
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing,
                          proposal: ProposedViewSize(width: side, height: bounds.height))
    }
}

/// ⏮ ▶ ⏭, shared by the bar and Now Playing.
struct TransportControls: View {
    var size: Font = .title3
    var playSize: Font = .title
    var spinnerSize: ControlSize = .small
    var modeSize: Font = .body
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme

    /// Settings › Colours › Buttons; System is your Mac's accent.
    private var active: Color { theme.color(.buttons) ?? .accentColor }

    var body: some View {
        HStack(spacing: 22) {
            // shuffle and repeat are the same width, one on each side: ▶ stays at the exact centre
            Button { withAnimation(.snappy(duration: 0.25)) { player.toggleShuffle() } } label: {
                Image(systemName: "shuffle")
                    .font(modeSize.weight(.semibold))
                    .foregroundStyle(player.isShuffled ? AnyShapeStyle(active) : AnyShapeStyle(.secondary))
                    .symbolEffect(.bounce, value: player.isShuffled)
                    .frame(width: 30, height: 30)
                    .background { if player.isShuffled { Circle().fill(active.opacity(0.16)).transition(.scale.combined(with: .opacity)) } }
                    .contentShape(.circle)
            }
            .help(player.isShuffled ? "Shuffle is on (⌘S)" : "Shuffle (⌘S)")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffled ? "On" : "Off")

            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(size).symbolEffect(.bounce.byLayer, value: player.previousPresses)
            }
                .help("Previous (⌘←)")
                .accessibilityLabel("Previous")
            Button { player.togglePlayPause() } label: {
                // while a song loads (up to ~3 s for YouTube) the button is a spinner, so you know it is coming
                ZStack {
                    if player.isBuffering {
                        ProgressView().controlSize(spinnerSize)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(playSize)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 34, height: 34)
            }
            .help("Play / Pause (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(size).symbolEffect(.bounce.byLayer, value: player.nextPresses)
            }
                .help("Next (⌘→)")
                .accessibilityLabel("Next")

            Button { withAnimation(.snappy(duration: 0.25)) { player.cycleRepeat() } } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(modeSize.weight(.semibold))
                    .foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(active))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
                    .background { if player.repeatMode != .off { Circle().fill(active.opacity(0.16)).transition(.scale.combined(with: .opacity)) } }
                    .contentShape(.circle)
            }
            .help(player.repeatMode.help)
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode.label)
        }
        .buttonStyle(.quiet)
    }
}

/// What sits beside the artwork in Now Playing: Up Next, Lyrics (MUS-12), or nothing (the song alone, centred).
enum NowPlayingPanel: String {
    case upNext, lyrics, none
}

/// Full-window Now Playing: huge artwork (as Jon Hicks asked Apple for), blended background, and a side panel
/// for Up Next or Lyrics. Click the active panel's button again and the panel goes: the artwork grows into the
/// centre. The panel you chose is remembered. Esc or a pinch in closes it; the corner button goes full screen.
struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @AppStorage("nowPlayingPanel") private var panelRaw = NowPlayingPanel.upNext.rawValue
    @AppStorage("nowPlayingBlur") private var surfaceBlur = Look.nowPlayingBlur        // Settings › Appearance › Surfaces › Now Playing
    @AppStorage("nowPlayingSolid") private var surfaceSolid = Look.nowPlayingSolid
    @AppStorage("nowPlayingColour") private var colourStrength = Look.nowPlayingColour
    @Environment(ThemeStore.self) private var theme
    @State private var isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
    private var glow: Color? { theme.color(.playing) }    // the light under the artwork: Settings › Colours › Playing song
    private var panel: NowPlayingPanel { NowPlayingPanel(rawValue: panelRaw) ?? .upNext }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // a blur and the window's colour hide the screen below; the artwork's wash goes on top of them
                ZStack {
                    SurfaceLayer(blur: surfaceBlur, solid: Look.readable(solid: surfaceSolid, blur: surfaceBlur), blending: .withinWindow)
                        .selfTestFrame("nowPlaying.surface")
                    IsolatedBackdrop(track: player.current, strength: colourStrength, inNowPlaying: true)
                }
                .ignoresSafeArea()

                if let track = player.current {
                    // the cover gets the height left after the top bar (~84 pt) and the controls under it (~250 pt);
                    // a share of the height alone let it reach the close button in a 760 pt window (6 Oct).
                    // Alone, the song takes the centre: a bigger cover
                    let room = max(160, geo.size.height - 340)
                    let side = panel == .none ? min(room, geo.size.width * 0.5, 640)
                                              : min(room, geo.size.width * 0.42, 560)
                    HStack(alignment: .center, spacing: 48) {
                        songColumn(track, side: side)
                        if panel != .none {
                            sidePanel
                                .frame(width: 340)
                                .frame(maxHeight: side + 180)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // no SwiftUI animation keyed on the song: it redrew the column on every frame of the change. The
                    // cover's crossfade and spring are Core Animation (LiveArtwork); the titles change at once
                }

                topBar
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: panelRaw)
        .simultaneousGesture(MagnifyGesture().onEnded { if $0.magnification < 0.85 { player.showNowPlaying = false } })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
    }

    private func songColumn(_ track: Track, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            LiveArtwork(url: track.image, size: side, radius: 18, song: track.id, pop: true)
                .frame(width: side, height: side)
                // the cover lights the space under it in its own colour: cast by a still shape behind it, so the
                // cover's own changes never make the shadow draw again
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))      // what shows under a cover still loading
                        .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.28 : 0.55), radius: 50, y: 24)
                }
            VStack(alignment: .leading, spacing: 6) {
                if let from = player.playingFrom {
                    Label("From “\(from)”", systemImage: "music.note.list")
                        .textStyle(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(track.title).textStyle(.title, weight: .bold).lineLimit(2)
                    if track.isExplicit { ExplicitBadge().font(.body) }
                    Spacer()
                    LikeButton(track: track, font: .title2)
                }
                Text(track.artistLine).textStyle(.title3).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: side)
            // Core Animation draws the line and the times (PlaybackTimeline): this view no longer reads the position
            PlaybackTimeline(thickness: 5, textStyle: .caption, timesBelow: true)
                .frame(width: side)
            TransportControls(size: .title, playSize: .system(size: 44), spinnerSize: .regular, modeSize: .title3)
                .frame(width: side)
            HStack(spacing: 10) {                     // like Apple Music: quiet speaker, slider, loud speaker
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }),
                       in: 0...1)
                    .tint(theme.color(.volume))
                    .accessibilityLabel("Volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(width: side * 0.7)
            .frame(width: side)
        }
    }

    /// Up Next and Lyrics, both built once and kept, behind one glass: switching fades one out and the other in.
    /// Built at the switch, the new panel (a whole list, or every lyric line) was made during the animation, and two
    /// glass panels crossfaded over each other: the switch dropped frames (7 Oct). The hidden one takes no clicks, and
    /// the one showing is on top: Lyrics, hidden above Up Next, kept its lines' AppKit view in the way of every drag and
    /// scroll (allowsHitTesting is SwiftUI's and does not reach for sure into an AppKit view), so Up Next could not be
    /// reordered once Lyrics had been opened (audit, 7 Oct).
    private var sidePanel: some View {
        ZStack {
            UpNextView()
                .opacity(panel == .upNext ? 1 : 0)
                .allowsHitTesting(panel == .upNext)
                .accessibilityHidden(panel != .upNext)
                .zIndex(panel == .upNext ? 1 : 0)
            LyricsPanel(shown: panel == .lyrics)
                .opacity(panel == .lyrics ? 1 : 0)
                .allowsHitTesting(panel == .lyrics)
                .accessibilityHidden(panel != .lyrics)
                .zIndex(panel == .lyrics ? 1 : 0)
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    /// Close on the left; on the right, the panel buttons and full screen. All glass, all with tooltips.
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { player.showNowPlaying = false } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 36, height: 36)
            }
            .buttonStyle(.quiet)
            .glassEffect(.regular.interactive(), in: .circle)
            .keyboardShortcut(.cancelAction)                      // Esc closes, and so does a pinch in
            .help("Close (Esc)")
            Spacer()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    panelButton(.lyrics, symbol: "quote.bubble", title: "Lyrics")
                    panelButton(.upNext, symbol: "list.bullet", title: "Up Next")
                    Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                        Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.body.weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.quiet)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help(isFullScreen ? "Exit Full Screen (⌃⌘F)" : "Full Screen (⌃⌘F)")
                }
            }
        }
        .padding(24)
    }

    /// Shows its panel; pressed again while showing, hides it (the song alone, centred).
    private func panelButton(_ which: NowPlayingPanel, symbol: String, title: String) -> some View {
        let on = panel == which
        let accent = theme.color(.buttons) ?? .accentColor
        return Button { panelRaw = (on ? NowPlayingPanel.none : which).rawValue } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(on ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.quiet)
        .glassEffect(on ? .regular.tint(accent.opacity(0.25)).interactive() : .regular.interactive(), in: .circle)
        .help(on ? "Hide \(title)" : "Show \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(on ? "Showing" : "Hidden")
    }
}

/// Now Playing's Lyrics (MUS-12). Timed lyrics: the line being sung is lit and kept in the middle; click any line
/// to jump there. Scroll to look around: following stops for a few seconds, then picks up again. Plain lyrics
/// (no times) simply scroll. Asks the server once per song (LyricsStore); "Couldn't find lyrics" when nobody has them.
struct LyricsPanel: View {
    /// The panel showing (not hidden behind Up Next): lyrics are asked for only then.
    var shown = true
    @Environment(Player.self) private var player
    @Environment(LyricsStore.self) private var lyrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let track = player.current {
                let state = lyrics.state(for: track)
                header(state)
                content(state, track: track)
                    // a no-op when the song start already asked. Only while this panel shows in an open Now Playing
                    // (both are kept, hidden, between uses), so Settings › Lyrics › "Only when I open Lyrics" still
                    // means that
                    .task(id: [track.id, shown && player.showNowPlaying ? "open" : "closed"]) {
                        if shown && player.showNowPlaying { lyrics.fetch(track) }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .selfTestFrame("lyrics.panel")              // the glass is Now Playing's, shared with Up Next
    }

    private func header(_ state: LyricsStore.State?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Lyrics").textStyle(.headline)
            Spacer()
            if case .found(let found) = state, let source = found.sourceName {
                Text(found.synced ? "from \(source)" : "from \(source) · not timed")
                    .textStyle(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
    }

    @ViewBuilder private func content(_ state: LyricsStore.State?, track: Track) -> some View {
        switch state {
        case .found(let found) where found.lines.isEmpty:
            message("Couldn't find lyrics", symbol: "quote.bubble", shown: "none")
        case .found(let found) where found.synced:
            // the playing line, known before the panel is drawn: it opens there instead of scrolling to it.
            // One view per song: with the next song's lyrics already fetched, the view was kept across the change, and
            // its running task went on lighting lines by the previous song's times (audit, 7 Oct)
            TimedLyricsView(lyrics: found, startLine: found.line(at: player.livePosition + 0.1), active: shown)
                .id(track.id)
        case .found(let found):
            PlainLyricsView(lyrics: found)
        case .unreachable:
            message("Couldn't reach the server", symbol: "wifi.exclamationmark", shown: "unreachable") {
                Button("Try Again") { lyrics.fetch(track) }
            }
        case .loading, nil:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Finding lyrics…").textStyle(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .selfTestShown("loading")
        }
    }

    private func message(_ text: String, symbol: String, shown: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(text).textStyle(.callout).foregroundStyle(.secondary)
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .selfTestShown(shown)
    }
}

/// Timed lyrics: lit line, kept in the middle, click to seek. The light moves only when a line changes: a task
/// sleeps until the next line is due (reading the player's live position), and anything that moves the clock starts
/// it again. A 10-a-second timer cost 14% of a core more than Up Next (6 Oct); a half-second check cost a wake twice a
/// second for nothing (audit, 7 Oct): now one wake per line. The lines themselves are Core Animation layers
/// (LyricLinesView): a line change was a SwiftUI scroll and fade, redrawn by the app up to 120 times a second for the
/// whole change; with a line every second or so that never stopped: 30–40% of a core (measured 7 Oct, Fake_Opps).
private struct TimedLyricsView: View {
    let lyrics: Lyrics
    @Environment(Player.self) private var player
    @Environment(\.textScale) private var textScale
    @AppStorage("lyricsMotion") private var motion = Look.lyricsMotion       // seconds per line change (Settings › Lyrics)
    @AppStorage("buttonFeedback") private var feedback = Look.buttonFeedback  // the highlight under the pointer
    @State private var current: Int?
    let active: Bool                                   // false while hidden behind Up Next: the lines ignore the mouse

    init(lyrics: Lyrics, startLine: Int?, active: Bool = true) {
        self.lyrics = lyrics
        self.active = active
        _current = State(initialValue: startLine)
    }

    var body: some View {
        LyricLines(lines: lyrics.lines, current: current, motion: motion, fontSize: 21 * textScale, feedback: feedback,
                   active: active) {
            jump(to: $0)
        }
        // starts again on play, pause, a stall and its end (`position` is re-anchored) and every seek: the sleep
        // below is never left counting from an old time
        .task(id: [player.isPlaying && !player.isBuffering ? 1.0 : 0.0, player.position, Double(player.seeks)]) {
            await follow()
        }
        #if DEBUG
        .onChange(of: current, initial: true) { _, line in SelfTest.lyricsCurrent = line }
        .onAppear { SelfTest.lyricsJump = { jump(to: $0) } }              // the click, when a click cannot reach
        #endif
    }

    /// Lights the line, then, while the song plays, sleeps until the next line is due. Nothing runs between lines.
    private func follow() async {
        while !Task.isCancelled {
            let now = light()
            guard player.isPlaying, !player.isBuffering else { return }   // paused or stalled: the clock is still
            let next = (current ?? -1) + 1
            guard next < lyrics.lines.count else { return }               // the last line is lit: nothing left to wait for
            let due = Double(lyrics.lines[next].startMs ?? 0) / 1000 - now
            try? await Task.sleep(for: .seconds(max(due, 0.02)))
        }
    }

    /// Lights the line being sung now (a tenth of a second early: the light lands with the voice). Returns the time used.
    @discardableResult private func light() -> Double {
        let now = (player.isPlaying ? player.livePosition : player.position) + 0.1
        let line = lyrics.line(at: now)
        if line != current { current = line }
        return now
    }

    /// Click a line: play from where it starts.
    private func jump(to index: Int) {
        guard lyrics.lines.indices.contains(index), let ms = lyrics.lines[index].startMs else { return }
        player.seek(to: Double(ms) / 1000)
        if !player.isPlaying { player.togglePlayPause() }
    }
}

/// The timed lines, as a view SwiftUI hands to AppKit.
private struct LyricLines: NSViewRepresentable {
    let lines: [LyricLine]
    let current: Int?                                              // nil: before the first line
    let motion: Double
    let fontSize: CGFloat
    let feedback: Bool
    let active: Bool
    let jump: (Int) -> Void

    func makeNSView(context: Context) -> LyricLinesView { LyricLinesView() }

    func updateNSView(_ view: LyricLinesView, context: Context) {
        view.active = active
        view.update(lines: lines, current: current, motion: motion, fontSize: fontSize, feedback: feedback, jump: jump)
    }
}

/// One text layer per line, all inside one `strip` layer. A line change sets where the strip and two opacities end
/// up, once; macOS's render server plays the movement (as for the progress line): the app does nothing per frame.
/// Scroll to look around (following stops for 4 s); click a line to play from it; the lines clip at the panel's edge.
final class LyricLinesView: NSView {
    private let strip = CALayer()                  // every line; moved as one to bring the lit line to the middle
    private let hover = CALayer()                  // Button feedback: a soft highlight under the line the pointer is on
    private var texts: [CATextLayer] = []
    private var strings: [NSAttributedString] = []    // each line's text, given to its layer when it first nears the view
    private var filled: [Bool] = []
    private var tops: [CGFloat] = []               // each line's top, measured down from the strip's top
    private var heights: [CGFloat] = []
    private var lines: [LyricLine] = []
    private var current: Int?
    private var motion = Look.lyricsMotion
    private var fontSize: CGFloat = 21
    private var feedback = true
    private var jump: (Int) -> Void = { _ in }
    private var offset: CGFloat = 0                // how far the strip's top sits above the view's top (a scroll offset)
    private var followAgainAt = Date.distantPast   // you scrolled: the light is followed again after this
    private var builtWidth: CGFloat = -1
    private var builtScale: CGFloat = 0
    private var builtDark = false
    private var pressed: Int?
    private var hovered: Int?

    private static let spacing: CGFloat = 14
    private static let inset: CGFloat = 20
    private static let unlit: Float = 0.38         // one colour, faded: switching primary/secondary snapped (7 Oct)
    private static let introGap: CGFloat = 140     // before the first line: it sits this far below the top

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        strip.anchorPoint = CGPoint(x: 0, y: 1)                     // placed by its top-left corner
        hover.cornerRadius = 8
        hover.isHidden = true
        strip.addSublayer(hover)
        layer?.addSublayer(strip)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(lines: [LyricLine], current: Int?, motion: Double, fontSize: CGFloat, feedback: Bool, jump: @escaping (Int) -> Void) {
        self.motion = motion
        self.feedback = feedback
        self.jump = jump
        if lines != self.lines || fontSize != self.fontSize {
            self.lines = lines
            self.fontSize = fontSize
            self.current = current
            build()                                                 // other text: the layers again, placed at once
            return
        }
        guard current != self.current else { return }
        let old = self.current
        self.current = current
        light(from: old)
    }

    // MARK: layout

    /// The layers for every line, measured for this width, placed with no animation. A layer gets its text (and draws
    /// it) only when its line first comes near the view (`fill`): drawn all at once, ~100 lines were ~24 MB of pictures,
    /// most never seen, all drawn while Now Playing opened.
    private func build() {
        let width = bounds.width
        guard width > 0 else { return }                             // not laid out yet: layout() builds
        builtWidth = width
        builtScale = window?.backingScaleFactor ?? 2
        builtDark = isDark
        still { texts.forEach { $0.removeFromSuperlayer() } }       // no fade-out: Core Animation fades removals by itself
        texts = []; strings = []; tops = []; heights = []
        let textWidth = max(1, width - 2 * Self.inset)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let colour = resolved(.labelColor)
        let scale = window?.backingScaleFactor ?? 2
        var y: CGFloat = 0
        for (i, line) in lines.enumerated() {
            let text = NSAttributedString(string: line.text.isEmpty ? "♪" : line.text, attributes: [.font: font, .foregroundColor: colour])
            let height = ceil(text.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
            let layer = CATextLayer()
            layer.isWrapped = true
            layer.alignmentMode = .left
            layer.contentsScale = scale
            layer.opacity = i == current ? 1 : Self.unlit
            texts.append(layer); strings.append(text); tops.append(y); heights.append(height)
            y += height + Self.spacing
        }
        filled = Array(repeating: false, count: texts.count)
        let total = max(0, y - Self.spacing)
        still {
            strip.bounds = CGRect(x: 0, y: 0, width: textWidth, height: total)
            for (i, layer) in texts.enumerated() {
                // layers count y from the bottom: line i's top is tops[i] below the strip's top
                layer.frame = CGRect(x: 0, y: total - tops[i] - heights[i], width: textWidth, height: heights[i])
                strip.addSublayer(layer)
            }
            hover.isHidden = true
        }
        hovered = nil
        followAgainAt = .distantPast
        offset = target()
        place(animated: false)
    }

    override func layout() {
        super.layout()
        if bounds.width != builtWidth { build(); return }           // another width wraps the lines differently
        offset = Date.now > followAgainAt ? target() : clamped(offset)
        place(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // another screen's scale: build again for sharp text (only then: opening Now Playing built the lines twice)
        if let window, window.backingScaleFactor != builtScale { build() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if isDark != builtDark { build() }                          // light or dark: the text's colour
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// Gives their text to the lines between `low` and `high` (points down from the strip's top) that have none yet.
    private func fill(_ low: CGFloat, _ high: CGFloat) {
        still {
            for i in texts.indices where !filled[i] && tops[i] + heights[i] >= low && tops[i] <= high {
                texts[i].string = strings[i]
                filled[i] = true
            }
        }
    }

    /// The offset that puts the lit line in the middle; before the first line, the first one `introGap` from the top.
    private func target() -> CGFloat {
        guard let i = current, tops.indices.contains(i) else { return -Self.introGap }
        return tops[i] + heights[i] / 2 - bounds.height / 2
    }

    /// As far as you can scroll: the first line in the middle (or lower) to the last line in the middle.
    private func clamped(_ value: CGFloat) -> CGFloat {
        guard let first = heights.first, let lastTop = tops.last, let last = heights.last else { return value }
        let low = min(-Self.introGap, first / 2 - bounds.height / 2)
        let high = max(low, lastTop + last / 2 - bounds.height / 2)
        return min(high, max(low, value))
    }

    // MARK: motion

    /// The new line lights, the old one fades, and (unless you scrolled in the last 4 s) the strip brings it to the
    /// middle: one animation each, set up here once and played by the render server.
    private func light(from old: Int?) {
        let changes: [(Int?, Float)] = [(old, Self.unlit), (current, 1)]
        for (index, opacity) in changes {
            guard let i = index, texts.indices.contains(i) else { continue }
            let from = texts[i].presentation()?.opacity ?? texts[i].opacity
            still { texts[i].opacity = opacity }
            if motion > 0 { texts[i].add(Self.animation("opacity", from: from, to: opacity, duration: motion), forKey: "light") }
        }
        guard Date.now > followAgainAt else { return }
        offset = target()
        place(animated: true)
    }

    /// Puts the strip at `offset`, sliding there from wherever it is now when `animated`.
    private func place(animated: Bool) {
        let to = CGPoint(x: Self.inset, y: bounds.height + offset)
        let from = strip.presentation()?.position ?? strip.position
        // text for the lines around where it stops, and on the way there when it slides (half a view either side)
        let start = animated ? min(from.y - bounds.height, offset) : offset
        let end = animated ? max(from.y - bounds.height, offset) : offset
        fill(start - bounds.height / 2, end + bounds.height * 1.5)
        still { strip.position = to }
        if animated, motion > 0, from != to {
            strip.add(Self.animation("position", from: NSValue(point: from), to: NSValue(point: to), duration: motion), forKey: "follow")
        }
        #if DEBUG
        recordFrames()
        #endif
    }

    /// At the screen's own rate (no cap: see EqualizerBars), eased in and out.
    private static func animation(_ keyPath: String, from: Any, to: Any, duration: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    /// A change with no implicit animation (Core Animation animates most layer changes by itself otherwise).
    private func still(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }

    // MARK: scroll, click, hover

    /// False while Lyrics is hidden behind Up Next: the lines take no clicks, drags, scrolls or hover there.
    var active = true {
        didSet { if !active { setHovered(nil) } }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { active ? super.hitTest(point) : nil }

    override func scrollWheel(with event: NSEvent) {
        guard !texts.isEmpty else { return }
        // you look around: the light is not followed for 4 s; the next line change after that brings it back
        followAgainAt = .now.addingTimeInterval(4)
        if let moving = strip.presentation(), strip.animation(forKey: "follow") != nil {
            offset = moving.position.y - bounds.height                  // stop the follow where it is, then scroll from there
            strip.removeAnimation(forKey: "follow")
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        offset = clamped(offset - delta)
        place(animated: false)
    }

    override func mouseDown(with event: NSEvent) { pressed = line(at: convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let i = line(at: convert(event.locationInWindow, from: nil)), i == pressed else { return }
        followAgainAt = .distantPast                                // follow from the clicked line at once
        jump(i)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // a tracking area reports the pointer whatever hitTest says: hidden, the lines light nothing
    override func mouseMoved(with event: NSEvent) { setHovered(active ? line(at: convert(event.locationInWindow, from: nil)) : nil) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    /// Settings › Appearance › Button feedback: the same soft highlight as the app's other plain buttons.
    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        still {
            guard feedback, let i = index, texts.indices.contains(i) else { hover.isHidden = true; return }
            hover.frame = texts[i].frame.insetBy(dx: -6, dy: -6)
            hover.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.08)).cgColor
            hover.isHidden = false
        }
    }

    /// The line under a point of this view (a line takes 6 pt around it, like a button), if any.
    private func line(at point: NSPoint) -> Int? {
        let y = bounds.height - point.y + offset                    // in the strip, measured down from its top
        guard let i = tops.lastIndex(where: { $0 <= y + 6 }), y <= tops[i] + heights[i] + 6 else { return nil }
        return i
    }

    /// A dynamic colour (it differs in light and dark) as it looks in this view now.
    private func resolved(_ colour: NSColor) -> NSColor {
        var out = colour
        effectiveAppearance.performAsCurrentDrawingAppearance { out = NSColor(cgColor: colour.cgColor) ?? colour }
        return out
    }

    // MARK: accessibility: the panel reads as the line being sung

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Lyrics" }
    override func accessibilityValue() -> Any? {
        guard let i = current, lines.indices.contains(i) else { return nil }
        return lines[i].text.isEmpty ? "Instrumental break" : lines[i].text
    }

    #if DEBUG
    /// Self-tests measure where each line is: window points from the top, as SwiftUI's global frames are.
    private func recordFrames() {
        guard let height = window?.contentView?.frame.height else { return }
        for i in texts.indices {
            let inView = CGRect(x: Self.inset, y: bounds.height + offset - tops[i] - heights[i], width: strip.bounds.width, height: heights[i])
            let r = convert(inView, to: nil)
            SelfTest.frames["lyrics.line.\(i)"] = CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
        }
    }
    #endif
}

/// Plain lyrics: no times, so nothing to light; they scroll.
private struct PlainLyricsView: View {
    let lyrics: Lyrics

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .textStyle(size: 17, weight: .semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .selfTestShown("plain")
    }
}

private extension View {
    /// Debug builds: tells the lyrics self-test which screen the panel shows. Release builds: nothing.
    func selfTestShown(_ name: String) -> some View {
        #if DEBUG
        onAppear { SelfTest.lyricsShown = name }
        #else
        self
        #endif
    }
}

struct UpNextView: View {
    @Environment(Player.self) private var player
    @State private var selection: String?            // the row clicked: a list's own selection, as in Apple Music

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next").textStyle(.headline)
                Spacer()
                if !player.upNextEntries.isEmpty {
                    Button("Clear") { withAnimation(.snappy) { player.clearUpNext() } }
                        .buttonStyle(.quiet)
                        .foregroundStyle(.secondary)
                        .help("Empty Up Next; this song plays on")
                }
            }
            .padding(.horizontal, 16).padding(.top, 16)
            if player.upNextEntries.isEmpty {
                Text("Nothing queued. Play a list, or right-click a song → Play Next.")
                    .textStyle(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                // a List, for drag to reorder; each row is an entry (a song queued twice is two rows). Double-click and
                // the right-click menu are the list's own (`primaryAction`), not gestures on the rows: a tap gesture on
                // a row, even a double-click one, took the mouse-down the list needs to start a drag, so Up Next could
                // not be reordered (7 Oct). Apple's way for a Mac list; a click selects the row, as in Apple Music
                List(selection: $selection) {
                    ForEach(Array(player.upNextEntries.enumerated()), id: \.element.id) { offset, entry in
                        UpNextRow(track: entry.track) {
                            withAnimation(.snappy) { player.removeFromUpNext(at: offset) }
                        }
                        .tag(entry.id)                       // what selection, the menu and double-click name
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    }
                    .onMove { player.moveUpNext(fromOffsets: $0, toOffset: $1) }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let offset = offset(of: ids) {
                        Button("Play Now") { playNow(offset) }
                        Button("Remove from Up Next", role: .destructive) {
                            withAnimation(.snappy) { player.removeFromUpNext(at: offset) }
                        }
                    }
                } primaryAction: { ids in
                    if let offset = offset(of: ids) { playNow(offset) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(.snappy(duration: 0.3), value: player.upNextEntries.map(\.id))
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)   // the glass is Now Playing's, shared with Lyrics
    }

    /// Where the row the menu or double-click is about sits in Up Next.
    private func offset(of ids: Set<String>) -> Int? {
        guard let id = ids.first else { return nil }
        return player.upNextEntries.firstIndex { $0.id == id }
    }

    private func playNow(_ offset: Int) {
        selection = nil
        player.jump(to: player.index + 1 + offset)
    }
}

/// One song in Up Next: double-click plays it now; drag to move it; ✕ (on hover) or right-click removes it. The
/// double-click and the menu are the list's (UpNextView): a gesture here would stop the drag.
private struct UpNextRow: View {
    let track: Track
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: track.image, size: 36, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(track.title).textStyle(.callout).lineLimit(1)
                    if track.isExplicit { ExplicitBadge() }
                }
                Text(track.artistLine).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)   // drag me
                    .transition(.opacity)
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.quiet)
                    .help("Remove from Up Next")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(hovering ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }                         // instant: a fade per hover redrew the window ~15 times
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(track.title). Double-click to play now; drag to move")
    }
}
