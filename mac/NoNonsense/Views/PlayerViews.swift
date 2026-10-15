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
    /// 26 around a cover of radius 14, 12 in from the edge: the two curves are concentric (15 Oct, as in the Windows app).
    private let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)

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
        .selfTestFrame("bar.open.\(panel.rawValue)")
    }

    /// Settings › Colours › Player bar: the glass itself, tinted; System leaves it clear.
    var body: some View {
        if let track = player.current {
            PlayerBarLayout {
                // the song; a right-click has its menu (the bar's "…" button went in the redesign, 15 Oct)
                HStack(spacing: 12) {
                    Button { player.showNowPlaying = true } label: {
                        LiveArtwork(url: track.image, size: 52, radius: 14, fades: { [player] in !player.showNowPlaying })
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.quiet(highlight: false))
                    .help("Open Now Playing (⇧⌘F)")

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(track.title).textStyle(size: 14, weight: .semibold).lineLimit(1)
                            if track.isExplicit { ExplicitBadge() }
                        }
                        ArtistLinks(artists: track.artists).textStyle(size: 12.5).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { SongLibraryActions(track: track) }
                .selfTestFrame("bar.song")

                // ⏮ ▶ ⏭, and under them the progress line with the time on each side. It used to be a stripe
                // along the bar's curved bottom edge, which looked stuck on (6 Oct).
                VStack(spacing: 2) {
                    TransportControls(compact: true)
                        .fixedSize()
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SelfTest.controlsFrame = $0 }
                        #endif
                    // the line and the times, drawn by Core Animation: this body no longer reads the position at all
                    PlaybackTimeline(underNowPlaying: true)
                        .selfTestFrame("bar.progress")
                }
                .selfTestFrame("bar.centre")

                // as many of the buttons as there is room for, the one needed least going first: Now Playing (the cover
                // opens it too), Lyrics, Up Next, then the volume (15 Oct, as in the Windows app; the volume slider used
                // to go first). Each row is measured whole, so the one shown always fits
                ViewThatFits(in: .horizontal) {
                    buttons(track, keeping: 4)
                    buttons(track, keeping: 3)
                    buttons(track, keeping: 2)
                    buttons(track, keeping: 1)
                    buttons(track, keeping: 0)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .selfTestFrame("bar.buttons")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background { fill }
            // the whole bar is the bar: with no fill (Liquid Glass, Fill 0) its empty parts were not there for the
            // pointer, so a pinch opened Now Playing only over the progress line (the one part with a hit area), and
            // a click between the controls fell through to the song under the bar (7 Oct)
            .contentShape(shape)
            .compatGlass(in: shape, tint: theme.color(.playerBar)?.opacity(0.35), enabled: barStyle == .glass)
            .compatGlassID("bar", in: glass)
            .compatGlassMaterialize()
            .frame(maxWidth: 940)
            .selfTestFrame("bar")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { player.barFrame = $0 }
            .simultaneousGesture(MagnifyGesture().onEnded { if $0.magnification > 1.15 { player.showNowPlaying = true } })
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
    }

    /// Like, Lyrics, Up Next, the volume and Now Playing, in that order, less the ones the bar has no room for. `kept`:
    /// how many stay of the volume, Up Next, Lyrics and Now Playing, taken in that order (the order of need).
    private func buttons(_ track: Track, keeping kept: Int) -> some View {
        HStack(spacing: 14) {
            LikeButton(track: track, font: .title3)
                .selfTestFrame("bar.like")
            if kept >= 3 { open(.lyrics, symbol: "quote.bubble", help: "Lyrics") }
            if kept >= 2 { open(.upNext, symbol: "list.bullet", help: "Up Next") }
            if kept >= 1 { VolumeControl().selfTestFrame("bar.volume") }
            if kept >= 4 { open(.none, symbol: "arrow.up.left.and.arrow.down.right", help: "Now Playing (⇧⌘F)") }
        }
        .fixedSize()
        .selfTestFrame("bar.row")
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
/// narrow window the centre shrinks to its minimum before any button goes.
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

/// Shuffle, ⏮, play, ⏭ and repeat, shared by the bar (`compact`: packed together) and Now Playing (spread across the
/// cover's width), as in the Windows app (15 Oct): shuffle and repeat are circles tinted in the accent while on, and
/// play is a disc in the text's colour with its symbol in the window's.
struct TransportControls: View {
    var compact = false
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme
    @Environment(\.colorScheme) private var scheme

    /// Settings › Colours › Buttons; System is your Mac's accent.
    private var active: Color { theme.color(.buttons) ?? .accentColor }
    private var disc: CGFloat { compact ? 38 : 68 }
    private var skip: CGFloat { compact ? 34 : 48 }                 // the box each skip button takes

    var body: some View {
        HStack(spacing: compact ? 6 : 0) {
            // shuffle and repeat are the same width, one on each side: ▶ stays at the exact centre
            Button { withAnimation(.snappy(duration: 0.25)) { player.toggleShuffle() } } label: {
                mode(Image(systemName: "shuffle").symbolEffect(.bounce, value: player.isShuffled), on: player.isShuffled)
            }
            .help(player.isShuffled ? "Shuffle is on (⌘S)" : "Shuffle (⌘S)")
            .accessibilityLabel("Shuffle")
            .accessibilityValue(player.isShuffled ? "On" : "Off")
            gap

            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(compact ? .title3 : .title)
                    .symbolEffect(.bounce.byLayer, value: player.previousPresses)
                    .frame(width: skip, height: skip)
            }
                .help("Previous (⌘←)")
                .accessibilityLabel("Previous")
            gap
            Button { player.togglePlayPause() } label: {
                ZStack {
                    // a plain colour: in the bar's Liquid Glass `.primary` is drawn vibrant, and the disc came out light
                    // grey (CI picture, 15 Oct)
                    Circle().fill(scheme == .dark ? Color.white : Color.black)
                    // while a song loads (up to ~3 s for YouTube) the disc holds a spinner, so you know it is coming
                    if player.isBuffering {
                        ProgressView()
                            .controlSize(compact ? .small : .regular)
                            .environment(\.colorScheme, scheme == .dark ? .light : .dark)     // readable on the disc
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: (disc * 0.42).rounded()))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: disc, height: disc)
                .contentShape(.circle)
            }
            .buttonStyle(.quiet(highlight: false))                  // a square highlight around a disc looked stuck on
            .help("Play / Pause (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            gap
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(compact ? .title3 : .title)
                    .symbolEffect(.bounce.byLayer, value: player.nextPresses)
                    .frame(width: skip, height: skip)
            }
                .help("Next (⌘→)")
                .accessibilityLabel("Next")
            gap

            Button { withAnimation(.snappy(duration: 0.25)) { player.cycleRepeat() } } label: {
                mode(Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").contentTransition(.symbolEffect(.replace)),
                     on: player.repeatMode != .off)
            }
            .help(player.repeatMode.help)
            .accessibilityLabel("Repeat")
            .accessibilityValue(player.repeatMode.label)
        }
        .buttonStyle(.quiet)
    }

    /// Shuffle's or repeat's face: its symbol in a circle, tinted in the accent while on.
    private func mode(_ symbol: some View, on: Bool) -> some View {
        let side: CGFloat = compact ? 30 : 40
        return symbol
            .font(.system(size: compact ? 13 : 16, weight: .semibold))
            .foregroundStyle(on ? AnyShapeStyle(active) : AnyShapeStyle(.secondary))
            .frame(width: side, height: side)
            .background { if on { Circle().fill(active.opacity(0.16)).transition(.scale.combined(with: .opacity)) } }
            .contentShape(.circle)
    }

    /// Now Playing spreads the five across the cover's width; the bar keeps them together.
    @ViewBuilder private var gap: some View {
        if !compact { Spacer(minLength: 0) }
    }
}

/// What sits beside the artwork in Now Playing: Up Next, Lyrics (MUS-12), or nothing (the song alone, centred).
enum NowPlayingPanel: String {
    case upNext, lyrics, none

    /// The panel after pressing `which` in Now Playing's corner: its own, or none when it was the one showing.
    func toggling(_ which: NowPlayingPanel) -> NowPlayingPanel { self == which ? .none : which }
}

/// Now Playing's volume, as Apple Music has it: the quiet speaker mutes, the slider, the loud speaker turns it all the
/// way up (15 Oct, as in the Windows app). A view of its own because it reads the volume: in Now Playing's body, every
/// step of a drag ran that whole body again (#12), as VolumeControl does for the bar.
private struct NowPlayingVolume: View {
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme
    @AppStorage("haptics") private var haptics = true

    var body: some View {
        HStack(spacing: 6) {
            Button { player.toggleMute() } label: {
                Image(systemName: player.isMuted || player.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.secondary)
            }
            .help(player.isMuted ? "Unmute" : "Mute")
            .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
            Slider(value: Binding(get: { Double(player.volume) }, set: { player.setVolume(Float($0)) }), in: 0...1)
                .tint(theme.color(.volume))
                .accessibilityLabel("Volume")
                // a light tick at every tenth while you drag (Settings › Trackpad › Haptic ticks), as the line does per minute
                .sensoryFeedback(.alignment, trigger: Int((player.volume * 10).rounded())) { _, _ in haptics }
            Button { player.setVolume(1) } label: { Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary) }
                .help("Full Volume")
                .accessibilityLabel("Full volume")
        }
        .buttonStyle(.quiet)
        .font(.callout)
    }
}

