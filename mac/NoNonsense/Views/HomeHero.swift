import SwiftUI

/// The top of Home (15 Oct, as in the Windows app): the song playing, large, with the next three songs of Up Next
/// beside it (under it where Home is narrower than 900 pt); with nothing playing, the last song played, to pick up
/// again; with nothing ever played, nothing. Drawn again only when the song, its state or Up Next changes: while a
/// song plays the one moving part is the time line, which is Core Animation and changes its text once a second
/// itself (PlaybackTimeline).
struct NowHero: View {
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        #if DEBUG
        let _ = SelfTest.drew("home.hero")
        #endif
        if let current = player.current {
            let next = Array(player.upNext.prefix(3))
            if next.isEmpty {
                NowCard(track: current)
            } else {
                HeroLayout {
                    NowCard(track: current)
                    UpNextCard(next: next)
                }
            }
        } else if let last = library.recent.first {
            ResumeCard(track: last)
        }
    }
}

/// The Now card and Up Next side by side, 3 : 2, 16 apart and of one height (the shorter one stretched to the
/// taller); under 900 pt of width, Up Next under the Now card.
struct HeroLayout: Layout {
    static let narrow: CGFloat = 900
    private let gap: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.narrow
        return CGSize(width: width, height: frames(width, subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(bounds.width, subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Where the two cards go in this width (the Now card first).
    private func frames(_ width: CGFloat, _ subviews: Subviews) -> [CGRect] {
        guard subviews.count == 2 else { return [] }
        func height(_ view: LayoutSubview, _ across: CGFloat) -> CGFloat {
            view.sizeThatFits(ProposedViewSize(width: across, height: nil)).height
        }
        if width < Self.narrow {
            let top = height(subviews[0], width)
            return [CGRect(x: 0, y: 0, width: width, height: top),
                    CGRect(x: 0, y: top + gap, width: width, height: height(subviews[1], width))]
        }
        let left = (width - gap) * 3 / 5, right = width - gap - left
        let tall = max(height(subviews[0], left), height(subviews[1], right))
        return [CGRect(x: 0, y: 0, width: left, height: tall), CGRect(x: left + gap, y: 0, width: right, height: tall)]
    }
}

/// The song playing: its cover (it opens Now Playing), NOW PLAYING or PAUSED in the accent colour, the title as the
/// page's headline, the artists, then play or pause, the time line and the song's menu.
private struct NowCard: View {
    let track: Track
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme

    var body: some View {
        let playing = player.isPlaying || player.isBuffering
        let label = playing ? "NOW PLAYING" : "PAUSED"
        #if DEBUG
        let _ = SelfTest.drew("home.now", "\(label) · \(track.title)")
        #endif
        HStack(spacing: 24) {
            Button { player.showNowPlaying = true } label: {
                // Core Animation, as the bar's cover: a new song's cover crossfades without the app drawing each
                // frame, and swaps at once while Now Playing covers it
                LiveArtwork(url: track.image, size: 148, radius: 12, fades: { [player] in !player.showNowPlaying })
                    .frame(width: 148, height: 148)
            }
            .buttonStyle(.quiet(highlight: false))
            .help("Open Now Playing (⇧⌘F)")
            .accessibilityLabel("Open Now Playing")

            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .tracking(2)
                    .textStyle(size: 11.5, weight: .bold)
                    .foregroundStyle(theme.color(.buttons) ?? .accentColor)    // Settings › Colours › Buttons
                Text(track.title)
                    .tracking(-1.2)
                    .textStyle(size: 42, weight: .heavy)
                    .lineLimit(1)
                    .padding(.top, 6)
                Text(track.artistLine)
                    .textStyle(size: 16)
                    .foregroundStyle(.primary.opacity(0.65))
                    .lineLimit(1)
                    .padding(.top, 2)
                HStack(spacing: 0) {
                    RoundPlay(size: 44, playing: playing, help: "Play / Pause (Space)") { player.togglePlayPause() }
                    // the one part of Home that moves while a song plays: a Core Animation line, and its text once a
                    // second only while the window can be seen and Now Playing does not cover it
                    PlaybackTimeline(thickness: 4, underNowPlaying: true, timesAfter: true, textSize: 12.5)
                        .padding(.leading, 16)
                    SongActionsButton(track: track, font: .title2)
                        .padding(.leading, 4)
                }
                .padding(.top, 18)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .homePanel(radius: 22)
        .selfTestFrame("home.now")
    }
}

/// The white round play button of Home's cards, as in the Windows app.
private struct RoundPlay: View {
    let size: CGFloat
    let playing: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4))
                .foregroundStyle(Color(red: 17 / 255, green: 17 / 255, blue: 20 / 255))
                .frame(width: size, height: size)
                .background(.white, in: .circle)
        }
        .buttonStyle(.quiet(highlight: false))
        .help(help)
        .accessibilityLabel(playing ? "Pause" : "Play")
    }
}

