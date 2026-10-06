import SwiftUI

/// The floating Liquid Glass capsule at the bottom of the window. Hidden until something plays.
struct PlayerBar: View {
    var glass: Namespace.ID
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme

    @AppStorage("nowPlayingPanel") private var panelRaw = NowPlayingPanel.upNext.rawValue

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
            // The two sides take equal widths, so ⏮ ▶ ⏭ sit at the bar's exact centre. With a spacer on each side
            // instead, the wider right side (volume, heart, list) pushed them 56 pt right of centre (5 Oct).
            HStack(spacing: 14) {
                HStack(spacing: 14) {
                    Button { player.showNowPlaying = true } label: {
                        ArtworkView(url: track.image, size: 44, radius: 9)
                    }
                    .buttonStyle(.plain)
                    .help("Open Now Playing (⇧⌘F)")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).textStyle(.callout, weight: .semibold).lineLimit(1)
                        Text(track.artistLine).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(minWidth: 120, maxWidth: 240, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                TransportControls(size: .title3, playSize: .title)
                    .fixedSize()
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { SelfTest.controlsFrame = $0 }
                    #endif

                HStack(spacing: 14) {
                    VolumeControl()
                    LikeButton(track: track, font: .title3)
                    open(.lyrics, symbol: "quote.bubble", help: "Lyrics")
                    open(.upNext, symbol: "list.bullet", help: "Up Next")
                    open(.none, symbol: "arrow.up.left.and.arrow.down.right", help: "Now Playing (⇧⌘F)")
                }
                .padding(.trailing, 8)       // inside the side, so both sides stay equal: the list icon keeps its 18 pt from the edge
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)   // equal on both sides, or the centre moves
            .overlay(alignment: .bottom) {
                ProgressBar(position: player.position, duration: player.duration) { player.seek(to: $0) }
                    .padding(.horizontal, 22)
                    .offset(y: 4)
            }
            .glassEffect(barGlass, in: .capsule)                 // interactive: the glass reacts to hover and press
            .glassEffectID("bar", in: glass)
            .glassEffectTransition(.materialize)
            .frame(maxWidth: 860)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { player.barFrame = $0 }
            .simultaneousGesture(MagnifyGesture().onEnded { if $0.magnification > 1.15 { player.showNowPlaying = true } })
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
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
    @AppStorage("artStrength") private var artStrength = Look.artStrength
    @AppStorage("nowPlayingPanel") private var panelRaw = NowPlayingPanel.upNext.rawValue
    @Environment(ThemeStore.self) private var theme
    @State private var isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
    private var glow: Color? { theme.color(.playing) }    // the light under the artwork: Settings › Colours › Playing song
    private var panel: NowPlayingPanel { NowPlayingPanel(rawValue: panelRaw) ?? .upNext }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // a thick material hides the screen below; the artwork's wash goes on top of it
                Backdrop(track: player.current, strength: min(1, artStrength * 1.4), base: AnyShapeStyle(.ultraThickMaterial))

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
                .contentTransition(.numericText())          // the digits roll
                .animation(.snappy(duration: 0.3), value: Int(player.position))
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
struct LyricsPanel: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "quote.bubble").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Lyrics are on the way").textStyle(.headline)
            Text("Lines will light up in time with the song.")
                .textStyle(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

struct UpNextView: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next").textStyle(.headline).padding(.horizontal, 16).padding(.top, 16)
            if player.upNext.isEmpty {
                Text("Nothing queued. Play a list, or right-click a song → Play Next.")
                    .textStyle(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, track in
                            Button { player.jump(to: player.index + 1 + offset) } label: {
                                HStack(spacing: 10) {
                                    ArtworkView(url: track.image, size: 36, radius: 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(track.title).textStyle(.callout).lineLimit(1)
                                        Text(track.artistLine).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 6).padding(.bottom, 10)
                }
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