/// Now Playing's cover, as Apple Music has it (15 Oct, as in the Windows app): full size while the song plays (or
/// loads), 86% while it is paused, springing between the two with its shadow (Core Animation, in LiveArtwork). A view
/// of its own because it reads whether the song plays: in Now Playing's body, every play and pause ran all of it again.
private struct NowPlayingCover: View {
    let track: Track
    let side: CGFloat
    @Environment(Player.self) private var player

    var body: some View {
        LiveArtwork(url: track.image, size: side, radius: side * 0.055, song: track.id, pop: true,
                    playing: player.isPlaying || player.isBuffering)
            .frame(width: side, height: side)
    }
}

/// Full-window Now Playing: huge artwork (as Jon Hicks asked Apple for), blended background, and a side panel
/// for Up Next or Lyrics. Press the showing panel's pill again and the panel goes: the song moves into the centre.
/// The panel you chose is remembered. Esc or a pinch in closes it; the corner button goes full screen.
struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @AppStorage("nowPlayingPanel") private var panelRaw = NowPlayingPanel.upNext.rawValue
    @AppStorage("nowPlayingBlur") private var surfaceBlur = Look.nowPlayingBlur        // Settings › Appearance › Surfaces › Now Playing
    @AppStorage("nowPlayingSolid") private var surfaceSolid = Look.nowPlayingSolid
    @AppStorage("nowPlayingColour") private var colourStrength = Look.nowPlayingColour
    @State private var isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
    private var panel: NowPlayingPanel { NowPlayingPanel(rawValue: panelRaw) ?? .upNext }

    /// The side panel and its gap from the song (15 Oct, as in the Windows app).
    private static let panelWidth: CGFloat = 380
    private static let panelGap: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // a blur and the window's colour hide the screen below; the artwork's wash goes on top of them
                ZStack {
                    SurfaceLayer(blur: surfaceBlur, solid: Look.readable(solid: surfaceSolid, blur: surfaceBlur), blending: .withinWindow)
                        .selfTestFrame("nowPlaying.surface")
                    IsolatedBackdrop(track: player.current, strength: colourStrength, inNowPlaying: true)
                }
                .ignoresSafeArea()

                if let track = player.current {
                    // the cover gives way to the controls: the height less the top bar and everything under the cover
                    // (15 Oct, as in the Windows app), and never so wide that the song and the panel leave the window
                    let beside = panel == .none ? 0 : Self.panelGap + Self.panelWidth
                    let side = min(min(max(geo.size.height - 440, 170), 470), geo.size.width - 48 - beside)
                    HStack(spacing: 0) {
                        songColumn(track, side: side)
                            .selfTestFrame("nowPlaying.column")
                        // the room the panel takes beside the song: as it opens the song moves over, and the two stay
                        // centred together
                        Color.clear.frame(width: beside, height: 0)
                    }
                    // exactly as tall as the song, from the top of the cover to the volume
                    .overlay(alignment: .topLeading) {
                        if panel != .none {
                            sidePanel
                                .frame(width: Self.panelWidth)
                                .selfTestFrame("nowPlaying.panel")
                                .padding(.leading, side + Self.panelGap)
                                .transition(.opacity.combined(with: .offset(x: 30)))
                        }
                    }
                    .padding(.vertical, 64).padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .selfTestFrame("nowPlaying.area")
                    // no SwiftUI animation keyed on the song: it redrew the column on every frame of the change. The
                    // cover's crossfade and springs are Core Animation (LiveArtwork); the titles change at once

                    topBar(track)
                }
            }
        }
        // the panel opening or closing: once, eased out (the Windows app's 0.42 s)
        .animation(.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.42), value: panelRaw)
        .simultaneousGesture(MagnifyGesture().onEnded { if $0.magnification < 0.85 { player.showNowPlaying = false } })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in isFullScreen = false }
    }

    private func songColumn(_ track: Track, side: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NowPlayingCover(track: track, side: side)
            titles(track)
                .padding(.top, 30)
            // Core Animation draws the line and the times (PlaybackTimeline): this view no longer reads the position
            PlaybackTimeline(thickness: 5, textStyle: .caption, timesBelow: true)
                .padding(.top, 18)
            TransportControls()
                .frame(width: side)                 // under a small cover (a short window) it overflows both sides alike
                .padding(.top, 12)
            NowPlayingVolume()
                .padding(.top, 14)
        }
        .frame(width: side)
    }

    /// The playlist it plays from, the title (the heart and the song's menu beside it), the artists (each opens its
    /// page; Now Playing closes first) and the copy playing.
    private func titles(_ track: Track) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let from = player.playingFrom {
                Label("From “\(from)”", systemImage: "music.note.list")
                    .textStyle(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(track.title).tracking(-0.5).textStyle(size: 26, weight: .bold).lineLimit(1)
                        if track.isExplicit { ExplicitBadge() }
                    }
                    ArtistLinks(artists: track.artists) { player.showNowPlaying = false }
                        .textStyle(size: 17, weight: .medium)
                        .foregroundStyle(.tint)
                        .padding(.top, 3)
                    CopyMenu(track: track)
                        .textStyle(size: 13)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)                       // under a small cover it wrapped ("JioSaavn · AAC / 320 kbps")
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
                LikeButton(track: track, font: .title2)
                SongActionsButton(track: track, font: .title2)
            }
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
        .compatGlass(in: .rect(cornerRadius: 22))
    }

    /// Close on the left; what is playing in the middle of the window; on the right, Lyrics and Up Next as pills, and
    /// full screen (15 Oct, as in the Windows app). The two sides take the same width whatever they hold, so the
    /// middle is the window's: between the close button and the wider pills it sat off the song's centre.
    private func topBar(_ track: Track) -> some View {
        HStack(spacing: 0) {
            Button { player.showNowPlaying = false } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.08), in: .circle)
            }
            .buttonStyle(.quiet(highlight: false))
            .keyboardShortcut(.cancelAction)                      // Esc closes, and so does a pinch in
            .help("Close (Esc)")
            .accessibilityLabel("Close")
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 1) {
                Text("NOW PLAYING")
                    .tracking(1.6)
                    .textStyle(size: 10.5, weight: .bold)
                    .foregroundStyle(.secondary)
                    .selfTestFrame("nowPlaying.title")
                if let album = track.albumTitle {
                    Text(album).textStyle(size: 13, weight: .semibold).foregroundStyle(.primary.opacity(0.85)).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 8) {
                pill(.lyrics, symbol: "quote.bubble", title: "Lyrics")
                pill(.upNext, symbol: "list.bullet", title: "Up Next")
                Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                    Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 38, height: 38)
                        .background(Color.primary.opacity(0.08), in: .circle)
                }
                .buttonStyle(.quiet(highlight: false))
                .help(isFullScreen ? "Exit Full Screen (⌃⌘F)" : "Full Screen (⌃⌘F)")
            }
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
    }

    /// Lyrics or Up Next: filled in the text's colour while its panel shows; pressed again, the panel goes (the song
    /// alone, centred).
    private func pill(_ which: NowPlayingPanel, symbol: String, title: String) -> some View {
        let on = panel == which
        return Button { panelRaw = panel.toggling(which).rawValue } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                Text(title).textStyle(size: 13, weight: .semibold)
            }
            .foregroundStyle(on ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.85))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(on ? Color.primary : Color.primary.opacity(0.08), in: .capsule)
        }
        .buttonStyle(.quiet(highlight: false))
        .help(on ? "Hide \(title)" : "Show \(title)")
        .accessibilityLabel(title)
        .accessibilityValue(on ? "Showing" : "Hidden")
        .selfTestFrame("nowPlaying.pill.\(which.rawValue)")
    }
}