/// Up Next on Home: the next three songs, each with its length; one clicked plays now. See All opens Now Playing with
/// Up Next beside the song.
private struct UpNextCard: View {
    let next: [Track]
    @Environment(Player.self) private var player
    @AppStorage("nowPlayingPanel") private var panelRaw = NowPlayingPanel.upNext.rawValue

    var body: some View {
        #if DEBUG
        let _ = SelfTest.drew("home.upNext", next.first?.title ?? "")
        #endif
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next")
                    .textStyle(size: 15, weight: .semibold)
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.leading, 4)
                Spacer()
                Button("See All") {
                    panelRaw = NowPlayingPanel.upNext.rawValue
                    player.showNowPlaying = true
                }
                .buttonStyle(.quiet)
                .textStyle(size: 14, weight: .medium)
                .foregroundStyle(.primary.opacity(0.7))
                .padding(.trailing, 12)                            // over the songs' lengths
                .help("Open Up Next")
            }
            .frame(minHeight: 32)
            ForEach(Array(next.enumerated()), id: \.offset) { i, track in
                UpNextLine(track: track) { player.jump(to: player.index + 1 + i) }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .homePanel(radius: 22)
        .selfTestFrame("home.upNext")
    }
}

/// One of the next songs: its cover, title and artists, and its length. The hover is its own, shown at once.
private struct UpNextLine: View {
    let track: Track
    let play: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: track.image, size: 40, radius: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(track.title).textStyle(size: 14, weight: .semibold).lineLimit(1)
                Text(track.artistLine).textStyle(size: 12.5).foregroundStyle(.primary.opacity(0.55)).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(formatTime(Double(track.duration)))
                .monospacedDigit()
                .textStyle(size: 12.5)
                .foregroundStyle(.primary.opacity(0.5))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(.primary.opacity(hovering ? 0.06 : 0), in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(perform: play)
        .onHover { hovering = $0 }                         // instant: a fade per hover redrew the window ~15 times
        .padding(.trailing, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Play \(track.title)")
    }
}

/// Nothing playing: the last song played, and a button that plays Recently Played again from the top.
private struct ResumeCard: View {
    let track: Track
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        #if DEBUG
        let _ = SelfTest.drew("home.resume", track.title)
        #endif
        let play = { player.play(library.recent, startAt: 0) }
        HStack(spacing: 0) {
            Button(action: play) { ArtworkView(url: track.image, size: 84, radius: 10) }
                .buttonStyle(.quiet(highlight: false))
                .help("Play")
                .accessibilityLabel("Play \(track.title)")
            VStack(alignment: .leading, spacing: 0) {
                Text("PICK UP WHERE YOU LEFT OFF")
                    .tracking(2)
                    .textStyle(size: 11.5, weight: .bold)
                    .foregroundStyle(.primary.opacity(0.55))
                Text(track.title)
                    .tracking(-0.6)
                    .textStyle(size: 26, weight: .heavy)
                    .lineLimit(1)
                    .padding(.top, 6)
                Text(track.artistLine)
                    .textStyle(size: 14.5)
                    .foregroundStyle(.primary.opacity(0.65))
                    .lineLimit(1)
            }
            .padding(.leading, 20)
            Spacer(minLength: 16)
            RoundPlay(size: 52, playing: false, help: "Play", action: play)
        }
        .padding(18)
        .homePanel(radius: 22)
        .selfTestFrame("home.resume")
    }
}

extension View {
    /// Home's cards and tiles (15 Oct, the Windows app's panels): a tint of the content colour over the window's own
    /// see-through background, and a hairline round it; `highlighted` (a tile under the pointer) adds a shade, at once.
    /// Not Liquid Glass: these scroll with the page (content, not controls floating over it), the bar and the toolbar
    /// are the glass, and the window under them is already a blur, as on Windows, where these panels are a tint too.
    /// A tint costs nothing to draw; a material per card and tile (Liquid Glass off, or macOS 15) would blur again on
    /// every frame of a scroll.
    func homePanel(radius: CGFloat, highlighted: Bool = false) -> some View {
        modifier(HomePanel(radius: radius, highlighted: highlighted))
    }
}

private struct HomePanel: ViewModifier {
    let radius: CGFloat
    let highlighted: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    // dark: a deeper shade than the window; light: a paler one (the Windows app's 42% and 50%)
                    shape.fill(Color(nsColor: .controlBackgroundColor).opacity(scheme == .dark ? 0.42 : 0.5))
                    if highlighted { shape.fill(.primary.opacity(0.06)) }
                }
            }
            .overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
    }
}
