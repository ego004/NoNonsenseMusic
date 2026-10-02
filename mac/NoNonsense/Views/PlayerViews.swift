import SwiftUI

/// The floating Liquid Glass capsule at the bottom of the window. Hidden until something plays.
struct PlayerBar: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let track = player.current {
            HStack(spacing: 14) {
                Button { player.showNowPlaying = true } label: {
                    ArtworkView(url: track.image, size: 44, radius: 9)
                }
                .buttonStyle(.plain)
                .help("Open Now Playing (⇧⌘F)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(track.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(minWidth: 120, maxWidth: 240, alignment: .leading)

                Spacer(minLength: 8)
                TransportControls(size: .title3, playSize: .title)
                Spacer(minLength: 8)

                if player.isBuffering { ProgressView().controlSize(.small) }
                LikeButton(track: track, font: .title3)
                Button { player.showNowPlaying = true } label: { Image(systemName: "list.bullet").font(.title3) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Up Next")
            }
            .padding(.leading, 10).padding(.trailing, 18).padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                ProgressBar(position: player.position, duration: player.duration) { player.seek(to: $0) }
                    .padding(.horizontal, 22)
                    .offset(y: 4)
            }
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: 760)
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        }
    }
}

/// ⏮ ▶ ⏭, shared by the bar and Now Playing.
struct TransportControls: View {
    var size: Font = .title3
    var playSize: Font = .title
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 22) {
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(size) }
                .help("Previous (⌘←)")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(playSize)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 34)
            }
            .help("Play / Pause (Space)")
            Button { player.next() } label: { Image(systemName: "forward.fill").font(size) }
                .help("Next (⌘→)")
        }
        .buttonStyle(.plain)
    }
}

/// Full-window Now Playing: huge artwork (as Jon Hicks asked Apple for), blended background, Up Next.
struct NowPlayingView: View {
    @Environment(Player.self) private var player

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Backdrop(track: player.current, strength: 1.8)

                if let track = player.current {
                    let side = min(geo.size.height * 0.62, geo.size.width * 0.42, 560)
                    HStack(alignment: .center, spacing: 48) {
                        VStack(alignment: .leading, spacing: 22) {
                            ArtworkView(url: track.image, size: side, radius: 18)
                                .shadow(color: .black.opacity(0.28), radius: 40, y: 22)
                                .id(track.id)
                                .transition(.scale(scale: 0.94).combined(with: .opacity))
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(track.title).font(.title.bold()).lineLimit(2)
                                    Spacer()
                                    LikeButton(track: track, font: .title2)
                                }
                                Text(track.artistLine).font(.title3).foregroundStyle(.secondary).lineLimit(1)
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
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            .frame(width: side)
                            TransportControls(size: .title, playSize: .system(size: 44))
                                .frame(width: side)
                        }

                        UpNextView()
                            .frame(width: 320)
                            .frame(maxHeight: side + 180)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: track.id)
                }

                Button { player.showNowPlaying = false } label: {
                    Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .keyboardShortcut(.cancelAction)                      // Esc closes
                .help("Close (Esc)")
                .padding(24)
            }
        }
    }
}

struct UpNextView: View {
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Up Next").font(.headline).padding(.horizontal, 16).padding(.top, 16)
            if player.upNext.isEmpty {
                Text("Nothing queued. Play a list, or right-click a song → Play Next.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, track in
                            Button { player.jump(to: player.index + 1 + offset) } label: {
                                HStack(spacing: 10) {
                                    ArtworkView(url: track.image, size: 36, radius: 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(track.title).font(.callout).lineLimit(1)
                                        Text(track.artistLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