/// Where the song plays from ("YouTube Music · AAC 128 kbps"). With more than one copy it is a menu: choosing a copy
/// plays it from the same moment.
private struct CopyMenu: View {
    let track: Track
    @Environment(Player.self) private var player

    var body: some View {
        let playing = player.playingListing ?? track.best
        let label = "\(playing.sourceName) · \(playing.quality)"
        if track.listings.count > 1 {
            Menu {
                ForEach(track.listings, id: \.key) { listing in
                    Toggle(isOn: Binding(get: { listing.key == playing.key }, set: { if $0 { player.switchCopy(to: listing) } })) {
                        Text("\(listing.sourceName) · \(listing.quality)")
                        Text("\(listing.artists.joined(separator: ", ")) · \(formatTime(Double(listing.duration)))\(listing.explicit == true ? " · Explicit" : "")")
                    }
                }
            } label: {
                Text(label)
            }
            .menuStyle(.button)
            .buttonStyle(.quiet)
            .fixedSize()
            .help("Play another copy of this song")
            .selfTestFrame("nowPlaying.copyMenu")
        } else {
            Text(label).help("The only place this song plays from")
        }
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
    @AppStorage("geniusNotes") private var genius = false          // Settings › Lyrics › Genius notes (experimental)
    @State private var aboutShown = false
    @AppStorage("lyricsTranslated") private var translating = false  // stays on for the next foreign song

    /// The lyrics' language when they are found and not in the reader's own.
    private func foreign(_ state: LyricsStore.State?, track: Track) -> Locale.Language? {
        guard case .found(let found) = state, !found.lines.isEmpty else { return nil }
        return LyricsTranslations.shared.language(of: track.id, lines: found.lines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let track = player.current {
                let state = lyrics.state(for: track)
                let notes = genius ? lyrics.notes[track.id] : nil
                let language = foreign(state, track: track)
                header(state, notes: notes, language: language)
                Group {
                    if translating, let language, case .found(let found) = state {
                        TranslatedLyricsView(songID: track.id, lyrics: found.lines, language: language).id(track.id)
                    } else {
                        content(state, track: track, notes: notes)
                    }
                }
                    // a no-op when the song start already asked. Only while this panel shows in an open Now Playing
                    // (both are kept, hidden, between uses), so Settings › Lyrics › "Only when I open Lyrics" still
                    // means that
                    .task(id: [track.id, shown && player.showNowPlaying ? "open" : "closed", genius ? "genius" : ""]) {
                        if shown && player.showNowPlaying { lyrics.fetch(track) }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .selfTestFrame("lyrics.panel")              // the glass is Now Playing's, shared with Up Next
    }

    private func header(_ state: LyricsStore.State?, notes: GeniusNotes?, language: Locale.Language?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Lyrics").textStyle(.headline)
            Spacer()
            // lyrics in another language: their translation, made on this Mac
            if language != nil {
                Button { translating.toggle() } label: {
                    Image(systemName: "character.bubble")
                        .symbolVariant(translating ? .fill : .none)
                        .foregroundStyle(translating ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.quiet)
                .help(translating ? "Show the Lyrics" : "Translate")
                .accessibilityLabel(translating ? "Show the lyrics" : "Translate the lyrics")
                .selfTestFrame("lyrics.translate")
            }
            if case .found(let found) = state, let source = found.sourceName {
                Text(found.synced ? "from \(source)" : "from \(source) · not timed")
                    .textStyle(.caption).foregroundStyle(.secondary)
            }
            // Genius's About this song: a glass popover, as Apple's apps show more about a thing
            if let about = notes?.about, !about.isEmpty {
                Button { aboutShown.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.quiet)
                    .help("About This Song")
                    .selfTestFrame("lyrics.about")
                    .popover(isPresented: $aboutShown, arrowEdge: .bottom) { GeniusAboutCard(about: about, url: notes?.url) }
            }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
    }

    @ViewBuilder private func content(_ state: LyricsStore.State?, track: Track, notes: GeniusNotes?) -> some View {
        switch state {
        case .found(let found) where found.lines.isEmpty:
            message("Couldn't find lyrics", symbol: "quote.bubble", shown: "none")
        case .found(let found) where found.synced:
            // the playing line, known before the panel is drawn: it opens there instead of scrolling to it.
            // One view per song: with the next song's lyrics already fetched, the view was kept across the change, and
            // its running task went on lighting lines by the previous song's times (audit, 7 Oct)
            TimedLyricsView(lyrics: found, startLine: found.line(at: player.livePosition + 0.1), active: shown,
                            notes: notes?.byLine(found.lines) ?? [:], notesURL: notes?.url)
                .id(track.id)
        case .found(let found):
            PlainLyricsView(lyrics: found, notes: notes?.byLine(found.lines) ?? [:], notesURL: notes?.url)
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
    @Environment(ThemeStore.self) private var theme
    @State private var current: Int?
    let active: Bool                                   // false while hidden behind Up Next: the lines ignore the mouse
    let notes: [Int: GeniusNote]                       // Genius notes by line: those lines are in the accent; a click opens one
    let notesURL: String?
    @State private var openNote: NoteAnchor?

    init(lyrics: Lyrics, startLine: Int?, active: Bool = true, notes: [Int: GeniusNote] = [:], notesURL: String? = nil) {
        self.lyrics = lyrics
        self.active = active
        self.notes = notes
        self.notesURL = notesURL
        _current = State(initialValue: startLine)
    }

    var body: some View {
        // the noted lines take the accent (Settings › Colours › Buttons; System is your Mac's)
        LyricLines(lines: lyrics.lines, current: current, motion: motion, fontSize: LyricsFont.size * textScale, feedback: feedback,
                   active: active, noted: Set(notes.keys), accent: theme.color(.buttons) ?? .accentColor,
                   openNote: { openNote = NoteAnchor(line: $0, rect: $1) }) {
            jump(to: $0)
        }
        // a noted line's click opens its note beside it instead of playing from it: Play from Here is in the note
        .popover(item: $openNote, attachmentAnchor: .rect(.rect(openNote?.rect ?? .zero)), arrowEdge: .leading) { anchor in
            if let note = notes[anchor.line] {
                GeniusNoteCard(note: note, url: notesURL) { openNote = nil; jump(to: anchor.line) }
            }
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

/// Where a Genius note opens: its line, in the lines' view (top-left origin, as SwiftUI counts).
struct NoteAnchor: Identifiable {
    let line: Int
    let rect: CGRect
    var id: Int { line }
}

/// The timed lines, as a view SwiftUI hands to AppKit.
private struct LyricLines: NSViewRepresentable {
    let lines: [LyricLine]
    let current: Int?                                              // nil: before the first line
    let motion: Double
    let fontSize: CGFloat
    let feedback: Bool
    let active: Bool
    var noted: Set<Int> = []                                       // lines with a Genius note: in the accent
    let accent: Color
    var openNote: (Int, CGRect) -> Void = { _, _ in }
    let jump: (Int) -> Void

    func makeNSView(context: Context) -> LyricLinesView { LyricLinesView() }

    func updateNSView(_ view: LyricLinesView, context: Context) {
        view.active = active
        view.openNote = openNote
        view.update(lines: lines, current: current, motion: motion, fontSize: fontSize, feedback: feedback, noted: noted,
                    accent: accent, jump: jump)
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
    private(set) var noted: Set<Int> = []          // lines with a Genius note: in the accent colour, a click opens it
    private var accent = Color.accentColor         // the noted lines' colour
    var openNote: (Int, CGRect) -> Void = { _, _ in }
    private var current: Int?
    private var motion = Look.lyricsMotion
    private var fontSize = LyricsFont.size
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
    private static let unlitNoted: Float = 0.6     // a noted line, unlit: its accent fades less (as in the Windows app)
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

    func update(lines: [LyricLine], current: Int?, motion: Double, fontSize: CGFloat, feedback: Bool, noted: Set<Int> = [],
                accent: Color, jump: @escaping (Int) -> Void) {
        self.motion = motion
        self.feedback = feedback
        self.jump = jump
        // notes arrive after the lyrics, and the song's colour (the accent) after the song
        if lines != self.lines || fontSize != self.fontSize || noted != self.noted || accent != self.accent {
            self.lines = lines
            self.noted = noted
            self.accent = accent
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
        let font = LyricsFont.nsFont(size: fontSize)
        let colour = resolved(.labelColor)
        let noteColour = resolved(NSColor(accent))     // a line with a Genius note (15 Oct: it was underlined)
        let scale = window?.backingScaleFactor ?? 2
        var y: CGFloat = 0
        for (i, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: LyricsFont.tracking,
                                                             .foregroundColor: noted.contains(i) ? noteColour : colour]
            let text = NSAttributedString(string: line.text.isEmpty ? "♪" : line.text, attributes: attributes)
            // measured by CoreText, which CATextLayer draws with. TextKit measured Devanagari lines shorter (24 pt a row
            // against 33), and a CATextLayer whose wrapped text does not fit its height draws one unwrapped, clipped row
            let height = ceil(CTFramesetterSuggestFrameSizeWithConstraints(
                CTFramesetterCreateWithAttributedString(text), CFRange(), nil,
                CGSize(width: textWidth, height: .greatestFiniteMagnitude), nil).height) + 2
            let layer = CATextLayer()
            layer.isWrapped = true
            layer.alignmentMode = .left
            layer.contentsScale = scale
            layer.opacity = i == current ? 1 : dimmed(i)
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
        let changes: [(Int?, Bool)] = [(old, false), (current, true)]
        for (index, lit) in changes {
            guard let i = index, texts.indices.contains(i) else { continue }
            let opacity = lit ? 1 : dimmed(i)
            let from = texts[i].presentation()?.opacity ?? texts[i].opacity
            still { texts[i].opacity = opacity }
            if motion > 0 { texts[i].add(Self.animation("opacity", from: from, to: opacity, duration: motion), forKey: "light") }
        }
        guard Date.now > followAgainAt else { return }
        offset = target()
        place(animated: true)
    }

    /// How line `i` looks while not sung: faded, a noted line's accent less so.
    private func dimmed(_ i: Int) -> Float { noted.contains(i) ? Self.unlitNoted : Self.unlit }

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
        if noted.contains(i) {                                      // its note opens beside it (Play from Here is in it)
            openNote(i, CGRect(x: Self.inset, y: tops[i] - offset, width: strip.bounds.width, height: heights[i]))
            return
        }
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
    var notes: [Int: GeniusNote] = [:]
    var notesURL: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                    if let note = notes[i] {
                        NotedLine(text: line.text, note: note, url: notesURL)
                    } else {
                        Text(line.text.isEmpty ? " " : line.text)
                            .lyricsStyle()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

/// The lyrics' face (15 Oct, as in the Windows app): Figtree ExtraBold, an open geometric font in the manner of
/// Spotify's, set as Spotify sets its lyrics: extra bold, large, tightly spaced. Its own line height is 1.2 times its
/// size (ascender 950 + descender 250 per 1000), the one wanted, so nothing sets a line height. Bundled
/// (Fonts/Figtree-ExtraBold.ttf, SIL Open Font License beside it) and registered for this app alone the first time
/// lyrics are drawn; the system's heavy font if it cannot be.
enum LyricsFont {
    static let size: CGFloat = 24                   // × Settings › Appearance › Text size
    static let tracking: CGFloat = -0.6
    static let name = "Figtree-ExtraBold"

    /// Registers the face, once, the first time it is asked for; false: it is missing (then the system's is used).
    private static let available: Bool = {
        if let url = Bundle.main.url(forResource: LyricsFont.name, withExtension: "ttf") {
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return NSFont(name: LyricsFont.name, size: LyricsFont.size) != nil
    }()

    /// For the timed lines' layers.
    static func nsFont(size: CGFloat) -> NSFont {
        (available ? NSFont(name: name, size: size) : nil) ?? .systemFont(ofSize: size, weight: .heavy)
    }

    /// For plain and translated lyrics.
    static func font(size: CGFloat) -> Font {
        available ? .custom(name, fixedSize: size) : .system(size: size, weight: .heavy)
    }
}

extension View {
    /// A lyric line's text (LyricsFont) at the size Settings › Appearance › Text size chose.
    func lyricsStyle() -> some View { modifier(LyricsText()) }
}

private struct LyricsText: ViewModifier {
    @Environment(\.textScale) private var scale

    func body(content: Content) -> some View {
        content.font(LyricsFont.font(size: LyricsFont.size * scale)).tracking(LyricsFont.tracking)
    }
}

/// A row of Up Next: a song (with its place among the songs), or the heading where Autoplay's part begins.
enum UpNextItem: Identifiable {
    case song(PlayQueue.Entry, Int)
    case autoplayHeading

    var id: String {
        switch self {
        case .song(let entry, _): entry.id
        case .autoplayHeading: "upnext.autoplay-heading"
        }
    }
}

/// Up Next in a jam: the room's queue, the same for everyone in it. Play Now and remove act on the room.
private struct JamUpNext: View {
    let room: JamState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next").textStyle(.headline)
                Label("Jam", systemImage: "person.2.wave.2").textStyle(.caption, weight: .semibold).foregroundStyle(.tint)
                Spacer()
                if JamSession.shared.isHost { AutoplayButton() }   // the host's Autoplay fills the room's queue
            }
            .padding(.horizontal, 16).padding(.top, 16)
            if room.queue.isEmpty {
                Text("Play any song to add it to the jam.")
                    .textStyle(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                // the room's queue drags as yours does; the move goes to the room, so everyone sees it
                ScrollView {
                    ReorderableStack(items: room.queue, rowHeight: 46, move: { from, to in
                        JamSession.shared.move(room.queue[from], to: to)
                    }, row: { entry, _ in
                        UpNextRow(track: Track(best: entry.listing, listings: [entry.listing], choosingVersion: false)) {
                            JamSession.shared.jump(to: entry)
                        } remove: {
                            JamSession.shared.remove(entry)
                        }
                        .padding(.horizontal, 6)
                    })
                    .padding(.bottom, 8)
                }
                .selfTestFrame("upNext.jam")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// ∞ in Up Next, as in Apple Music: on, songs like the last one keep playing when the queue runs out.
private struct AutoplayButton: View {
    @AppStorage("autoplay") private var autoplay = true
    @Environment(Player.self) private var player

    var body: some View {
        Button { autoplay.toggle(); if autoplay { player.upNextChanged() } } label: {
            Image(systemName: "infinity")
                .font(.body.weight(.semibold))
                .foregroundStyle(autoplay ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.quiet)
        .help(autoplay ? "Autoplay is on: similar songs play when Up Next runs out" : "Autoplay is off")
        .accessibilityLabel("Autoplay")
        .accessibilityValue(autoplay ? "On" : "Off")
    }
}

struct UpNextView: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let room = JamSession.shared.state { JamUpNext(room: room) } else { queue }
    }

    private var queue: some View {
        let entries = player.upNextEntries                 // a copy of the queue's tail: once, not three times (#12)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next").textStyle(.headline)
                Spacer()
                AutoplayButton()
                if !entries.isEmpty {
                    Button("Clear") { withAnimation(.snappy) { player.clearUpNext() } }
                        .buttonStyle(.quiet)
                        .foregroundStyle(.secondary)
                        .help("Empty Up Next; this song plays on")
                }
            }
            .padding(.horizontal, 16).padding(.top, 16)
            if entries.isEmpty {
                Text("Nothing queued. Play a list, or right-click a song → Play Next or Add to Queue.")
                    .textStyle(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                // drag a row to move it: it follows the pointer and the others make room (ReorderableStack; List's own
                // drag and drop never delivered the drop in here, 7 Oct). Each row is an entry: a song queued twice is two.
                // One queue: your songs, then Autoplay's under its heading (as in Apple Music); any song can be dragged
                // anywhere, and which side of the heading it lands on makes it yours or Autoplay's (12 Oct)
                let mine = entries.prefix { !$0.autoplay }.count
                let rows: [UpNextItem] = entries.enumerated().map { .song($1, $0) }
                let items = mine < entries.count ? Array(rows[..<mine]) + [.autoplayHeading] + Array(rows[mine...]) : rows
                ScrollView {
                    ReorderableStack(items: items, rowHeight: 46, move: { from, to in
                        guard case .song(_, let start) = items[from] else { return }
                        var arranged = items
                        let moved = arranged.remove(at: from)
                        arranged.insert(moved, at: to)
                        let heading = arranged.firstIndex { $0.id == UpNextItem.autoplayHeading.id } ?? arranged.count
                        player.moveUpNext(from: start, to: to > heading ? to - 1 : to, autoplay: to > heading)
                    }, row: { item, _ in
                        switch item {
                        case .autoplayHeading:
                            Label("Autoplay", systemImage: "infinity")
                                .textStyle(.subheadline, weight: .semibold)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                                .padding(.horizontal, 16).padding(.bottom, 6)
                                .selfTestFrame("upNext.autoplay")
                        case .song(let entry, let offset):
                            UpNextRow(track: entry.track) {
                                player.jump(to: player.index + 1 + offset)
                            } remove: {
                                withAnimation(.snappy) { player.removeFromUpNext(at: offset) }
                            }
                            .padding(.horizontal, 6)
                            .selfTestFrame("upNext.row:\(offset)")
                        }
                    }, canDrag: { $0.id != UpNextItem.autoplayHeading.id })
                }
                .animation(.snappy(duration: 0.3), value: entries.map(\.id))
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)   // the glass is Now Playing's, shared with Lyrics
    }
}

/// One song in Up Next: a click plays it now (it is already queued: nothing to select it for); drag to move it
/// (ReorderableStack); ✕ (on hover) or right-click removes it.
private struct UpNextRow: View {
    let track: Track
    let play: () -> Void
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
        .onTapGesture(perform: play)                       // no List under it now: a gesture here stops no drag
        .onHover { hovering = $0 }                         // instant: a fade per hover redrew the window ~15 times
        .contextMenu {
            Button("Play Now", action: play)
            Divider()
            SongLibraryActions(track: track)
            Divider()
            Button("Remove from Up Next", role: .destructive, action: remove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(track.title). Click to play now; drag to move")
    }
}

// MARK: - Genius notes (experimental, 8 Oct)

/// A plain lyric line with a Genius note: in the accent colour (15 Oct: it was underlined); a click opens the note.
private struct NotedLine: View {
    let text: String
    let note: GeniusNote
    let url: String?
    @State private var open = false

    var body: some View {
        Text(text)
            .lyricsStyle()
            .foregroundStyle(.tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { open = true }
            .popover(isPresented: $open, arrowEdge: .leading) { GeniusNoteCard(note: note, url: url) }
    }
}

/// One Genius note, in a glass popover beside its line: the note, then the credit, and Play from Here for timed lyrics
/// (the click that opened it did not play from the line).
struct GeniusNoteCard: View {
    let note: GeniusNote
    let url: String?
    var play: (() -> Void)?
    @Environment(\.textScale) private var textScale

    private static let width: CGFloat = 340
    private static let padding: CGFloat = 16
    private static let tallest: CGFloat = 380

    /// The note's height at the card's width, measured once before layout: a long note scrolls inside a card of fixed
    /// height. Measured while on screen, a Show More that changed the height resized the popover inside its own
    /// layout pass, and AppKit stopped the app (a layout loop).
    private var noteHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: Font.TextStyle.body.macPointSize * textScale)
        let size = NSAttributedString(string: note.text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: Self.width - 2 * Self.padding, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(size.height) + 2
    }

    var body: some View {
        let height = noteHeight
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(note.text)
                    .textStyle(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(height, Self.tallest))
            HStack {
                GeniusCredit(url: url, verified: note.verified)
                Spacer()
                if let play { Button("Play from Here", action: play) }
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width)
    }
}

/// Genius's About this song: its description, who produced it, what it samples.
struct GeniusAboutCard: View {
    let about: GeniusAbout
    let url: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("About This Song").textStyle(.headline)
            if let description = about.description {
                Text(description).textStyle(.body).lineLimit(14).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !about.producedBy.isEmpty { fact("Produced by", about.producedBy.joined(separator: ", ")) }
            if !about.samples.isEmpty { fact("Samples", about.samples.joined(separator: "\n")) }
            GeniusCredit(url: url, verified: false)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).textStyle(.caption, weight: .semibold).foregroundStyle(.secondary)
            Text(value).textStyle(.callout)
        }
    }
}

/// "Genius", a link to the song's page there when there is one: the notes are theirs.
private struct GeniusCredit: View {
    let url: String?
    let verified: Bool

    var body: some View {
        let label = verified ? "Genius · Verified by the artist" : "Genius"
        if let url, let link = URL(string: url) {
            Link(label, destination: link).textStyle(.caption)
        } else {
            Text(label).textStyle(.caption).foregroundStyle(.secondary)
        }
    }
}
