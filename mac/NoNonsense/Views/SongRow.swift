import SwiftUI

/// One song in any list. Double-click (or click the artwork) to play; hover reveals the heart.
struct SongRow: View {
    let track: Track
    let queue: [Track]
    let index: Int
    @Environment(Player.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var hovering = false
    @State private var showVersions = false

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            Button { player.play(queue, startAt: index) } label: {
                ArtworkView(url: track.image, size: 44, radius: 8)
                    .overlay {
                        if hovering || isCurrent {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.35))
                            Image(systemName: isCurrent && player.isPlaying ? "speaker.wave.2.fill" : "play.fill")
                                .foregroundStyle(.white)
                                .symbolEffect(.variableColor.iterative, isActive: isCurrent && player.isPlaying)
                        }
                    }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(track.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 12)

            if track.listings.count > 1 {
                Button { showVersions.toggle() } label: { Chip(text: "\(track.listings.count) copies") }
                    .buttonStyle(.plain)
                    .help("Every place this song can be played from")
                    .popover(isPresented: $showVersions, arrowEdge: .bottom) { VersionsView(track: track) }
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
}

/// "N copies": every listing of a song, so you can pick a specific one.
struct VersionsView: View {
    let track: Track
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Copies of “\(track.title)”").font(.headline)
            ForEach(track.listings, id: \.key) { listing in
                Button { player.play([track.playing(listing)]) } label: {
                    HStack(spacing: 10) {
                        ArtworkView(url: listing.image.flatMap(URL.init(string:)), size: 32, radius: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(listing.album ?? listing.title).lineLimit(1)
                            Text(listing.artists.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 16)
                        Chip(text: listing.sourceName)
                        Chip(text: listing.quality)
                        Text(formatTime(Double(listing.duration))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        if listing.key == track.best.key {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow).help("The copy that plays by default")
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 520)
    }
}
