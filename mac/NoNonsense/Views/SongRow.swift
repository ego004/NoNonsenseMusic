import SwiftUI

/// One song in any list. Double-click (or click the artwork) to play; hover reveals the heart.
/// A song found on several sources shows "N listings": click it to open every copy, and play exactly the one you want.
struct SongRow: View {
    let track: Track
    let queue: [Track]
    let index: Int
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ThemeStore.self) private var theme
    @State private var hovering = false
    @State private var expanded = false

    /// Settings › Colours › Playing song; System is your Mac's accent.
    private var highlight: AnyShapeStyle { theme.color(.playing).map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.accentColor) }

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
                .padding(.leading, 56)          // under the title: artwork (44) + spacing (12)
                .padding(.bottom, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Button { player.play(queue, startAt: index) } label: {
                ArtworkView(url: track.image, size: 44, radius: 8)
                    .overlay {
                        if hovering || isCurrent {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35))
                            if isCurrent && player.isBuffering {
                                ProgressView().controlSize(.small).tint(.white)          // loading this song
                            } else {
                                Image(systemName: isCurrent && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                                    .foregroundStyle(.white)
                                    .symbolEffect(.variableColor.iterative, isActive: isCurrent && player.isPlaying)
                            }
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(track.title)")

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCurrent ? highlight : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 12)

            if track.listings.count > 1 {
                Button { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } } label: {
                    HStack(spacing: 4) {
                        Text("\(track.listings.count) listings")
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide the listings" : "Every place this song can be played from")
            }

            LikeButton(track: track)
                .opacity(hovering || library.isLiked(track) ? 1 : 0)

            Text(formatTime(Double(track.duration)))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(hovering ? AnyShapeStyle(.primary.opacity(0.05)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(count: 2) { player.play(queue, startAt: index) }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button("Play") { player.play(queue, startAt: index) }
            Button("Play Next") { player.playNext(track) }
            Divider()
            Button(library.isLiked(track) ? "Remove from Liked" : "Like") { Task { await library.toggleLike(track) } }
        }
    }

    /// Plays one chosen copy in place, so the rest of the list still follows it.
    private func play(_ listing: Listing) {
        var chosen = queue
        chosen[index] = track.playing(listing)
        player.play(chosen, startAt: index)
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
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                    .font(.caption)
                    .foregroundStyle(isPlaying ? (theme.color(.playing).map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.accentColor)) : AnyShapeStyle(.secondary))
                    .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    .opacity(isPlaying || hovering ? 1 : 0)
                    .frame(width: 16)
                Text(listing.title).lineLimit(1)
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
            .font(.callout)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(hovering ? AnyShapeStyle(.primary.opacity(0.05)) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Play the \(listing.sourceName) listing of \(listing.title)")
    }
}
