import SwiftUI

/// Album cover with continuous ("squircle") corners and a hairline edge, like Apple Music.
struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var radius: CGFloat = 8

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note").font(.system(size: size * 0.32)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
    }
}

/// The window's background: a blurred wash of the current song's artwork, tinted with its pastel colour.
struct Backdrop: View {
    let track: Track?
    var strength: Double = 1
    @State private var tint: Color = .clear
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            // The image fills the area but must never SET its size: a square cover scaled to fill a wide
            // window is taller than the window, and it pushed the whole screen off-screen (5 Oct).
            // Color.clear takes the given size; the image is only drawn on top of it, then clipped.
            Color.clear
                .overlay {
                    if let url = track?.image {
                        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                            .transition(.opacity)
                    }
                }
                .clipped()
                .blur(radius: 90)
                .opacity((scheme == .dark ? 0.30 : 0.40) * strength)
            LinearGradient(colors: [tint.opacity(0.45 * strength), tint.opacity(0.12 * strength)],
                           startPoint: .top, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
        .task(id: [track?.id ?? "", scheme == .dark ? "dark" : "light"]) {
            guard let track else { tint = .clear; return }
            tint = await Palette.pastel(for: track.image, dark: scheme == .dark) ?? Palette.fallback(for: track.title)
        }
        .animation(.easeInOut(duration: 0.8), value: tint)
        .animation(.easeInOut(duration: 0.6), value: track?.id)
    }
}

struct LikeButton: View {
    let track: Track
    var font: Font = .body
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let liked = library.isLiked(track)
        Button {
            Task { await library.toggleLike(track) }
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(font)
                .foregroundStyle(liked ? AnyShapeStyle(Color.pastelPink) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: liked)
        }
        .buttonStyle(.plain)
        .help(liked ? "Remove from Liked" : "Like")
    }
}

/// A thin progress line that thickens on hover and can be dragged to seek.
struct ProgressBar: View {
    let position: Double
    let duration: Double
    let onSeek: (Double) -> Void
    var thickness: CGFloat = 3
    @State private var hovering = false
    @State private var dragged: Double?

    var body: some View {
        GeometryReader { geo in
            let fraction = duration > 0 ? min(1, max(0, (dragged ?? position) / duration)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule().fill(.primary.opacity(0.7)).frame(width: geo.size.width * fraction)
            }
            .frame(height: hovering || dragged != nil ? thickness * 2 : thickness)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragged = max(0, min(1, value.location.x / geo.size.width)) * duration }
                .onEnded { _ in if let d = dragged { onSeek(d) }; dragged = nil })
        }
        .frame(height: 14)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// A small capsule label: source name, audio quality.
struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
            .foregroundStyle(.secondary)
    }
}

extension Color {
    static let pastelPink = Color(red: 1.0, green: 0.42, blue: 0.58)
}
