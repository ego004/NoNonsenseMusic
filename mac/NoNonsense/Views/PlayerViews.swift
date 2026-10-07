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
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Settings › Colours › Player bar: the glass itself, tinted; System leaves it clear.
    private var barGlass: Glass {
        if let tint = theme.color(.playerBar) { .regular.tint(tint.opacity(0.35)).interactive() } else { .regular.interactive() }
    }

    var body: some View {
        if let track = player.current {
            PlayerBarLayout {
                // the song
                HStack(spacing: 12) {
                    Button { player.showNowPlaying = true } label: {
                        ArtworkView(url: track.image, size: 48, radius: 10)
                    }
                    .buttonStyle(.plain)
                    .help("Open Now Playing (⇧⌘F)")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).textStyle(.callout, weight: .semibold).lineLimit(1)
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
                    HStack(spacing: 8) {
                        Text(formatTime(player.position))
                            .frame(width: 40, alignment: .trailing)
                            .selfTestFrame("bar.elapsed")
                        ProgressBar(position: player.position, duration: player.duration, onSeek: { player.seek(to: $0) })
                            .selfTestFrame("bar.progress")
                        Text("-" + formatTime(max(0, player.duration - player.position)))
                            .frame(width: 40, alignment: .leading)
                            .selfTestFrame("bar.remaining")
                    }
                    .textStyle(.caption2, monospacedDigit: true)
                    .foregroundStyle(.secondary)
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
            .glassEffect(barStyle == .glass ? barGlass : .identity, in: shape)   // interactive: the glass reacts to hover and press
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
        .buttonStyle(.plain)
    }
}

/// Full-window Now Playing: huge artwork (as Jon Hicks asked Apple for), blended background, Up Next.
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
                    IsolatedBackdrop(track: player.current, strength: colourStrength)
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
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: track.id)
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
            ArtworkView(url: track.image, size: side, radius: 18)
                // the cover lights the space under it in its own colour
                .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.28 : 0.55), radius: 50, y: 24)
                .id(track.id)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
            VStack(alignment: .leading, spacing: 6) {
                if let from = player.playingFrom {
                    Label("From “\(from)”", systemImage: "music.note.list")
                        .textStyle(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(track.title).textStyle(.title, weight: .bold).lineLimit(2)
                    Spacer()
                    LikeButton(track: track, font: .title2)
                }
                Text(track.artistLine).textStyle(.title3).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: side)
            VStack(spacing: 4) {
                ProgressBar(position: player.position, duration: player.duration, onSeek: { player.seek(to: $0) },
                            thickness: 5)
                HStack {
                    Text(formatTime(player.position))
                    Spacer()
                    Text("-" + formatTime(max(0, player.duration - player.position)))
                }
                .textStyle(.caption, monospacedDigit: true)
                .foregroundStyle(.secondary)
                // no rolling digits: their animation ran a third of every second and repainted the cover's layer with it
            }
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

    @ViewBuilder private var sidePanel: some View {
        switch panel {
        case .upNext: UpNextView()
        case .lyrics: LyricsPanel()
        case .none: EmptyView()
        }
    }

    /// Close on the left; on the right, the panel buttons and full screen. All glass, all with tooltips.
    private var topBar: some View {
        HStack(spacing: 10) {
            Button { player.showNowPlaying = false } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(accent.opacity(0.25)).interactive() : .regular.interactive(), in: .circle)
        .help(on ? "Hide \(title)" : "Show \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(on ? "Showing" : "Hidden")
    }
}

/// The Lyrics panel until MUS-12 brings real ones: says what is coming, in the same glass as Up Next.
/// Now Playing's Lyrics (MUS-12). Timed lyrics: the line being sung is lit and kept in the middle; click any line
/// to jump there. Scroll to look around: following stops for a few seconds, then picks up again. Plain lyrics
/// (no times) simply scroll. Asks the server once per song (LyricsStore); "Couldn't find lyrics" when nobody has them.
struct LyricsPanel: View {
    @Environment(Player.self) private var player
    @Environment(LyricsStore.self) private var lyrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let track = player.current {
                let state = lyrics.state(for: track)
                header(state)
                content(state, track: track)
                    .task(id: track.id) { lyrics.fetch(track) }       // a no-op when the song start already asked
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .selfTestFrame("lyrics.panel")
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
            TimedLyricsView(lyrics: found)
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
/// sleeps until the next line is due (reading the player's live position, as `position` updates only twice a
/// second), and any seek moves it at once. A 10-a-second timer cost 14% of a core more than Up Next (6 Oct).
private struct TimedLyricsView: View {
    let lyrics: Lyrics
    @Environment(Player.self) private var player
    @State private var current: Int?

    var body: some View {
        TimedLines(lines: lyrics.lines, current: current)
            .equatable()                                           // redrawn only when the lit line changes
            .task(id: player.isPlaying) { await follow() }
            .onChange(of: player.position, initial: true) { light() }   // a seek, playing or paused
    }

    /// While playing: light the line, sleep until the next one is due, repeat. At most half a second at a time,
    /// so a seek from elsewhere is noticed soon even between position updates.
    private func follow() async {
        while !Task.isCancelled {
            let now = light()
            guard player.isPlaying else { return }
            let next = (current ?? -1) + 1
            let due = next < lyrics.lines.count ? Double(lyrics.lines[next].startMs ?? 0) / 1000 - now : 0.5
            try? await Task.sleep(for: .seconds(min(max(due, 0.02), 0.5)))
        }
    }

    /// Lights the line being sung now (a tenth of a second early: the light lands with the voice). Returns the time used.
    @discardableResult private func light() -> Double {
        let now = (player.isPlaying ? player.livePosition : player.position) + 0.1
        let line = lyrics.line(at: now)
        if line != current { current = line }
        return now
    }
}

private struct TimedLines: View, Equatable {
    let lines: [LyricLine]
    let current: Int?                                              // nil: before the first line
    @Environment(Player.self) private var player
    @State private var followAgainAt = Date.distantPast             // you scrolled: follow again after this

    static func == (a: TimedLines, b: TimedLines) -> Bool { a.current == b.current && a.lines == b.lines }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button { jump(to: line) } label: { row(line, index: index) }
                            .buttonStyle(.plain)
                            .id(index)
                            .selfTestFrame("lyrics.line.\(index)")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 140)                           // room for the first and last lines to sit in the middle
            }
            .scrollIndicators(.never)
            // no fade mask at the edges: measured 6 Oct, it cost ~2% of a core more while playing (a mask redraws
            // offscreen); the lines clip at the panel's edge, as Up Next's do
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { followAgainAt = .now.addingTimeInterval(4) }
            }
            .onChange(of: current) { _, line in
                guard let line, Date.now > followAgainAt else { return }
                // smooth while the app is in front. Behind other apps it jumps: an animated scroll there never
                // finished (macOS stops drawing frames for a covered window; tested 7 Oct), and it saves the frames
                if NSApp.isActive {
                    withAnimation(.smooth(duration: 0.55)) { proxy.scrollTo(line, anchor: .center) }
                } else {
                    proxy.scrollTo(line, anchor: .center)
                }
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            #if DEBUG
            .onChange(of: current, initial: true) { _, line in SelfTest.lyricsCurrent = line }
            .onAppear { SelfTest.lyricsJump = { index in jump(to: lines[index]) } }     // the click, when a click cannot reach
            #endif
        }
    }

    private func row(_ line: LyricLine, index: Int) -> some View {
        let lit = index == current
        return Text(line.text.isEmpty ? "♪" : line.text)
            .textStyle(size: 21, weight: .bold)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(lit ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .opacity(lit ? 1 : 0.55)
            // opacity only: scaling text made every frame of the change re-render it (measured 7 Oct)
            .animation(.easeOut(duration: 0.25), value: lit)
            .contentShape(.rect)
            .accessibilityLabel(line.text.isEmpty ? "Instrumental break" : line.text)
            .accessibilityAddTraits(lit ? .isSelected : [])
    }

    /// Click a line: play from where it starts.
    private func jump(to line: LyricLine) {
        guard let ms = line.startMs else { return }
        followAgainAt = .distantPast                               // follow from here at once
        player.seek(to: Double(ms) / 1000)
        if !player.isPlaying { player.togglePlayPause() }
    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next").textStyle(.headline)
                Spacer()
                if !player.upNextEntries.isEmpty {
                    Button("Clear") { withAnimation(.snappy) { player.clearUpNext() } }
                        .buttonStyle(.plain)
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
                // a List, for drag to reorder; each row is an entry (a song queued twice is two rows)
                List {
                    ForEach(Array(player.upNextEntries.enumerated()), id: \.element.id) { offset, entry in
                        UpNextRow(track: entry.track) {
                            player.jump(to: player.index + 1 + offset)
                        } remove: {
                            withAnimation(.snappy) { player.removeFromUpNext(at: offset) }
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    }
                    .onMove { player.moveUpNext(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(.snappy(duration: 0.3), value: player.upNextEntries.map(\.id))
                .padding(.bottom, 8)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// One song in Up Next: click plays it now; drag to move it; ✕ (on hover) or right-click removes it.
private struct UpNextRow: View {
    let track: Track
    let play: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(url: track.image, size: 36, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).textStyle(.callout).lineLimit(1)
                Text(track.artistLine).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
                    .help("Remove from Up Next")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(hovering ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: play)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button("Play Now", action: play)
            Button("Remove from Up Next", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Play \(track.title) now")
    }
}
