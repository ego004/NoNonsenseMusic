import SwiftUI

/// One song in any list. Double-click (or click the artwork) to play; hover reveals the heart.
/// A song found on several sources shows "N listings": click it to open every copy, and play exactly the one you want.
struct SongRow: View {
    let track: Track
    let queue: [Track]
    let index: Int
    /// On an album (its page, or a pinned album): the track number, shown in place of the cover.
    var number: Int? = nil
    /// In a playlist: the rows' item ids and the playlist's queue name, so your edits reach a playing queue.
    var keys: [String]? = nil
    var source: String? = nil
    var removeLabel = "Remove"
    /// In a playlist: "Remove from …" in the right-click menu.
    var remove: (() -> Void)? = nil
    /// False where the list handles the double-click (a list you can reorder: see `row`).
    var doubleClickPlays = true
    @Environment(Player.self) private var player
    @State private var expanded = false

    /// True for any copy of this song: playing a chosen listing changes `best`, not the song.
    private var isCurrent: Bool { player.current.map { $0.isSameSong(as: track) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if expanded {
                VStack(spacing: 0) {
                    ForEach(track.listings, id: \.key) { listing in
                        ListingRow(listing: listing,
                                   isDefault: listing.key == track.best.key,
                                   isPlaying: player.playingListing?.key == listing.key && isCurrent) {
                            play(listing)
                        }
                    }
                }
                .padding(.leading, number == nil ? 56 : 44)     // under the title: artwork (44) + spacing (12), or number (34) + 10
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var row: some View {
        SongRowLine(track: track, number: number, expanded: $expanded) { player.play(queue, startAt: index, keys: keys, source: source) }
            .contentShape(.rect)
            // off in a list you reorder: any double-tap gesture on a row, simultaneous or not, takes the mouse-down the
            // list needs to start a drag, so a playlist's songs could not be dragged (real input, 8 Oct). There the list
            // itself plays on a double-click (PlaylistView)
            .simultaneousGesture(TapGesture(count: 2).onEnded { player.play(queue, startAt: index, keys: keys, source: source) },
                                 including: doubleClickPlays ? .all : .subviews)
            .contextMenu {
                Button("Play") { player.play(queue, startAt: index, keys: keys, source: source) }
                Button("Play Next") { player.playNext(track) }
                Button("Add to Queue") { player.addToQueue(track) }
                Divider()
                SongLibraryActions(track: track)
                Divider()
                if let artist = track.artists.first {
                    Button("Go to Artist") { Navigator.shared.open(.artistNamed(artist)) }
                }
                if let album = track.albumTitle {
                    Button("Go to Album") { Navigator.shared.open(.albumNamed(title: album, artist: track.artists.first ?? "")) }
                }
                if let remove {
                    Divider()
                    Button(removeLabel, role: .destructive, action: remove)
                }
            }
    }

    /// Plays one chosen copy in place, so the rest of the list still follows it.
    private func play(_ listing: Listing) {
        var chosen = queue
        chosen[index] = track.playing(listing)
        player.play(chosen, startAt: index, keys: keys, source: source)
    }
}

/// What a row shows, and the hover, in a view of their own: a hover (and a song change) redraws only this, not the row
/// and its menu (built again on every redraw of the row). The cover's overlay fades instead of being added and removed:
/// that laid the row out again on every hover, and rows passing under the pointer while a list scrolled did it over
/// and over (as Home's tiles did: 8% of a core, 7 Oct).
private struct SongRowLine: View {
    let track: Track
    let number: Int?
    @Binding var expanded: Bool
    let play: () -> Void
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ThemeStore.self) private var theme
    @Environment(DownloadStore.self) private var downloads
    @State private var hovering = false

    /// Settings › Colours › Playing song; System is your Mac's accent.
    private var highlight: Color { theme.color(.playing) ?? .accentColor }

    var body: some View {
        let current = player.current.map { $0.isSameSong(as: track) } ?? false
        // an album's playing song: its whole row filled in the playing colour, as Apple Music marks it (15 Oct, as in
        // the Windows app). Other rows keep the hover shade alone
        let filled = current && number != nil
        HStack(spacing: number == nil ? 12 : 10) {
            Button(action: play) {
                if let number {
                    numberBox(number, current: current)
                } else {
                    ArtworkView(url: track.image, size: 44, radius: 8)
                        .overlay {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35))
                                if current && player.isBuffering {
                                    ProgressView().controlSize(.small).tint(.white)          // loading this song
                                } else {
                                    PlayingSpeaker(playing: current && player.isPlaying)
                                }
                            }
                            .opacity(hovering || current ? 1 : 0)
                        }
                }
            }
            .buttonStyle(.quiet(highlight: false))
            .accessibilityLabel("Play \(track.title)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(track.title)
                        .textStyle(.body, weight: .medium)
                        .foregroundStyle(current ? AnyShapeStyle(highlight) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                    if track.isExplicit { ExplicitBadge() }
                }
                HStack(spacing: 5) {
                    if downloads.isDownloading(track) {
                        ProgressView().controlSize(.mini)
                    } else if downloads.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(.secondary)
                            .help("Downloaded: plays without the server or the internet")
                    }
                    Text(track.artistLine).textStyle(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if track.listings.count == 1 {
                // one copy: where it plays from, in the place "N listings" takes for songs found on several sources
                Text(track.best.sourceName)
                    .textStyle(.caption)
                    .foregroundStyle(.secondary)
                    .help("The only place this song plays from")
            } else if track.listings.count > 1 {
                Button { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text("\(track.listings.count) listings")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .textStyle(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.quiet)
                .help(expanded ? "Hide the listings" : "Every place this song can be played from")
            }

            LikeButton(track: track)
                .opacity(hovering || library.isLiked(track) ? 1 : 0)

            Text(formatTime(Double(track.duration)))
                .textStyle(.subheadline, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(filled ? AnyShapeStyle(highlight.opacity(0.12)) : AnyShapeStyle(.primary.opacity(hovering ? 0.05 : 0)),
                    in: .rect(cornerRadius: filled ? 12 : 10, style: .continuous))
        .onHover { hovering = $0 }                         // instant: a fade per hover redrew the window ~15 times
    }

    /// An album row's number, in a 34 × 40 box where the cover would be (15 Oct, as in the Windows app): ▶ under the
    /// pointer, and the playing mark on the playing song. Number and ▶ swap by opacity, as the cover's overlay fades:
    /// a hover lays nothing out again.
    private func numberBox(_ number: Int, current: Bool) -> some View {
        ZStack {
            Text(String(number))
                .monospacedDigit()
                .textStyle(size: 15, weight: .semibold)
                .foregroundStyle(.primary.opacity(0.42))
                .opacity(current || hovering ? 0 : 1)
            Image(systemName: "play.fill")
                .opacity(!current && hovering ? 1 : 0)
            if current {
                if player.isBuffering {
                    ProgressView().controlSize(.small)                  // loading this song
                } else {
                    PlayingSpeaker(playing: player.isPlaying, style: AnyShapeStyle(highlight), color: highlight)
                }
            }
        }
        .frame(width: 34, height: 40)
    }
}

/// One copy of a song: its title and artists, source, quality and length. Click to play exactly this copy.
struct ListingRow: View {
    let listing: Listing
    let isDefault: Bool
    let isPlaying: Bool
    let play: () -> Void
    @Environment(ThemeStore.self) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: play) {
            HStack(spacing: 10) {
                PlayingSpeaker(playing: isPlaying, font: .caption,
                               style: isPlaying ? (theme.color(.playing).map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.accentColor)) : AnyShapeStyle(.secondary),
                               color: theme.color(.playing) ?? .accentColor)
                    .opacity(isPlaying || hovering ? 1 : 0)
                    .frame(width: 16)
                Text(listing.title).lineLimit(1)
                if listing.explicit == true { ExplicitBadge() }
                Text(listing.artists.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 12)
                if isDefault {
                    Text("Default").foregroundStyle(.secondary).help("The copy that plays when you play the song")
                }
                Text(listing.sourceName).foregroundStyle(.secondary)
                Text(listing.quality).foregroundStyle(.tertiary)
                Text(formatTime(Double(listing.duration)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            .textStyle(.callout)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(hovering ? AnyShapeStyle(.primary.opacity(0.05)) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.quiet)
        .onHover { hovering = $0 }
        .accessibilityLabel("Play the \(listing.sourceName) listing of \(listing.title)")
    }
}
